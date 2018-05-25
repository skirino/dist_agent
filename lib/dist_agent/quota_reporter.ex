use Croma

defmodule DistAgent.Quota.Reporter do
  use GenServer
  alias DistAgent.{Quota, Config}
  alias DistAgent.Quota.CountsMap
  alias DistAgent.Quota.Name, as: QName

  def start_link([]) do
    GenServer.start_link(__MODULE__, :ok, [name: __MODULE__])
  end

  @impl true
  def init(:ok) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:init, state) do
    {:noreply, state, Config.quota_collection_interval()}
  end

  @impl true
  def handle_info(:timeout, state) do
    spawn(fn -> report_agent_counts() end)
    {:noreply, state, Config.quota_collection_interval()}
  end

  defp report_agent_counts() do
    {counts_map, owner_shards_map} = compute_counts()
    nonexisting_qnames = Quota.report_local_counts(counts_map)
    Enum.each(nonexisting_qnames, fn qname ->
      Map.fetch!(owner_shards_map, qname)
      |> Enum.each(fn shard_name ->
        RaftKV.command_on_all_keys_in_shard(shard_name, {:"$dist_agent_remove_quota", qname})
      end)
    end)
  end

  defunp compute_counts() :: {CountsMap.t, %{QName.t => [atom]}} do
    RaftKV.reduce_keyspace_shard_names(:dist_agent, {%{}, %{}}, fn(shard_name, {counts_map, owner_shards_map}) ->
      case RaftedValue.query(shard_name, :list_keys) do
        {:ok, {l1, l2}} ->
          %{}
          |> accumulate(l1)
          |> accumulate(l2)
          |> Enum.reduce({counts_map, owner_shards_map}, fn({q, n}, {cs, os}) ->
            {Map.update(cs, q, n, &(&1 + n)), Map.update(os, q, [shard_name], &[shard_name | &1])}
          end)
        {:error, _} ->
          {counts_map, owner_shards_map}
      end
    end)
  end

  defp accumulate(map, ids) do
    Enum.reduce(ids, map, fn({qname, _, _}, m) -> Map.update(m, qname, 1, &(&1 + 1)) end)
  end

  #
  # API
  #
  defun init() :: :ok do
    GenServer.cast(__MODULE__, :init)
  end
end
