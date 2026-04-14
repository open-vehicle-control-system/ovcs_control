defmodule OvcsControl.PID do
  @moduledoc """
  PID (Proportional-Integral-Derivative) controller.

  Computes a control output based on the error between a setpoint (desired value)
  and a measurement (actual value). The output is the sum of three terms:

  - **Proportional (P)**: Reacts to the current error. Higher `kp` means stronger
    immediate response but can cause overshoot and oscillation.

  - **Integral (I)**: Accumulates past error over time. Eliminates steady-state error
    (the small residual gap the P term alone can't close) but can cause overshoot
    if too aggressive. The integral accumulates as `ki * error * dt` per iteration.

  - **Derivative (D)**: Reacts to the rate of change of the error. Dampens overshoot
    and oscillation but amplifies sensor noise if too high.

  The output is clamped to `[minimum_output, maximum_output]` (default -1..1).

  ## Usage

      pid = OvcsControl.PID.new(kp: Decimal.new("0.2"), ki: Decimal.new("0.02"), kd: Decimal.new("0.01"))

      # In a loop (e.g. every 10-20ms):
      pid = OvcsControl.PID.iterate(pid, measurement, setpoint)
      pid.output  # => Decimal value to send to actuator

  ## Time tracking

  `iterate/3` uses `System.monotonic_time/1` to compute elapsed time between calls.
  On the first call, `minimum_elapsed_time` is used to avoid division by zero.

  ## Options

  - `:kp` - proportional gain (required, Decimal)
  - `:ki` - integral gain (required, Decimal)
  - `:kd` - derivative gain (required, Decimal)
  - `:minimum_output` - lower clamp for output (default: -1)
  - `:maximum_output` - upper clamp for output (default: 1)
  - `:minimum_elapsed_time` - floor for dt in seconds (default: 0.0001)
  - `:reset_derivative_when_setpoint_changes` - when true, resets the derivative
    term on setpoint changes to avoid a spike (default: false)

  ## Tuning guide: steering column (stepper motor)

  The steering column uses a stepper motor driven by a PWM frequency signal.
  The PID output (-1..1) maps to a motor speed percentage, which is then
  multiplied by the frequency range (65535 Hz). The steering angle range is
  400 degrees (-200..+200).

  Characteristics:
  - Stepper motors have precise positioning but no back-drivability
  - Low friction means Ki can be kept very small
  - Overshoot is dangerous — the wheel jerking past target is unsafe
  - Use `reset_derivative_when_setpoint_changes: true` to avoid D-term spikes
    when the operator moves the input

  Recommended starting gains:
  - Kp: 0.15 - 0.3  (full motor speed at ~3-6 degrees of error, fast correction
    without being twitchy. Lower end for smoother feel, higher for snappier response)
  - Ki: 0.01 - 0.03  (eliminates the last few degrees of steady-state error that
    Kp alone won't close. Keep low — stepper motors don't fight much friction)
  - Kd: 0.005 - 0.02  (dampens overshoot, critical for steering safety. Too high
    will amplify angle sensor noise and cause jitter)

  Start with Kp=0.2, Ki=0.02, Kd=0.01 and adjust from there.
  Consider pairing with `OvcsControl.InputFilter` on the setpoint to reject radio
  controller jitter before it reaches the PID.

  ## Tuning guide: servo brake (iBooster Gen2)

  The iBooster uses a hydraulic rod controlled via a flow rate signal.
  The PID output maps to a flow rate offset from a zero-point (32256).
  The rod position range is 0..16.56mm.

  Characteristics:
  - Hydraulic system has significant inertia and is not instantly responsive
  - The flow rate controls velocity of the rod, not position directly
  - Braking must be reliable and responsive — under-braking is dangerous
  - Overshoot is less critical than with steering (slight over-braking is
    acceptable, under-braking is not)
  - The system is asymmetric: applying brakes (pushing rod) may have different
    dynamics than releasing (retracting rod)

  Recommended starting gains:
  - Kp: 150 - 300  (high because the error is in mm and the output must drive
    a flow rate offset of up to 5120. At Kp=250, a 1mm error produces ~50% of
    max flow rate)
  - Ki: 5 - 20  (more important here than for steering — hydraulic friction and
    seal resistance create steady-state error that Kp alone won't overcome)
  - Kd: 0 - 10  (start without it. Hydraulic systems are naturally damped by
    fluid resistance. Add Kd only if you observe oscillation around the target
    rod position)

  Start with Kp=250, Ki=10, Kd=0 and adjust from there.
  The brake system is less sensitive to input noise (rod position changes slowly)
  so input filtering is less critical than for steering.
  """

  alias Decimal, as: D
  @zero D.new(0)
  require Logger

  defstruct kp: @zero,
            ki: @zero,
            kd: @zero,
            minimum_output: Decimal.new(-1),
            maximum_output: Decimal.new(1),
            minimum_elapsed_time: D.new("0.0001"),
            reset_derivative_when_setpoint_changes: false,
            proportional_term: @zero,
            integral_term: @zero,
            derivative_term: @zero,
            previous_time: nil,
            previous_error: nil,
            previous_measurement: nil,
            previous_setpoint: nil,
            output: nil

  @doc """
  Creates a new PID controller state with the given gains and options.
  """
  def new(config \\ []) do
    default = %__MODULE__{}
    default |> Map.merge(config |> Enum.into(%{}))
  end

  @doc """
  Runs one PID iteration.

  Computes the error between `setpoint` and `measurement`, updates the P/I/D terms,
  and returns the updated PID state with the new `output`.

  Must be called repeatedly in a loop (typically every 10-20ms). The elapsed time
  between calls is measured automatically.
  """
  def iterate(pid, measurement, setpoint) do
    time                 = System.monotonic_time(:millisecond)
    previous_time        = pid.previous_time || time
    elapsed_time_seconds = time |> D.sub(previous_time) |> D.div(1000) |> D.max(pid.minimum_elapsed_time)

    error          = setpoint |> D.sub(measurement)
    previous_error = cond do
      is_nil(pid.previous_error) -> error
      pid.reset_derivative_when_setpoint_changes && pid.previous_setpoint != setpoint -> error
      true -> pid.previous_error
    end

    proportional_term = error |> D.mult(pid.kp)
    integral_term     = error |> D.mult(elapsed_time_seconds) |> D.mult(pid.ki) |> D.add(pid.integral_term)
    derivative_term   = error |> D.sub(previous_error) |> D.div(elapsed_time_seconds) |> D.mult(pid.kd)
    output_raw        = proportional_term |> D.add(integral_term) |> D.add(derivative_term)
    output            = output_raw |> D.max(pid.minimum_output) |> D.min(pid.maximum_output)
    Logger.debug("E: #{error |> Decimal.round(4)} - P: #{proportional_term |> Decimal.round(4)} - I: #{integral_term |> Decimal.round(4)} - D: #{derivative_term |> Decimal.round(4)} - O: #{output |> Decimal.round(4)}")

    %{pid |
      previous_error: error,
      previous_time: time,
      previous_setpoint: setpoint,
      previous_measurement: measurement,
      proportional_term: proportional_term,
      integral_term: integral_term,
      derivative_term: derivative_term,
      output: output
    }
  end
end
