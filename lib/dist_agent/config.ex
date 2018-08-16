use Croma

defmodule DistAgent.Config do
  @default_tick_interval             (if Mix.env() == :test, do: 1_000, else:     60_000)
  @default_quota_collection_interval (if Mix.env() == :test, do: 1_000, else: 5 * 60_000)

  @moduledoc """
  `dist_agent` defines the following application configs:

  - `:tick_interval`
    Time interval (in milliseconds) between periodic tick events.
    Defaults to `#{@default_tick_interval}`.
    By using smaller value you can increase the precision of low-resolution timers with higher overhead.
  - `:quota_collection_interval`
    Time interval (in milliseconds) between periodic collections of number of distributed agent.
    Defaults to `#{@default_quota_collection_interval}`.
    By using smaller value you can get more accurate view of total number of distributed agents with higher overhead.

  Note that each `dist_agent` process uses application configs stored in the local node.
  If you want to configure the options above you must set them on all nodes in your cluster.

  In addition to the configurations above, the following configurations defined by the underlying libraries are also available:

  - `RaftFleet.Config`
  - `RaftKV.Config`

  ## About `:rafted_value_config_maker` option for `:raft_fleet`

  `:raft_fleet` provides a way to configure each consensus group by setting an implementation of `RaftFleet.RaftedValueConfigMaker` behaviour
  as `:rafted_value_config_maker` option.
  `:dist_agent` and underlying `:raft_kv` respect this option; they use the callback module (if any)
  when creating a `t:RaftedValue.Config.t/0`.
  `:dist_agent` defines `DistAgent.Quota` as a consensus group, and in order to construct a `t:RaftedValue.Config.t/0`
  for `DistAgent.Quota` in your implementation of `RaftFleet.RaftedValueConfigMaker` behaviour,
  you can use `DistAgent.Quota.make_rv_config/1`.
  See also the moduledoc of `RaftKV.Config`.
  """

  defun tick_interval() :: pos_integer do
    Application.get_env(:dist_agent, :tick_interval, @default_tick_interval)
  end

  defun quota_collection_interval() :: pos_integer do
    Application.get_env(:dist_agent, :quota_collection_interval, @default_quota_collection_interval)
  end
end
