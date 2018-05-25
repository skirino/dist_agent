use Croma

defmodule DistAgent.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DistAgent.Quota.Reporter,
      DistAgent.TickSender,
    ]
    Supervisor.start_link(children, [strategy: :one_for_one])
  end
end
