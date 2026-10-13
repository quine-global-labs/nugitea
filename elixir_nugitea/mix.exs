defmodule Nugitea.MixProject do
  use Mix.Project

  def project do
    [
      app: :nugitea,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssh, :public_key, :crypto, :inets, :ssl],
      mod: {Nugitea.Application, []}
    ]
  end

  defp deps do
    [
      {:absinthe, "~> 1.7"},
      {:absinthe_plug, "~> 1.5"},
      {:bandit, "~> 1.6"},
      {:erlexec, "~> 2.0"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16"}
    ]
  end
end
