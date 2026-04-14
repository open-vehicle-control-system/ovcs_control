defmodule PidSimulatorWeb.SimulatorLive do
  use Phoenix.LiveView
  alias OvcsControl.PID, as: PIDController
  alias OvcsControl.InputFilter
  alias Decimal, as: D

  @tick_ms 20
  @dt D.new("0.02")
  @settling_band 0.05

  @default_kp "1.0"
  @default_ki "0.0"
  @default_kd "0.0"
  @default_deadband "0.02"
  @default_smoothing_alpha "0.15"
  @default_reset_derivative_on_setpoint_change true
  # Plant model: full_traverse_time is how many seconds the actuator takes to go
  # from one extreme to the other at max PID output.
  # Measure on real hardware or estimate from specs.
  # Examples: steering column ~2s lock-to-lock, iBooster rod ~1s full travel
  @default_full_traverse_time "2.0"
  @min_alpha 0.01 # Below this the filter barely moves, effectively frozen
  @max_alpha 1.0  # No smoothing, raw passthrough

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket,
      kp: @default_kp,
      ki: @default_ki,
      kd: @default_kd,
      setpoint: 0.0,
      filtered_setpoint: 0.0,
      deadband: @default_deadband,
      smoothing: @default_smoothing_alpha,
      reset_derivative_on_setpoint_change: @default_reset_derivative_on_setpoint_change,
      full_traverse_time: @default_full_traverse_time,
      input_filter: new_input_filter(@default_deadband, @default_smoothing_alpha),
      measurement: D.new("0"),
      pid_state: nil,
      running: false,
      time: 0.0,
      metrics: initial_metrics()
    )
    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket,
      kp: params["kp"] || socket.assigns.kp,
      ki: params["ki"] || socket.assigns.ki,
      kd: params["kd"] || socket.assigns.kd,
      deadband: params["deadband"] || socket.assigns.deadband,
      smoothing: params["smoothing"] || socket.assigns.smoothing,
      full_traverse_time: params["full_traverse_time"] || socket.assigns.full_traverse_time,
      reset_derivative_on_setpoint_change: parse_bool(params["reset_d"], socket.assigns.reset_derivative_on_setpoint_change)
    )
    {:noreply, socket}
  end

  defp initial_metrics do
    %{
      peak_overshoot: 0.0,
      oscillation_count: 0,
      prev_error_sign: nil,
      rise_time: nil,
      settling_time: nil,
      setpoint_change_time: nil,
      prev_setpoint: 0.0,
      rise_achieved: false,
      last_outside_band_time: nil,
      steady_state_error: 0.0,
      hints: ["Set a setpoint and click Start to begin analysis"]
    }
  end

  @impl true
  def handle_event("start", _params, %{assigns: %{running: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("start", _params, socket) do
    pid = PIDController.new(
      kp: D.new(socket.assigns.kp),
      ki: D.new(socket.assigns.ki),
      kd: D.new(socket.assigns.kd),
      reset_derivative_when_setpoint_changes: socket.assigns.reset_derivative_on_setpoint_change
    )
    input_filter = new_input_filter(socket.assigns.deadband, socket.assigns.smoothing, socket.assigns.setpoint)
    socket = assign(socket,
      pid_state: pid,
      running: true,
      measurement: D.new("0"),
      filtered_setpoint: socket.assigns.setpoint,
      input_filter: input_filter,
      time: 0.0,
      metrics: initial_metrics()
    )
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, push_event(socket, "clear-chart", %{})}
  end

  def handle_event("stop", _params, socket) do
    {:noreply, assign(socket, running: false)}
  end

  def handle_event("reset", _params, socket) do
    socket =
      socket
      |> assign(running: false, measurement: D.new("0"), pid_state: nil, time: 0.0, filtered_setpoint: 0.0, metrics: initial_metrics())
      |> push_event("clear-chart", %{})
    {:noreply, socket}
  end

  def handle_event("update-params", params, socket) do
    socket = assign(socket,
      kp: params["kp"] || socket.assigns.kp,
      ki: params["ki"] || socket.assigns.ki,
      kd: params["kd"] || socket.assigns.kd
    )
    {:noreply, push_settings_to_url(socket)}
  end

  def handle_event("update-filter", params, socket) do
    socket = assign(socket,
      deadband: params["deadband"] || socket.assigns.deadband,
      smoothing: params["smoothing"] || socket.assigns.smoothing
    )
    {:noreply, push_settings_to_url(socket)}
  end

  def handle_event("update-plant", params, socket) do
    socket = assign(socket, full_traverse_time: params["full_traverse_time"] || socket.assigns.full_traverse_time)
    {:noreply, push_settings_to_url(socket)}
  end

  def handle_event("toggle-reset-derivative", _params, socket) do
    new_val = !socket.assigns.reset_derivative_on_setpoint_change
    socket = assign(socket, reset_derivative_on_setpoint_change: new_val)
    socket = if socket.assigns.pid_state do
      assign(socket, pid_state: %{socket.assigns.pid_state | reset_derivative_when_setpoint_changes: new_val})
    else
      socket
    end
    {:noreply, push_settings_to_url(socket)}
  end

  def handle_event("mouse-input", %{"value" => value}, socket) do
    {:noreply, assign(socket, setpoint: value)}
  end

  def handle_event("setpoint-slider", %{"value" => value}, socket) do
    {float_val, _} = Float.parse(value)
    {:noreply, assign(socket, setpoint: float_val)}
  end

  @impl true
  def handle_info(:tick, socket) do
    if socket.assigns.running do
      raw_setpoint = socket.assigns.setpoint

      input_filter = update_filter_params(socket.assigns.input_filter, socket.assigns.deadband, socket.assigns.smoothing)
      input_filter = InputFilter.apply(input_filter, D.new(Float.to_string(raw_setpoint)))
      filtered_setpoint = D.to_float(input_filter.value)

      setpoint = input_filter.value
      measurement = socket.assigns.measurement

      pid = socket.assigns.pid_state
      pid = %{pid |
        kp: safe_decimal(socket.assigns.kp),
        ki: safe_decimal(socket.assigns.ki),
        kd: safe_decimal(socket.assigns.kd)
      }
      pid = PIDController.iterate(pid, measurement, setpoint)

      # Plant gain derived from full traverse time:
      # The -1..1 range is 2 units. At full output (1.0), the system should
      # cross those 2 units in full_traverse_time seconds.
      # So plant_gain = 2 / full_traverse_time
      {traverse_time, _} = Float.parse(socket.assigns.full_traverse_time)
      traverse_time = max(0.1, traverse_time)
      plant_gain_d = D.new(Float.to_string(2.0 / traverse_time))

      new_measurement =
        measurement
        |> D.add(pid.output |> D.mult(plant_gain_d) |> D.mult(@dt))
        |> D.max(D.new("-1"))
        |> D.min(D.new("1"))

      new_time = socket.assigns.time + 0.02

      metrics = update_metrics(
        socket.assigns.metrics,
        D.to_float(setpoint),
        D.to_float(new_measurement),
        D.to_float(pid.integral_term),
        new_time
      )

      socket =
        socket
        |> assign(pid_state: pid, measurement: new_measurement, time: new_time, filtered_setpoint: filtered_setpoint, input_filter: input_filter, metrics: metrics)
        |> push_event("new-data-point", %{
          time: Float.round(new_time, 3),
          raw_setpoint: Float.round(raw_setpoint, 4),
          setpoint: D.to_float(setpoint),
          measurement: D.to_float(new_measurement),
          output: D.to_float(pid.output),
          p_term: D.to_float(pid.proportional_term),
          i_term: D.to_float(pid.integral_term),
          d_term: D.to_float(pid.derivative_term)
        })

      Process.send_after(self(), :tick, @tick_ms)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  defp update_metrics(metrics, setpoint, measurement, i_term, time) do
    error = setpoint - measurement
    abs_error = abs(error)
    setpoint_range = abs(setpoint)

    # Detect significant setpoint change (reset tracking)
    setpoint_changed = abs(setpoint - metrics.prev_setpoint) > 0.05

    metrics = if setpoint_changed do
      %{metrics |
        setpoint_change_time: time,
        rise_achieved: false,
        rise_time: nil,
        settling_time: nil,
        last_outside_band_time: time,
        peak_overshoot: 0.0
      }
    else
      metrics
    end

    # Error sign tracking for oscillation counting
    error_sign = cond do
      error > 0.01 -> :positive
      error < -0.01 -> :negative
      true -> metrics.prev_error_sign
    end

    oscillation_count = cond do
      metrics.prev_error_sign != nil and error_sign != nil and
        metrics.prev_error_sign != error_sign -> metrics.oscillation_count + 1
      true -> metrics.oscillation_count
    end

    # Overshoot: measurement goes past setpoint
    overshoot = if setpoint_range > 0.01 do
      case {setpoint > 0, measurement > setpoint} do
        {true, true} -> (measurement - setpoint) / setpoint_range * 100
        {false, _} ->
          if measurement < setpoint, do: (setpoint - measurement) / setpoint_range * 100, else: 0.0
        _ -> 0.0
      end
    else
      0.0
    end
    peak_overshoot = max(metrics.peak_overshoot, overshoot)

    # Rise time: time from setpoint change to first reaching 90% of setpoint
    rise_achieved = metrics.rise_achieved
    rise_time = metrics.rise_time
    rise_achieved = rise_achieved || (setpoint_range > 0.01 and abs_error < setpoint_range * 0.1)
    rise_time = if rise_achieved and is_nil(rise_time) and metrics.setpoint_change_time do
      time - metrics.setpoint_change_time
    else
      rise_time
    end

    # Settling: within band of setpoint
    within_band = abs_error < max(setpoint_range * @settling_band, 0.01)
    last_outside_band_time = if within_band, do: metrics.last_outside_band_time, else: time
    settling_time = if within_band and last_outside_band_time && metrics.setpoint_change_time do
      last_outside_band_time - metrics.setpoint_change_time
    else
      metrics.settling_time
    end

    # Generate tuning hints
    hints = generate_hints(peak_overshoot, oscillation_count, abs_error, setpoint_range, i_term, rise_time, _settling_time = settling_time)

    %{metrics |
      peak_overshoot: peak_overshoot,
      oscillation_count: oscillation_count,
      prev_error_sign: error_sign,
      rise_achieved: rise_achieved,
      rise_time: rise_time,
      settling_time: settling_time,
      last_outside_band_time: last_outside_band_time,
      prev_setpoint: setpoint,
      steady_state_error: abs_error,
      hints: hints
    }
  end

  defp generate_hints(overshoot, oscillations, abs_error, setpoint_range, i_term, rise_time, _settling_time) do
    hints = []

    hints = if overshoot > 5 do
      ["High overshoot (#{Float.round(overshoot, 1)}%) - reduce Kp or increase Kd" | hints]
    else
      hints
    end

    hints = if oscillations > 2 do
      ["Oscillating (#{oscillations}x) - reduce Kp or increase Kd" | hints]
    else
      hints
    end

    hints = if setpoint_range > 0.01 and abs_error > setpoint_range * 0.1 and (rise_time || 999) > 0.5 do
      ["Slow response - increase Kp" | hints]
    else
      hints
    end

    hints = if setpoint_range > 0.01 and abs_error > 0.02 and rise_time != nil and rise_time > 0.3 do
      ["Steady-state error (#{Float.round(abs_error, 4)}) - increase Ki" | hints]
    else
      hints
    end

    hints = if abs(i_term) > 0.5 do
      ["Integral windup (I=#{Float.round(i_term, 3)}) - reduce Ki" | hints]
    else
      hints
    end

    hints = if overshoot < 5 and oscillations < 2 and rise_time != nil and rise_time < 0.5 do
      ["Good response" | hints]
    else
      hints
    end

    case hints do
      [] -> ["Waiting for data..."]
      _ -> Enum.reverse(hints)
    end
  end

  defp new_input_filter(deadband_str, alpha_str, initial_value \\ 0.0) do
    {deadband, _} = Float.parse(deadband_str)
    {alpha, _} = Float.parse(alpha_str)
    InputFilter.new(
      deadband: D.new(Float.to_string(deadband)),
      alpha: D.new(Float.to_string(clamp_alpha(alpha))),
      initial_value: D.new(Float.to_string(initial_value))
    )
  end

  defp update_filter_params(filter, deadband_str, alpha_str) do
    {deadband, _} = Float.parse(deadband_str)
    {alpha, _} = Float.parse(alpha_str)
    %{filter |
      deadband: D.new(Float.to_string(deadband)),
      alpha: D.new(Float.to_string(clamp_alpha(alpha)))
    }
  end

  defp clamp_alpha(alpha), do: max(@min_alpha, min(@max_alpha, alpha))

  defp push_settings_to_url(socket) do
    params = %{
      "kp" => socket.assigns.kp,
      "ki" => socket.assigns.ki,
      "kd" => socket.assigns.kd,
      "deadband" => socket.assigns.deadband,
      "smoothing" => socket.assigns.smoothing,
      "full_traverse_time" => socket.assigns.full_traverse_time,
      "reset_d" => to_string(socket.assigns.reset_derivative_on_setpoint_change)
    }
    push_patch(socket, to: "/?" <> URI.encode_query(params), replace: true)
  end

  defp parse_bool(nil, default), do: default
  defp parse_bool("true", _default), do: true
  defp parse_bool("false", _default), do: false
  defp parse_bool(_, default), do: default

  defp safe_decimal(str) do
    case Decimal.parse(str) do
      {d, _} -> d
      :error -> D.new("0")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen p-6 flex gap-6" id="input-container" phx-hook="MouseInput">
      <!-- Sidebar -->
      <div class="w-80 flex-shrink-0 space-y-4">
        <h1 class="text-2xl font-bold">PID Simulator</h1>
        <p class="text-sm text-gray-400">Generic PID controller simulation with input filtering</p>

        <!-- PID Parameters -->
        <div class="bg-gray-800 rounded-lg p-4">
          <h2 class="text-lg font-semibold mb-3">PID Gains</h2>
          <form phx-change="update-params" class="space-y-3">
            <div>
              <label class="block text-sm text-gray-400 mb-1">Kp (Proportional)</label>
              <input type="number" name="kp" value={@kp} step="0.01"
                     class="w-full bg-gray-700 border border-gray-600 rounded px-3 py-2 text-white focus:border-blue-500 focus:outline-none" />
            </div>
            <div>
              <label class="block text-sm text-gray-400 mb-1">Ki (Integral)</label>
              <input type="number" name="ki" value={@ki} step="0.01"
                     class="w-full bg-gray-700 border border-gray-600 rounded px-3 py-2 text-white focus:border-blue-500 focus:outline-none" />
            </div>
            <div>
              <label class="block text-sm text-gray-400 mb-1">Kd (Derivative)</label>
              <input type="number" name="kd" value={@kd} step="0.01"
                     class="w-full bg-gray-700 border border-gray-600 rounded px-3 py-2 text-white focus:border-blue-500 focus:outline-none" />
            </div>
          </form>
          <div class="mt-3 pt-3 border-t border-gray-700">
            <label class="flex items-center gap-2 cursor-pointer">
              <button phx-click="toggle-reset-derivative"
                      class={"w-4 h-4 rounded border #{if @reset_derivative_on_setpoint_change, do: "bg-blue-500 border-blue-500", else: "bg-gray-700 border-gray-500"}"}>
              </button>
              <span class="text-sm text-gray-400">Reset D-term on setpoint change</span>
            </label>
            <p class="text-xs text-gray-600 mt-1">
              Prevents D-term spikes when the setpoint changes suddenly (e.g. radio input, ROS2 commands)
            </p>
          </div>
        </div>

        <!-- Plant Model -->
        <div class="bg-gray-800 rounded-lg p-4">
          <h2 class="text-lg font-semibold mb-3">Plant Model</h2>
          <p class="text-xs text-gray-500 mb-3">Models real actuator speed. Measure on hardware or estimate from specs.</p>
          <form phx-change="update-plant" class="space-y-3">
            <div>
              <label class="block text-sm text-gray-400 mb-1">
                Full traverse time <span class="text-gray-500">(seconds, end-to-end at max output)</span>
              </label>
              <input type="number" name="full_traverse_time" value={@full_traverse_time} step="0.1" min="0.1"
                     class="w-full bg-gray-700 border border-gray-600 rounded px-3 py-2 text-white focus:border-blue-500 focus:outline-none" />
              <p class="text-xs text-gray-600 mt-1">
                Steering column: ~2s lock-to-lock. iBooster rod: ~1s full travel.
              </p>
            </div>
          </form>
        </div>

        <!-- Input Filter -->
        <div class="bg-gray-800 rounded-lg p-4">
          <h2 class="text-lg font-semibold mb-3">Input Filter</h2>
          <p class="text-xs text-gray-500 mb-3">Filters raw setpoint before PID to reject input noise</p>
          <form phx-change="update-filter" class="space-y-3">
            <div>
              <label class="block text-sm text-gray-400 mb-1">
                Deadband <span class="text-gray-500">(ignore changes &lt; this)</span>
              </label>
              <input type="number" name="deadband" value={@deadband} step="0.005" min="0" max="0.2"
                     class="w-full bg-gray-700 border border-gray-600 rounded px-3 py-2 text-white focus:border-blue-500 focus:outline-none" />
            </div>
            <div>
              <label class="block text-sm text-gray-400 mb-1">
                Smoothing alpha <span class="text-gray-500">(lower = smoother)</span>
              </label>
              <input type="number" name="smoothing" value={@smoothing} step="0.01" min="0.01" max="1.0"
                     class="w-full bg-gray-700 border border-gray-600 rounded px-3 py-2 text-white focus:border-blue-500 focus:outline-none" />
            </div>
          </form>
        </div>

        <!-- Controls -->
        <div class="bg-gray-800 rounded-lg p-4">
          <h2 class="text-lg font-semibold mb-3">Controls</h2>
          <div class="flex gap-2">
            <button phx-click="start" class="flex-1 bg-green-600 hover:bg-green-700 text-white font-medium py-2 px-4 rounded transition">
              Start
            </button>
            <button phx-click="stop" class="flex-1 bg-yellow-600 hover:bg-yellow-700 text-white font-medium py-2 px-4 rounded transition">
              Stop
            </button>
            <button phx-click="reset" class="flex-1 bg-red-600 hover:bg-red-700 text-white font-medium py-2 px-4 rounded transition">
              Reset
            </button>
          </div>
        </div>

        <!-- Setpoint Input -->
        <div class="bg-gray-800 rounded-lg p-4">
          <h2 class="text-lg font-semibold mb-3">Setpoint</h2>
          <div class="space-y-2">
            <div id="input-debug" class="text-xs text-gray-500 font-mono" phx-update="ignore">
              Hold CTRL + move mouse left/right to control setpoint
            </div>
            <form phx-change="setpoint-slider">
              <input type="range" min="-1" max="1" step="0.01"
                     value={@setpoint}
                     name="value"
                     class="w-full accent-amber-500" />
              <div class="flex justify-between text-sm font-mono">
                <span class="text-gray-500">Raw: <%= Float.round(@setpoint, 3) %></span>
                <span class="text-amber-400">Filtered: <%= Float.round(@filtered_setpoint, 3) %></span>
              </div>
            </form>
          </div>
        </div>

        <!-- Live Values -->
        <div class="bg-gray-800 rounded-lg p-4">
          <h2 class="text-lg font-semibold mb-3">Live Values</h2>
          <div class="grid grid-cols-2 gap-y-2 text-sm font-mono">
            <span class="text-gray-500">Raw setpoint:</span>
            <span class="text-right"><%= Float.round(@setpoint, 4) %></span>
            <span class="text-amber-400">Filtered setpoint:</span>
            <span class="text-right"><%= Float.round(@filtered_setpoint, 4) %></span>
            <span class="text-blue-400">Measurement:</span>
            <span class="text-right"><%= format_decimal(@measurement) %></span>
            <span class="text-red-400">Output:</span>
            <span class="text-right"><%= if @pid_state && @pid_state.output, do: format_decimal(@pid_state.output), else: "0" %></span>
            <span class="text-green-400">P term:</span>
            <span class="text-right"><%= if @pid_state, do: format_decimal(@pid_state.proportional_term), else: "0" %></span>
            <span class="text-purple-400">I term:</span>
            <span class="text-right"><%= if @pid_state, do: format_decimal(@pid_state.integral_term), else: "0" %></span>
            <span class="text-cyan-400">D term:</span>
            <span class="text-right"><%= if @pid_state, do: format_decimal(@pid_state.derivative_term), else: "0" %></span>
            <span class="text-gray-400">Time:</span>
            <span class="text-right"><%= Float.round(@time, 2) %>s</span>
          </div>
        </div>
      </div>

      <!-- Main area -->
      <div class="flex-1 flex flex-col gap-4">
        <!-- Chart -->
        <div class="flex-1 bg-gray-800 rounded-lg p-4">
          <div class="h-full" style="min-height: 500px;">
            <canvas id="pid-chart" phx-hook="Chart" phx-update="ignore"></canvas>
          </div>
        </div>

        <!-- Performance Metrics -->
        <div class="bg-gray-800 rounded-lg p-4">
          <h2 class="text-lg font-semibold mb-3">Performance Analysis</h2>
          <div class="grid grid-cols-5 gap-4 text-center">
            <div>
              <div class="text-xs text-gray-500 uppercase">Overshoot</div>
              <div class={"text-xl font-mono #{overshoot_color(@metrics.peak_overshoot)}"}>
                <%= Float.round(@metrics.peak_overshoot, 1) %>%
              </div>
            </div>
            <div>
              <div class="text-xs text-gray-500 uppercase">Oscillations</div>
              <div class={"text-xl font-mono #{oscillation_color(@metrics.oscillation_count)}"}>
                <%= @metrics.oscillation_count %>
              </div>
            </div>
            <div>
              <div class="text-xs text-gray-500 uppercase">Rise Time</div>
              <div class="text-xl font-mono text-gray-200">
                <%= if @metrics.rise_time, do: "#{Float.round(@metrics.rise_time, 2)}s", else: "-" %>
              </div>
            </div>
            <div>
              <div class="text-xs text-gray-500 uppercase">Settling Time</div>
              <div class="text-xl font-mono text-gray-200">
                <%= if @metrics.settling_time, do: "#{Float.round(@metrics.settling_time, 2)}s", else: "-" %>
              </div>
            </div>
            <div>
              <div class="text-xs text-gray-500 uppercase">Error</div>
              <div class={"text-xl font-mono #{error_color(@metrics.steady_state_error)}"}>
                <%= Float.round(@metrics.steady_state_error, 4) %>
              </div>
            </div>
          </div>

          <%= if @metrics.hints != [] do %>
            <div class="mt-3 pt-3 border-t border-gray-700">
              <div class="text-xs text-gray-500 uppercase mb-2">Tuning Hints</div>
              <div class="space-y-1">
                <%= for hint <- @metrics.hints do %>
                  <div class={"text-sm #{hint_color(hint)}"}>
                    <%= hint_icon(hint) %> <%= hint %>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp overshoot_color(v) when v < 5, do: "text-green-400"
  defp overshoot_color(v) when v < 20, do: "text-yellow-400"
  defp overshoot_color(_), do: "text-red-400"

  defp oscillation_color(v) when v < 3, do: "text-green-400"
  defp oscillation_color(v) when v < 6, do: "text-yellow-400"
  defp oscillation_color(_), do: "text-red-400"

  defp error_color(v) when v < 0.02, do: "text-green-400"
  defp error_color(v) when v < 0.1, do: "text-yellow-400"
  defp error_color(_), do: "text-red-400"

  defp hint_color("Good" <> _), do: "text-green-400"
  defp hint_color(_), do: "text-yellow-300"

  defp hint_icon("Good" <> _), do: "OK"
  defp hint_icon("High overshoot" <> _), do: ">>"
  defp hint_icon("Oscillating" <> _), do: "~~"
  defp hint_icon("Slow" <> _), do: ".."
  defp hint_icon("Steady" <> _), do: "--"
  defp hint_icon("Integral" <> _), do: "!!"
  defp hint_icon(_), do: "--"

  defp format_decimal(d), do: d |> Decimal.round(4) |> Decimal.to_string()
end
