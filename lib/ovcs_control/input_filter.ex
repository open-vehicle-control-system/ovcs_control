defmodule OvcsControl.InputFilter do
  @moduledoc """
  Low-pass filter with deadband for noisy inputs (e.g. radio controller signals).

  Combines two techniques to clean up a noisy input signal before it reaches
  a controller (such as `OvcsControl.PID`):

  - **Deadband**: Ignores input changes smaller than a threshold. This eliminates
    jitter — tiny random variations that the radio controller produces even when
    the stick is held steady.

  - **Exponential moving average (EMA)**: Smooths the input signal so that sudden
    jumps are spread over several iterations. Controlled by the `alpha` parameter:
    - `alpha` close to 1.0 = fast tracking, almost no smoothing
    - `alpha` close to 0.0 = heavy smoothing, slow to react
    - Typical starting value for radio input: 0.10 to 0.20

  The filter formula is: `filtered = previous + alpha * (target - previous)`
  where `target` is either the raw input (if it exceeds the deadband) or the
  previous filtered value (if the change is within the deadband).

  ## Usage

      filter = InputFilter.new(
        deadband: Decimal.new("0.02"),
        alpha: Decimal.new("0.15")
      )

      # In a loop, apply the filter to each raw input value:
      filter = InputFilter.apply(filter, raw_value)
      filter.value  # => filtered Decimal value, ready for the PID controller

  ## Parameters

  - `:deadband` - (required, Decimal) minimum change from current filtered value
    to accept a new input. Changes smaller than this are ignored.
  - `:alpha` - (required, Decimal) smoothing factor between 0 and 1.
    Lower values produce smoother output but slower response.
  - `:initial_value` - (optional, Decimal) starting value for the filter.
    Defaults to 0.
  """

  alias Decimal, as: D

  @enforce_keys [:deadband, :alpha]
  defstruct [:deadband, :alpha, value: D.new(0)]

  @doc """
  Creates a new filter. Both `:deadband` and `:alpha` are required.
  """
  def new(opts) do
    %__MODULE__{
      deadband: Keyword.fetch!(opts, :deadband),
      alpha: Keyword.fetch!(opts, :alpha),
      value: opts[:initial_value] || D.new(0)
    }
  end

  @doc """
  Applies the filter to a new raw input value and returns the updated filter.
  The filtered result is available in `filter.value`.
  """
  def apply(%__MODULE__{} = filter, raw_value) do
    delta = raw_value |> D.sub(filter.value) |> D.abs()

    target = if D.gt?(delta, filter.deadband) do
      raw_value
    else
      filter.value
    end

    new_value =
      target
      |> D.sub(filter.value)
      |> D.mult(filter.alpha)
      |> D.add(filter.value)

    %{filter | value: new_value}
  end
end
