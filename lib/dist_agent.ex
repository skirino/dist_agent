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
  @default_rv_options [
    communication_module:                BatchedCommunication,
    heartbeat_timeout:                   500,
    election_timeout:                    2_000,
    election_timeout_clock_drift_margin: 500,
  ]
  @default_split_merge_policy %RaftKV.SplitMergePolicy{max_shards: 100, max_keys_per_shard: 100}

  @type init_option :: {:rv_options        , [RaftedValue.option]}
                     | {:split_merge_policy, RaftKV.SplitMergePolicy.t}

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
    rv_options = Keyword.get(options, :rv_options        , @default_rv_options        )
    policy     = Keyword.get(options, :split_merge_policy, @default_split_merge_policy)
    case RaftKV.register_keyspace(:dist_agent, rv_options, State, State, policy) do
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
  @doc """
  """
  defun command(quota_name      :: v[QName.t],
                callback_module :: v[module],
                agent_key       :: v[String.t],
                command         :: Behaviour.command,
                options         :: [RaftKV.option] \\ []) :: {:ok, Behaviour.ret} | {:error, :quota_limit_reached | :quota_not_found | :no_leader} do
    id = {quota_name, callback_module, agent_key}
    options = Keyword.put_new(options, :call_module, BatchedCommunication)
    RaftKV.command(:dist_agent, id, command, options)
    |> R.bind(fn
      {:"$dist_agent_check_quota", pending_index} -> check_quota_for_new_agent_id(id, pending_index, options)
      :"$dist_agent_quota_limit_reached"          -> {:error, :quota_limit_reached}
      :"$dist_agent_retry"                        -> :timer.sleep(200); command(quota_name, callback_module, agent_key, command, options) # shouldn't happen, retry indefinitely
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

  @doc """
  """
  defun query(quota_name      :: v[QName.t],
              callback_module :: v[module],
              agent_key       :: v[String.t],
              query           :: Behaviour.query,
              options         :: [RaftKV.option] \\ []) :: {:ok, Behaviour.ret} | {:error, :agent_not_found | :no_leader} do
    id = {quota_name, callback_module, agent_key}
    options = Keyword.put_new(options, :call_module, BatchedCommunication)
    case RaftKV.query(:dist_agent, id, query, options) do
      {:ok, result}            -> result
      {:error, :key_not_found} -> {:error, :agent_not_found}
      {:error, _} = e          -> e
    end
  end
end
