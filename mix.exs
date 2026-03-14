defmodule MeliGraph.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/AndreFilho0/MeliGraph"

  def project do
    [
      app: :meli_graph,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: package(),
      name: "MeliGraph",
      description: description(),
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    """
    Graph-based recommendation engine for Elixir. In-memory graph with temporal
    segmentation, Personalized PageRank, SALSA, SimilarItems and GlobalRank algorithms.
    Inspired by Twitter's WTF/GraphJet and Oban's OTP patterns.
    """
  end

  defp package do
    [
      name: "meli_graph",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:nx, "~> 0.9", optional: true},
      {:csv, "~> 3.2", only: :test, runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:observer_cli, "~> 1.7", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "MeliGraph",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "LICENSE"],
      groups_for_modules: [
        "API Pública": [MeliGraph],
        "Algoritmos": [
          MeliGraph.Algorithm,
          MeliGraph.Algorithm.PageRank,
          MeliGraph.Algorithm.SALSA,
          MeliGraph.Algorithm.SimilarItems,
          MeliGraph.Algorithm.GlobalRank
        ],
        "Graph Storage": [
          MeliGraph.Graph.Segment,
          MeliGraph.Graph.SegmentManager,
          MeliGraph.Graph.IdMap,
          MeliGraph.Graph.Edge
        ],
        "Ingestion": [MeliGraph.Ingestion.Writer],
        "Query & Store": [MeliGraph.Query, MeliGraph.Store.ETS],
        "Infraestrutura": [
          MeliGraph.Config,
          MeliGraph.Supervisor,
          MeliGraph.Registry,
          MeliGraph.Telemetry,
          MeliGraph.ConfigHolder
        ],
        "Plugins": [
          MeliGraph.Plugin,
          MeliGraph.Plugins.Pruner,
          MeliGraph.Plugins.CacheCleaner,
          MeliGraph.Plugins.Supervisor
        ]
      ]
    ]
  end
end
