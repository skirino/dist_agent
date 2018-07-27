defmodule DistAgent.Behaviour do
  @moduledoc """
  Behaviour module for distributed agents.

  The 6 callbacks are classified into the following 2 dimensions:

  - how the callback is used, i.e., for pure manipulation of state or for side effect
  - when the callback is used, i.e., type of event that triggers the callback

  The following table summarizes the classification:

    |                                           | for pure state manipulation | for side effect     |
    | ----------------------------------------- | --------------------------- | ------------------- |
    | used when `DistAgent.query/5` is called   | `c:handle_query/4`          | `c:after_query/5`   |
    | used when `DistAgent.command/5` is called | `c:handle_command/4`        | `c:after_command/6` |
    | used when a low-resolution timer fires    | `c:handle_timeout/4`        | `c:after_timeout/5` |
  """

  alias DistAgent.OnTick
  alias DistAgent.Quota.Name, as: QName

  @type agent_key                :: String.t
  @type data                     :: any
  @type command                  :: any
  @type query                    :: any
  @type ret                      :: any
  @type milliseconds_since_epoch :: pos_integer

  @doc """
  Invoked to handle an incoming read-only query.

  Implementations of this callback must be pure.

  The callback takes the following arguments:

  - 1st argument is the name of the quota in which this distributed agent belongs.
  - 2nd argument is the key of the agent.
  - 3rd argument is the state of the agent.
  - 4th argument is the `query` passed to the `DistAgent.query/5`.

  Return value of this callback is delivered to the caller process of `DistAgent.query/5`.
  """
  @callback handle_query(quota_name :: QName.t, agent_key, data, query) :: ret

  @doc """
  Invoked to handle an incoming command.

  Implementations of this callback must be pure.

  The callback takes the following arguments:

  - 1st argument is the name of the quota in which this distributed agent belongs.
  - 2nd argument is the key of the agent.
  - 3rd argument is the state of the agent.
    This is `nil` if the agent is right after its activation.
  - 4th argument is the `command` passed to the `DistAgent.command/5`.

  Return value of this callback must be a 3-tuple.

  - 1st element is returned to the caller of `DistAgent.command/5`.
  - 2nd element is the state after the command is applied; if this value is `nil` then the distributed agent is deactivated.
  - 3rd element specifies what happens at the subsequent ticks.
    You may specify either `t:DistAgent.OnTick.t/0` or `:keep`, where `:keep` respects the previously set `t:DistAgent.OnTick.t/0`.
  """
  @callback handle_command(quota_name :: QName.t, agent_key, nil | data, command) :: {ret, nil | data, OnTick.t | :keep}

  @doc """
  Invoked when a low-resolution timer fires.

  Implementations of this callback must be pure.

  The callback takes the following arguments:

  - 1st argument is the name of the quota in which this distributed agent belongs.
  - 2nd argument is the key of the agent.
  - 3rd argument is the state of the agent.
  - 4th argument is the time (milliseconds since UNIX epoch) in UTC time zone at which the tick starts.
    Note that this value is not very accurate as it's obtained by a separate process (`DistAgent.TickSender`);
    it only indicates that current time is at least as large as this value.

  Return value of this callback must be a 2-tuple.

  - 1st element is the state after the timeout; if this value is `nil` then the distributed agent is deactivated.
  - 2nd element specifies what happens at the subsequent ticks.
    See `t:DistAgent.OnTick.t/0` for more details.
  """
  @callback handle_timeout(QName.t, agent_key, data, milliseconds_since_epoch) :: {nil | data, OnTick.t}

  @doc """
  Invoked after `handle_query/2`.

  Implementations of this callback can have side effects.
  Note that this callback should avoid long running operations to keep distributed agents responsive;
  delegate such operations to other processes instead.

  The callback takes the following arguments:

  - 1st argument is the name of the quota in which this distributed agent belongs.
  - 2nd argument is the key of the agent.
  - 3rd argument is the state of the agent.
  - 4th argument is the `query` passed to the `DistAgent.query/5`.
  - 5th argument is the return value to the client process, computed by `c:handle_query/4`.

  Return value of this callback is neglected.
  """
  @callback after_query(quota_name :: QName.t, agent_key, data, query, ret) :: any

  @doc """
  Invoked after `handle_command/2`.

  Implementations of this callback can have side effects.
  Note that this callback should avoid long running operations to keep distributed agents responsive;
  delegate such operations to other processes instead.

  The callback takes the following arguments:

  - 1st argument is the name of the quota in which this distributed agent belongs.
  - 2nd argument is the key of the agent.
  - 3rd argument is the state of the agent before the command is applied.
    This is `nil` if the agent is right after its activation.
  - 4th argument is the `command` passed to the `DistAgent.command/5`.
  - 5th argument is the return value to the client process (1st element of return value of `c:handle_command/4`).
  - 6th argument is the state of the distributed agent after the command is applied (2nd element of return value of `c:handle_command/4`).

  Return value of this callback is neglected.
  """
  @callback after_command(quota_name :: QName.t, agent_key, data_before :: nil | data, command :: command, ret :: ret, data_after :: nil | data) :: any

  @doc """
  Invoked after `handle_timeout/2`.

  Implementations of this callback can have side effects.
  Note that this callback should avoid long running operations to keep distributed agents responsive;
  delegate such operations to other processes instead.

  The callback takes the following arguments:

  - 1st argument is the name of the quota in which this distributed agent belongs.
  - 2nd argument is the key of the agent.
  - 3rd argument is the state of the agent before the timeout.
  - 4th argument is the same timestamp passed to `c:handle_timeout/4`.
  - 5th argument is the state of the distrubuted agent after the timeout (1st element of return value of `c:handle_timeout/4`).

  Return value of this callback is neglected.
  """
  @callback after_timeout(quota_name :: QName.t, agent_key, data_before :: data, now_millis :: milliseconds_since_epoch, data_after :: nil | data) :: any
end
