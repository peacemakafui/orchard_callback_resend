defmodule OrchardResend.Repo do
  use Ecto.Repo,
    otp_app: :orchard_resend,
    adapter: Ecto.Adapters.Postgres
end
