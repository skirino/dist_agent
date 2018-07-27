use Croma

defmodule DistAgent.State do
  alias RaftKV.{ValuePerKey, LeaderHook}
  alias DistAgent.{Id, Behaviour, OnTick}

  @type pending_commands :: %{non_neg_integer => Behaviour.command}

  @type t :: {:preparing, pending_commands, OnTick.tick_count}
           | {:ok, Behaviour.data, pending_commands, OnTick.t}

  defun valid?(v :: any) :: boolean do
    {:preparing, _cmds, _count}   -> true
    {:ok, _data, _cmds, _on_tick} -> true
    _                             -> false
  end

  #
  # command/query (pure state manipulation)
  #
  @behaviour ValuePerKey

  @typep tuple4 :: {ValuePerKey.command_ret, ValuePerKey.load, nil | t, ValuePerKey.size}

  defp to_tuple4({ret, state}, load \\ 0) do
    {ret, load, state, 0}
  end

  @impl ValuePerKey
  defun command(state                :: v[nil | t],
                _size                :: ValuePerKey.size,
                {q, _mod, _key} = id :: Id.t,
                arg                  :: ValuePerKey.command_arg) :: tuple4 do
    case arg do
      {:"$dist_agent_tick", time}              -> {:ok, handle_tick(state, id, time)}          |> to_tuple4()
      {:"$dist_agent_quota_ok", pending_index} -> handle_quota_ok(state, id, pending_index)    |> to_tuple4()
      {:"$dist_agent_quota_ng", pending_index} -> handle_quota_ng(state, id, pending_index)    |> to_tuple4()
      :"$dist_agent_quota_not_found"           -> {:ok, nil}                                   |> to_tuple4()
      {:"$dist_agent_remove_quota", qname}     -> {:ok, (if qname == q, do: nil, else: state)} |> to_tuple4()
      cmd                                      -> handle_command(state, id, cmd)
    end
  end

  defunp handle_tick(state :: v[t], id :: v[Id.t], time :: v[pos_integer]) :: nil | t do
    case state do
      {:preparing, cmds, tick_count} ->
        case tick_count do
          0 -> nil
          _ -> {:preparing, cmds, tick_count - 1}
        end
      {:ok, data, cmds, on_tick} ->
        case on_tick do
          nil                       -> state
          {:timeout   , 0         } -> handle_timeout(state, id, time)
          {:timeout   , tick_count} -> {:ok, data, cmds, {:timeout, tick_count - 1}}
          {:deactivate, 0         } -> nil
          {:deactivate, tick_count} -> {:ok, data, cmds, {:deactivate, tick_count - 1}}
        end
    end
  end

  defunp handle_timeout({:ok, data, cmds, {:timeout, 0}} :: t, {qname, mod, key} :: Id.t, time :: v[pos_integer]) :: t do
    case mod.handle_timeout(qname, key, data, time) do
      {nil     , _on_tick} -> nil
      {new_data, on_tick } -> {:ok, new_data, cmds, validate_on_tick(on_tick)}
    end
  end

  defunp handle_quota_ok(state :: v[nil | t], id :: v[Id.t], pending_index :: v[non_neg_integer]) :: {ValuePerKey.command_ret, nil | t} do
    case state do
      nil                        -> {:"$dist_agent_retry", nil}
      {:preparing, cmds, _count} ->
        case Map.pop(cmds, pending_index) do
          {nil, _       } -> {:"$dist_agent_retry", state}
          {cmd, new_cmds} -> run_command({:ok, nil, new_cmds, nil}, id, cmd)
        end
      {:ok, data, cmds, on_tick} ->
        case Map.pop(cmds, pending_index) do
          {nil, _       } -> {:"$dist_agent_retry", state}
          {cmd, new_cmds} -> run_command({:ok, data, new_cmds, on_tick}, id, cmd)
        end
    end
  end

  defunp handle_quota_ng(state :: v[nil | t], id :: v[Id.t], pending_index :: v[non_neg_integer]) :: {ValuePerKey.command_ret, nil | t} do
    case state do
      nil                         -> {:"$dist_agent_retry", nil}
      {:preparing, _cmds, _count} -> {:"$dist_agent_quota_limit_reached", nil}
      {:ok, data, cmds, on_tick}  ->
        case Map.pop(cmds, pending_index) do
          {nil, _       } -> {:"$dist_agent_retry", state}
          {cmd, new_cmds} -> run_command({:ok, data, new_cmds, on_tick}, id, cmd) # quota check by the current client failed but another client had already passed
        end
    end
  end

  defunp handle_command(state :: v[nil | t], id :: v[Id.t], cmd :: Behaviour.command) :: {Behaviour.ret, ValuePerKey.load, nil | t, ValuePerKey.size} do
    case state do
      nil                        -> force_client_to_check_quota_limit(%{} , cmd) |> to_tuple4()
      {:preparing, cmds, _count} -> force_client_to_check_quota_limit(cmds, cmd) |> to_tuple4()
      _                          -> run_command(state, id, cmd)                 |> to_tuple4(3)
    end
  end

  defp force_client_to_check_quota_limit(cmds, cmd) do
    index = map_size(cmds)
    {{:"$dist_agent_check_quota", index}, {:preparing, Map.put(cmds, index, cmd), 1}}
  end

  defp run_command({:ok, data, cmds, on_tick}, {qname, mod, key}, cmd) do
    {ret, new_data, on_tick_or_keep} = mod.handle_command(qname, key, data, cmd)
    case new_data do
      nil -> {ret, nil}
      _   -> {ret, {:ok, new_data, cmds, next_on_tick(on_tick, on_tick_or_keep)}}
    end
  end

  defunp validate_on_tick(on_tick :: v[OnTick.t]) :: OnTick.t do
    on_tick
  end

  defunp next_on_tick(on_tick :: v[OnTick.t], on_tick_or_keep :: v[:keep | OnTick.t]) :: OnTick.t do
    case on_tick_or_keep do
      :keep       -> on_tick
      new_on_tick -> new_on_tick
    end
  end

  @impl ValuePerKey
  defun query(state             :: v[t],
              _size             :: ValuePerKey.size,
              {qname, mod, key} :: Id.t,
              query             :: Behaviour.query) :: {ValuePerKey.query_ret, ValuePerKey.load} do
    result =
      case state do
        {:ok, data, _cmds, _on_tick} -> {:ok, mod.handle_query(qname, key, data, query)}
        _otherwise                   -> {:error, :id_not_found}
      end
    {result, 1}
  end

  #
  # side-effecting hooks
  #
  @behaviour LeaderHook

  @impl LeaderHook
  defun on_command_committed(state_before      :: v[nil | t],
                             _size_before      :: ValuePerKey.size,
                             {qname, mod, key} :: Id.t,
                             arg               :: ValuePerKey.command_arg,
                             ret               :: ValuePerKey.command_ret,
                             state_after       :: v[nil | t],
                             _size_after       :: ValuePerKey.size) :: any do
    case arg do
      {:"$dist_agent_tick", time} ->
        case state_before do
          {:ok, d, _cmds, {:timeout, 0}} -> mod.after_timeout(qname, key, d, time, get_data(state_after))
          _                              -> :ok
        end
      {:"$dist_agent_quota_ok", pending_index} ->
        case state_before do
          {:preparing, %{^pending_index => cmd}, _count} -> mod.after_command(qname, key, nil, cmd, ret, get_data(state_after))
          {:ok, d, %{^pending_index => cmd}, _on_tick}   -> mod.after_command(qname, key, d  , cmd, ret, get_data(state_after))
          _                                              -> :ok
        end
      {:"$dist_agent_quota_ng", pending_index} ->
        case state_before do
          {:ok, d, %{^pending_index => cmd}, _on_tick} -> mod.after_command(qname, key, d, cmd, ret, get_data(state_after))
          _                                            -> :ok
        end
      :"$dist_agent_quota_not_found" ->
        :ok
      {:"$dist_agent_remove_quota", _qname} ->
        :ok
      cmd ->
        case {state_before, state_after} do
          {{:ok, d1, _c1, _o1}, {:ok, d2, _c2, _o2}} -> mod.after_command(qname, key, d1, cmd, ret, d2 )
          {{:ok, d1, _c1, _o1}, nil                } -> mod.after_command(qname, key, d1, cmd, ret, nil)
          _                                          -> :ok
        end
    end
  end

  defp get_data(nil                     ), do: nil
  defp get_data({_t, d, _cmds, _on_tick}), do: d

  @impl LeaderHook
  defun on_query_answered(state             :: v[t],
                          _size             :: ValuePerKey.size,
                          {qname, mod, key} :: Id.t,
                          query             :: ValuePerKey.query_arg,
                          ret               :: ValuePerKey.query_ret) :: any do
    case state do
      {:preparing, _cmds, _count} -> {:error, :id_not_found}
      {:ok, d, _cmds, _on_tick}   ->
        {:ok, r} = ret
        mod.after_query(qname, key, d, query, r)
    end
  end
end
