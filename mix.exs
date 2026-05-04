defmodule TricitiesEvents.MixProject do
  use Mix.Project

  def project do
    [
      app: :tricities_events,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {TricitiesEvents.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5.17"},
      {:floki, "~> 0.38.1"},
      {:tzdata, "~> 1.1"}
    ]
  end
end
