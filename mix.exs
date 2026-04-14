defmodule OvcsControl.MixProject do
  use Mix.Project

  def project do
    [
      app: :ovcs_control,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:decimal, "~> 2.1"}
    ]
  end
end
