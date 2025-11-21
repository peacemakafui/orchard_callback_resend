defmodule OrchardResend.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      OrchardResend.Repo
    ]

    opts = [strategy: :one_for_one, name: OrchardResend.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
