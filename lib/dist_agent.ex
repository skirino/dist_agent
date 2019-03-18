use Croma

defmodule DistAgent do
  @moduledoc File.read!(Path.join([__DIR__, "..", "README.md"])) |> String.replace_prefix("# #{inspect(__MODULE__)}\n\n", "")

  alias Croma.Result, as: R
  alias DistAgent.{Behaviour, State, Quota, TickSender}
  alias DistAgent.Quota.Name, as: QName
  alias DistAgent.Quota.Limit, as: QLimit

  #
  # initialization
  #
  @default_split_merge_policy %RaftKV.SplitMergePolicy{max_shards: 100, max_keys_per_shard: 100}

  @type init_option :: {:split_merge_policy, RaftKV.SplitMergePolicy.t}

  @doc """
  Initializes `:dist_agent`.

  Note that `:dist_agent` requires that you complete the following initialization steps before calling this function:

  1. connect to the other existing nodes in the cluster
  1. call `RaftFleet.activate/1`
  1. call `RaftKV.init/0`
  """
  defun init(init_options :: [init_option] \\ []) :: :ok do
    register_keyspace(init_options)
    case Quota.add_consensus_group() do
      :ok                      -> :ok
      {:error, :already_added} -> :ok
    end
    Quota.Reporter.init()
    TickSender.init()
  end

  defp register_keyspace(options) do
    policy = Keyword.get(options, :split_merge_policy, @default_split_merge_policy)
    case RaftKV.register_keyspace(:dist_agent, State, State, policy) do
      :ok                           -> :ok
      {:error, :already_registered} -> :ok
    end
  end

  #
  # quota management
  #
  @doc """
  Lists existing quota names.
  """
  defun list_quotas() :: [QName.t] do
    {:ok, l} = RaftFleet.query(Quota, :list_quotas)
    l
  end

  @doc """
  Returns a pair of current number of distributed agents in the specified quota and its upper limit.
  """
  defun quota_usage(quota_name :: v[QName.t]) :: nil | {non_neg_integer, QLimit.t} do
    {:ok, pair} = RaftFleet.query(Quota, {:quota_usage, quota_name})
    pair
  end

  @doc """
  Adds or updates limit of the specified quota.
  """
  defun put_quota(quota_name :: v[QName.t], limit :: v[QLimit.t]) :: :ok do
    {:ok, :ok} = RaftFleet.command(Quota, {:put_quota, quota_name, limit})
    :ok
  end

  @doc """
  Deletes limit of the specified quota.
  """
  defun delete_quota(quota_name :: v[QName.t]) :: :ok do
    {:ok, :ok} = RaftFleet.command(Quota, {:delete_quota, quota_name})
    :ok
  end

  #
  # command & query
  #
  @type option :: RaftKV.option
                | {:rate_limit, nil | {milliseconds_per_token :: pos_integer, max_tokens :: pos_integer}}

  @doc """
  Sends a read-only query to the specified distributed agent and receives a reply from it.

  The target distributed agent is specified by the triplet: `quota_name`, `callback_module` and `agent_key`.
  If the agent has not yet activated `{:error, :agent_not_found}` is returned.

  On receipt of the query, the distributed agent evaluates `c:DistAgent.Behaviour.handle_query/4` callback
  and then `c:DistAgent.Behaviour.after_query/5` callback.
  For the detailed semantics of the arguments and return values of the callbacks refer to `DistAgent.Behaviour`.

  ## Options

  The last argument to this function is a list of options.
  Most of options are directly passed to the underlying function (`RaftKV.query/4`).

  You may also pass `:rate_limit` option to enable per-node rate limiting feature.
  The value part of `:rate_limit` option must be a pair of positive integers.
  Executing a query consumes 1 token in the corresponding bucket.
  See also `Foretoken.take/5`.
  """
  defun query(quota_name      :: v[QName.t],
              callback_module :: v[module],
              agent_key       :: v[String.t],
              query           :: Behaviour.query,
              options         :: [option] \\ []) :: {:ok, Behaviour.ret} | {:error, :agent_not_found | {:rate_limit_reached, milliseconds_to_wait :: pos_integer} | :no_leader} do
    id = {quota_name, callback_module, agent_key}
    case Keyword.get(options, :rate_limit) do
      nil                            -> query_impl(id, query, options)
      {millis_per_token, max_tokens} ->
        case Foretoken.take(id, millis_per_token, max_tokens, 1) do
          :ok                                           -> query_impl(id, query, options)
          {:error, {:not_enough_token, millis_to_wait}} -> {:error, {:rate_limit_reached, millis_to_wait}}
        end
    end
  end

  defp query_impl(id, query, options) do
    case RaftKV.query(:dist_agent, id, query, options) do
      {:ok, result}            -> result
      {:error, :key_not_found} -> {:error, :agent_not_found}
      {:error, _} = e          -> e
    end
  end

  @doc """
  Sends a command to the specified distributed agent and receives a reply from it.

  The target distributed agent is specified by the triplet: `quota_name`, `callback_module` and `agent_key`.
  If the agent has not yet activated, it is activated before applying the command.
  During activation of the new agent, quota limit is checked (and it involves additional message round-trip).
  As such it is necessary that the quota is created (by `put_quota/2`) before calling this function.
  When the quota limit is violated `{:error, :quota_limit_reached}` is returned.

  On receipt of the command, the distributed agent evaluates `c:DistAgent.Behaviour.handle_command/4` callback
  and then `c:DistAgent.Behaviour.after_command/6` callback.
  For the semantics of the arguments and return values of the callbacks refer to `DistAgent.Behaviour`.

  ## Options

  The last argument to this function is a list of options.
  Most of options are directly passed to the underlying function (`RaftKV.command/4`).

  You may also pass `:rate_limit` option to enable per-node rate limiting feature.
  The value part of `:rate_limit` option must be a pair of positive integers.
  Executing a command consumes 3 tokens in the corresponding bucket (as command is basically more expensive than query).
  See also `Foretoken.take/5`.
  """
  defun command(quota_name      :: v[QName.t],
                callback_module :: v[module],
                agent_key       :: v[String.t],
                command         :: Behaviour.command,
                options         :: [option] \\ []) :: {:ok, Behaviour.ret} | {:error, :quota_limit_reached | :quota_not_found | {:rate_limit_reached, milliseconds_to_wait :: pos_integer} | :no_leader} do
    id = {quota_name, callback_module, agent_key}
    case Keyword.get(options, :rate_limit) do
      nil                            -> command_impl(id, command, options)
      {millis_per_token, max_tokens} ->
        case Foretoken.take(id, millis_per_token, max_tokens, 3) do
          :ok                                           -> command_impl(id, command, options)
          {:error, {:not_enough_token, millis_to_wait}} -> {:error, {:rate_limit_reached, millis_to_wait}}
        end
    end
  end

  defp command_impl(id, command, options) do
    RaftKV.command(:dist_agent, id, command, options)
    |> R.bind(fn
      {:"$dist_agent_check_quota", pending_index} -> check_quota_for_new_agent_id(id, pending_index, options)
      :"$dist_agent_quota_limit_reached"          -> {:error, :quota_limit_reached}
      :"$dist_agent_retry"                        -> :timer.sleep(200); command_impl(id, command, options) # shouldn't happen, retry indefinitely
      ret                                         -> {:ok, ret}
    end)
  end

  defp check_quota_for_new_agent_id(id, pending_index, options) do
    case Quota.query_status(id) do
      :ok            -> report_quota_check_result(id, pending_index, :"$dist_agent_quota_ok", options)
      :limit_reached -> report_quota_check_result(id, pending_index, :"$dist_agent_quota_ng", options)
      :not_found     -> revert_preparing_agent_for_nonexisting_quota(id, options)
    end
  end

  defp report_quota_check_result(id, pending_index, command_label, options) do
    case RaftKV.command(:dist_agent, id, {command_label, pending_index}, options) do
      {:ok, :"$dist_agent_quota_limit_reached"} -> {:error, :quota_limit_reached}
      {:ok, _ret} = ok                          -> ok
      {:error, _} = e                           -> e
    end
  end

  defp revert_preparing_agent_for_nonexisting_quota(id, options) do
    _ = RaftKV.command(:dist_agent, id, :"$dist_agent_quota_not_found", options)
    {:error, :quota_not_found}
  end
end
