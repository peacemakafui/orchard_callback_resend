defmodule OrchardResend.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      OrchardResend.Repo,
      # Auto-start daemon
      {OrchardResend.ResenderDaemon, [
        check_interval: 60_000,    # Check every 60 seconds
        batch_size: 1000,
        concurrency: 20,
        timeout: 60_000,
        batch_delay: 1_000
      ]}
    ]

    opts = [strategy: :one_for_one, name: OrchardResend.Supervisor]
    Logger.info("Starting OrchardResend application with daemon...")
    Supervisor.start_link(children, opts)
  end
end
