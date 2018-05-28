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
  """

  defun tick_interval() :: pos_integer do
    Application.get_env(:dist_agent, :tick_interval, @default_tick_interval)
  end

  defun quota_collection_interval() :: pos_integer do
    Application.get_env(:dist_agent, :quota_collection_interval, @default_quota_collection_interval)
  end
end
