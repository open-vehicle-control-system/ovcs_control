defmodule PidSimulatorWeb.Layouts do
  use Phoenix.Component
  import Plug.CSRFProtection, only: [get_csrf_token: 0]

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>PID Simulator</title>
        <script src="https://cdn.tailwindcss.com">
        </script>
        <script src="https://cdn.jsdelivr.net/npm/chart.js@4">
        </script>
        <script defer type="text/javascript" src="/assets/app.js">
        </script>
      </head>
      <body class="bg-gray-900 text-white">
        <%= @inner_content %>
      </body>
    </html>
    """
  end
end
