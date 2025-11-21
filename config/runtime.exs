import Config

config :orchard_resend, OrchardResend.Repo,
  database: System.get_env("M_DB_NAME"),
  username: System.get_env("M_DB_USER"),
  password: System.get_env("M_DB_PASSWORD"),
  hostname: System.get_env("M_DB_HOST"),
  port: System.get_env("M_DB_PORT") |> String.to_integer(),
  prepare: :unnamed,
  pool_size: 10

config :logger,
  level: :info
