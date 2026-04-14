defmodule PidSimulator.MixProject do
  use Mix.Project

  def project do
    [
      app: :pid_simulator,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {PidSimulator.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ovcs_control, path: "../../"},
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_view, "~> 0.20"},
      {:phoenix_pubsub, "~> 2.0"},
      {:jason, "~> 1.2"},
      {:plug_cowboy, "~> 2.5"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
    ]
  end

  defp aliases do
    [
      "assets.build": ["esbuild default"],
      "assets.deploy": ["esbuild default --minify"],
      setup: ["deps.get", "assets.build"]
    ]
  end
end
