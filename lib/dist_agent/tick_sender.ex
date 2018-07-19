use Croma

defmodule DistAgent.TickSender do
  use GenServer
  alias DistAgent.Config

  def start_link([]) do
    GenServer.start_link(__MODULE__, :ok, [name: __MODULE__])
  end

  @impl true
  def init(:ok) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:init, state) do
    {:noreply, state, Config.tick_interval()}
  end

  @impl true
  def handle_info(:timeout, state) do
    spawn(fn -> send_tick() end)
    {:noreply, state, Config.tick_interval()}
  end

  defp send_tick() do
    RaftKV.reduce_keyspace_shard_names(:dist_agent, :ok, fn(shard_name, :ok) ->
      # send command to local leaders (by using internal protocol of `RaftKV.command_on_all_keys_in_shard/3`)
      _ = RaftedValue.command(shard_name, {:all_keys_command, {:"$dist_agent_tick", System.system_time(:millisecond)}})
      :ok
    end)
  end

  #
  # API
  #
  defun init() :: :ok do
    GenServer.cast(__MODULE__, :init)
  end
end
