defmodule DistAgentTest do
  use ExUnit.Case

  @q "dist_agent_test"

  setup_all do
    assert DistAgent.put_quota(@q, :infinity) == :ok
    on_exit(fn ->
      assert DistAgent.delete_quota(@q) == :ok
    end)
  end

  setup do
    Process.register(self(), :test_runner)
    on_exit(fn ->
      refute_received(_)
    end)
  end

  test "should trigger after_command and after_query hooks" do
    assert DistAgent.command(@q, A, "k1", "value") == {:ok, :ok}
    assert_receive({:after_command, nil, "value", :ok, "value"})
    assert DistAgent.query(@q, A, "k1", :get) == {:ok, "value"}
    assert_receive({:after_query, "value", :get, "value"})
  end

  test "should terminate itself when `nil` is specified as the new state" do
    assert DistAgent.command(@q, A, "k2", "value") == {:ok, :ok}
    assert_receive({:after_command, nil, "value", :ok, "value"})
    assert DistAgent.command(@q, A, "k2", nil) == {:ok, :ok}
    assert_receive({:after_command, "value", nil, :ok, nil})
    assert DistAgent.query(@q, A, "k2", :get) == {:error, :agent_not_found}
  end

  defp timeout_in_tick_sender() do
    send(DistAgent.TickSender, :timeout)
    _ = :sys.get_state(DistAgent.TickSender)
  end

  test "should trigger timeout after specified ticks" do
    # set `on_tick` by command
    to2 = {:timeout, 2}
    assert DistAgent.command(@q, A, "k3", to2) == {:ok, :ok}
    assert_receive({:after_command, nil, ^to2, :ok, ^to2})
    timeout_in_tick_sender() # 2 => 1
    timeout_in_tick_sender() # 1 => 0
    timeout_in_tick_sender() # 0: timeout
    assert_receive({:after_timeout, ^to2, _, ^to2})

    # `on_tick` is set again by `handle_timeout/2`
    timeout_in_tick_sender() # 2 => 1
    timeout_in_tick_sender() # 1 => 0
    timeout_in_tick_sender() # 0: timeout
    assert_receive({:after_timeout, ^to2, _, ^to2})

    # override `on_tick` by command
    to1 = {:timeout, 1}
    assert DistAgent.command(@q, A, "k3", to1) == {:ok, :ok}
    assert_receive({:after_command, ^to2, ^to1, :ok, ^to1})
    timeout_in_tick_sender() # 1 => 0
    timeout_in_tick_sender() # 0: timeout
    assert_receive({:after_timeout, ^to1, _, ^to1})

    # deactivate itself by returning `nil` in `handle_timeout/2`
    assert DistAgent.command(@q, A, "k3", :deactivate) == {:ok, :ok}
    assert_receive({:after_command, ^to1, :deactivate, :ok, :deactivate})
    timeout_in_tick_sender() # 1 => 0
    timeout_in_tick_sender() # 0: timeout
    assert_receive({:after_timeout, :deactivate, _, nil})
    assert DistAgent.query(@q, A, "k3", :get) == {:error, :agent_not_found}
  end

  test "should deactivate itself after specified ticks" do
    da2 = {:deactivate, 2}
    assert DistAgent.command(@q, A, "k4", da2) == {:ok, :ok}
    assert_receive({:after_command, nil, ^da2, :ok, ^da2})
    timeout_in_tick_sender() # 2 => 1
    timeout_in_tick_sender() # 1 => 0
    timeout_in_tick_sender() # 0: timeout
    assert DistAgent.query(@q, A, "k3", :get) == {:error, :agent_not_found}
  end
end
