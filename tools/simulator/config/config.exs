import Config

config :pid_simulator, PidSimulatorWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [formats: [html: PidSimulatorWeb.ErrorHTML], layout: false],
  pubsub_server: PidSimulator.PubSub,
  live_view: [signing_salt: "pid_sim_salt"]

config :esbuild,
  version: "0.17.11",
  default: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :phoenix, :json_library, Jason

config :logger, :console,
  format: "[$level] $message\n"

import_config "#{config_env()}.exs"
