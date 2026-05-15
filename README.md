# OvcsControl

Control and signal processing library for OVCS vehicle systems. Provides a PID controller, input filtering, and an interactive tuning simulator.

## Modules

### OvcsControl.PID

PID (Proportional-Integral-Derivative) controller with configurable gains, output clamping, and optional derivative reset on setpoint changes.

```elixir
pid = OvcsControl.PID.new(
  kp: Decimal.new("0.2"),
  ki: Decimal.new("0.02"),
  kd: Decimal.new("0.01"),
  reset_derivative_when_setpoint_changes: true
)

# In a loop (every 10-20ms):
pid = OvcsControl.PID.iterate(pid, measurement, setpoint)
pid.output  # => Decimal value to send to actuator
```

See the module documentation for tuning guides specific to the OVCS steering column and iBooster brake system.

### OvcsControl.InputFilter

Low-pass filter with deadband for noisy inputs. Rejects jitter from radio controllers, ROS2 commands, or any other noisy signal source before it reaches the PID.

```elixir
filter = OvcsControl.InputFilter.new(
  deadband: Decimal.new("0.02"),
  alpha: Decimal.new("0.15")
)

# In a loop, filter each raw input:
filter = OvcsControl.InputFilter.apply(filter, raw_value)
filter.value  # => filtered Decimal, feed this to the PID as setpoint
```

- **deadband**: ignores changes smaller than this threshold (kills jitter)
- **alpha**: smoothing factor, 0.01 (heavy smoothing) to 1.0 (no smoothing)

## Installation

Add as a path dependency in your `mix.exs` (adjust the relative path to
match your caller's depth — `vms/core/`, `bridges/<name>/`, etc.):

```elixir
def deps do
  [
    {:ovcs_control, path: "../../libraries/ovcs_control"}
  ]
end
```

Then update your aliases from `VmsCore.PID` / `VmsCore.InputFilter` to `OvcsControl.PID` / `OvcsControl.InputFilter`.

## Tests

```sh
mix test
```

## Simulator

An interactive Phoenix LiveView application for tuning PID gains and input filter parameters in real time.

### Running the simulator

```sh
cd tools/simulator
mix setup
mix phx.server
```

Open http://localhost:4002 in your browser.

### Features

- **PID gains** (Kp, Ki, Kd) adjustable live while the simulation runs
- **Input filter** (deadband, smoothing alpha) to see the effect of filtering before the PID
- **Reset D-term on setpoint change** toggle to prevent derivative spikes from sudden input changes
- **Plant model** with configurable full traverse time to approximate real actuator speed (e.g. ~2s for steering lock-to-lock, ~1s for brake rod full travel)
- **Real-time chart** showing raw setpoint, filtered setpoint, measurement, PID output, and individual P/I/D terms
- **Performance analysis** with overshoot %, oscillation count, rise time, settling time, and steady-state error
- **Tuning hints** that suggest gain adjustments based on observed behavior
- **URL-persisted settings** that survive page reloads and crashes
- **Mouse input**: hold CTRL and move mouse left/right to control the setpoint dynamically

### How to use

1. Set the **Plant model** traverse time to match your actuator (how long it takes to go end-to-end at full output)
2. Set initial **PID gains** (start with Kp only, Ki and Kd at 0)
3. Click **Start**
4. Move the setpoint slider or use CTRL+mouse
5. Observe the chart and performance metrics
6. Adjust gains based on the tuning hints and observed behavior:
   - Slow response: increase Kp
   - Overshoot/oscillation: reduce Kp or increase Kd
   - Steady-state error: increase Ki
   - Integral windup: reduce Ki
7. Enable the **Input filter** with a small deadband (0.02) and smoothing (0.15) to see how it cleans up noisy input
