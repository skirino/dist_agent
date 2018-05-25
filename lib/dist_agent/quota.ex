use Croma

defmodule DistAgent.Quota do
  alias RaftedValue.Data, as: RVData
  alias DistAgent.Id
  alias DistAgent.Quota.Name, as: QName
  alias DistAgent.Quota.Limit, as: QLimit
  alias DistAgent.Quota.CountsMap, as: QCountsMap

  @per_node_counts_lifetime 15 * 60_000

  defmodule CountsAndTimestamp do
    use Croma.SubtypeOfTuple, elem_modules: [QCountsMap, Croma.PosInteger]
  end

  defmodule NodesMap do
    use Croma.SubtypeOfMap, key_module: Croma.Atom, value_module: CountsAndTimestamp
  end

  defmodule LimitsMap do
    use Croma.SubtypeOfMap, key_module: QName, value_module: QLimit
  end

  use Croma.Struct, fields: [
    nodes_map:  NodesMap,
    limits_map: LimitsMap,
  ]

  @behaviour RVData

  @impl true
  defun new() :: t do
    %__MODULE__{nodes_map: %{}, limits_map: %{}}
  end

  @impl true
  defun command(%__MODULE__{limits_map: ls} = state, arg :: RVData.command_arg) :: {RVData.command_ret, t} do
    case arg do
      {:add_stats, node, map, time} -> add_stats(state, node, map, time)
      {:put_quota, qname, limit}    -> {:ok, %__MODULE__{state | limits_map: Map.put(ls, qname, limit)}}
      {:delete_quota, qname}        -> {:ok, %__MODULE__{state | limits_map: Map.delete(ls, qname)}}
      _                             -> {:ok, state} # in order not to crash on unexpected command
    end
  end

  defp add_stats(%__MODULE__{nodes_map: ns, limits_map: ls} = state, node, map1, time) do
    {map2, nonexisting_qnames} =
      Enum.reduce(map1, {%{}, []}, fn({q, c}, {m, qs}) ->
        case Map.has_key?(ls, q) do
          true  -> {Map.put(m, q, c), qs      }
          false -> {m               , [q | qs]}
        end
      end)
    new_ns = ns |> remove_expired(time) |> Map.put(node, {map2, time})
    {nonexisting_qnames, %__MODULE__{state | nodes_map: new_ns}}
  end

  defp remove_expired(ns, time) do
    threshold = time - @per_node_counts_lifetime
    for {n, {_m, t} = pair} when threshold < t <- ns, into: %{}, do: {n, pair}
  end

  @impl true
  defun query(state :: v[t], arg :: RVData.query_arg) :: RVData.query_ret do
    case arg do
      {:quota_usage, qname} -> quota_usage(state, qname)
      :list_quotas          -> Map.keys(state.limits_map)
      _                     -> :ok # in order not to crash on unexpected query
    end
  end

  defunp quota_usage(%__MODULE__{nodes_map: ns, limits_map: ls}, qname :: v[QName.t]) :: nil | {non_neg_integer, QLimit.t} do
    case Map.get(ls, qname) do
      nil   -> nil
      limit -> {current_total(ns, qname), limit}
    end
  end

  defunp current_total(ns :: v[NodesMap.t], qname :: v[QName.t]) :: non_neg_integer do
    Enum.reduce(ns, 0, fn({_node, {counts, _t}}, acc) ->
      acc + Map.get(counts, qname, 0)
    end)
  end

  #
  # API
  #
  defun add_consensus_group() :: :ok | {:error, :already_added} do
    rv_options = [
      communication_module:                BatchedCommunication,
      heartbeat_timeout:                   500,
      election_timeout:                    2_000,
      election_timeout_clock_drift_margin: 500,
    ]
    rv_config = RaftedValue.make_config(__MODULE__, rv_options)
    RaftFleet.add_consensus_group(__MODULE__, 3, rv_config)
  end

  defun report_local_counts(m :: v[QCountsMap.t]) :: [QName.t] do
    {:ok, nonexisting_qnames} = RaftFleet.command(__MODULE__, {:add_stats, Node.self(), m, System.system_time(:milliseconds)})
    nonexisting_qnames
  end

  defun query_status({qname, _mod, _key} :: Id.t) :: :ok | :not_found | :limit_reached do
    case RaftFleet.query(__MODULE__, {:quota_usage, qname}) do
      {:ok, nil   } -> :not_found
      {:ok, {n, d}} -> if n < d, do: :ok, else: :limit_reached
      {:error, _}   -> :ok # Something is wrong! In this case we don't block creation of new distributed agent (as the limit is a soft one after all)
    end
  end
end
