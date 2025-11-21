import Config

config :logger,
  backends: [:console],
  compile_time_purge_matching: [
    [level_lower_than: :info]
  ]

# Log to syslog in production
if config_env() == :prod do
  config :logger,
    handle_otp_reports: true,
    handle_sasl_reports: true
end

import_config "#{config_env()}.exs"
