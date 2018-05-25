ExUnit.start()

:ok = RaftFleet.activate("zone")
:timer.sleep(100)
:ok = RaftKV.init()
:ok = DistAgent.init()

defmodule A do
  @behaviour DistAgent.Behaviour

  @impl true
  def handle_query(data, _query) do
    data
  end

  @impl true
  def handle_command(_data, value) do
    on_tick =
      case value do
        {:timeout   , n} -> {:timeout   , n}
        {:deactivate, n} -> {:deactivate, n}
        _                -> :keep
      end
    {:ok, value, on_tick}
  end

  @impl true
  def handle_timeout(data, _now_millis) do
    case data do
      :deactivate   -> {nil , nil}
      {:timeout, n} -> {data, {:timeout, n}}
      _             -> {data, nil}
    end
  end

  @impl true
  def after_query(data, query, ret) do
    send({:after_query, data, query, ret})
  end

  @impl true
  def after_command(data_before, command, ret, data_after) do
    send({:after_command, data_before, command, ret, data_after})
  end

  @impl true
  def after_timeout(data_before, now_millis, data_after) do
    send({:after_timeout, data_before, now_millis, data_after})
  end

  defp send(msg) do
    try do
      send(:test_runner, msg)
    rescue
      _no_registered_process -> :ok
    end
  end
end
