defmodule DistAgent.Behaviour do
  alias DistAgent.OnTick

  @type data                     :: any
  @type command                  :: any
  @type query                    :: any
  @type ret                      :: any
  @type milliseconds_since_epoch :: pos_integer

  # pure callbacks
  @callback handle_query(data, query) :: ret
  @callback handle_command(nil | data, command) :: {ret, nil | data, OnTick.t | :keep}
  @callback handle_timeout(data, milliseconds_since_epoch) :: {nil | data, OnTick.t}

  # callbacks for side-effects
  @callback after_query(data, query, ret) :: any
  @callback after_command(data_before :: nil | data, command :: command, ret :: ret, data_after :: nil | data) :: any
  @callback after_timeout(data_before :: data, now_millis :: milliseconds_since_epoch, data_after :: nil | data) :: any
end
