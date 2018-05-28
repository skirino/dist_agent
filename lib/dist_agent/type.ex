use Croma

defmodule DistAgent.Quota.Name do
  use Croma.SubtypeOfString, pattern: ~r/.*/
end

defmodule DistAgent.Quota.Limit do
  @type t :: non_neg_integer | :infinity

  defun valid?(v :: term) :: boolean do
    i when is_integer(i) and i >= 0 -> true
    :infinity                       -> true
    _                               -> false
  end
end

defmodule DistAgent.Quota.CountsMap do
  use Croma.SubtypeOfMap, key_module: DistAgent.Quota.Name, value_module: Croma.NonNegInteger
end

defmodule DistAgent.Id do
  use Croma.SubtypeOfTuple, elem_modules: [DistAgent.Quota.Name, Croma.Atom, Croma.String]
end

defmodule DistAgent.OnTick do
  @type tick_count :: non_neg_integer

  @typedoc """
  A type describing what a distributed agent does at the subsequent ticks.

  Available values are:

  - `nil`
      - Do nothing.
  - `{:timeout, tick_count}`
      - Invoke timeout after at least `tick_count` tick intervals.
        For example, `{:timeout, 0}` means that timeout is invoked at the next tick,
        `{:timeout, 1}` means that timeout is invoked at the next next tick, and so on.
  - `{:deactivate, tick_count}`
      - Deactivate this distributed agent after at least `tick_count` tick intervals.
        For example, `{:deactivate, 0}` means that the agent is deactivated at the next tick,
        `{:deactivate, 1}` means that the agent is deactivated at the next next tick, and so on.
  """
  @type t :: nil | {:timeout, tick_count} | {:deactivate, tick_count}

  defun valid?(v :: term) :: boolean do
    nil                                                        -> true
    {:timeout   , count} when is_integer(count) and 0 <= count -> true
    {:deactivate, count} when is_integer(count) and 0 <= count -> true
    _                                                          -> false
  end
end
