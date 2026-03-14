defmodule MeliGraph.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/dede/meli_graph"

  def project do
    [
      app: :meli_graph,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      name: "MeliGraph",
      description: "Graph-based recommendation engine for Elixir",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:nx, "~> 0.9", optional: true},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "MeliGraph",
      extras: ["README.md", "base.md"]
    ]
  end
end
