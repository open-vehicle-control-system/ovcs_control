defmodule PidSimulatorWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :pid_simulator

  @session_options [
    store: :cookie,
    key: "_pid_simulator_key",
    signing_salt: "pid_sim"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :pid_simulator,
    gzip: false,
    only: ~w(assets)

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug PidSimulatorWeb.Router
end
