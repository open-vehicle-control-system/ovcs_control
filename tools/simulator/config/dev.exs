import Config

config :pid_simulator, PidSimulatorWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  check_origin: false,
  code_reloader: false,
  debug_errors: true,
  secret_key_base: "pid_simulator_dev_secret_key_base_that_is_at_least_64_bytes_long_for_security!!",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:default, ~w(--sourcemap=inline --watch)]}
  ]

config :logger, :console, format: "[$level] $message\n", level: :info
