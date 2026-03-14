defmodule MeliGraph.ConfigTest do
  use ExUnit.Case, async: true

  alias MeliGraph.Config

  describe "new/1" do
    test "creates config with required fields" do
      conf = Config.new(name: :test_config, graph_type: :directed)

      assert conf.name == :test_config
      assert conf.graph_type == :directed
      assert conf.registry == :"Elixir.test_config.Registry"
    end

    test "applies default values" do
      conf = Config.new(name: :test_defaults, graph_type: :bipartite)

      assert conf.segment_max_edges == 1_000_000
      assert conf.testing == :disabled
      assert conf.algorithms == [:pagerank, :salsa]
    end

    test "allows overriding defaults" do
      conf = Config.new(
        name: :test_override,
        graph_type: :directed,
        segment_max_edges: 500,
        testing: :sync
      )

      assert conf.segment_max_edges == 500
      assert conf.testing == :sync
    end

    test "raises on missing required fields" do
      assert_raise ArgumentError, fn ->
        Config.new(graph_type: :directed)
      end

      assert_raise ArgumentError, fn ->
        Config.new(name: :test)
      end
    end

    test "raises on invalid graph_type" do
      assert_raise ArgumentError, ~r/graph_type/, fn ->
        Config.new(name: :test, graph_type: :invalid)
      end
    end

    test "raises on invalid testing mode" do
      assert_raise ArgumentError, ~r/testing/, fn ->
        Config.new(name: :test, graph_type: :directed, testing: :invalid)
      end
    end

    test "raises on invalid segment_max_edges" do
      assert_raise ArgumentError, ~r/segment_max_edges/, fn ->
        Config.new(name: :test, graph_type: :directed, segment_max_edges: 0)
      end

      assert_raise ArgumentError, ~r/segment_max_edges/, fn ->
        Config.new(name: :test, graph_type: :directed, segment_max_edges: -1)
      end
    end

    test "raises on invalid segment_ttl" do
      assert_raise ArgumentError, ~r/segment_ttl/, fn ->
        Config.new(name: :test, graph_type: :directed, segment_ttl: 0)
      end
    end

    test "raises on invalid result_ttl" do
      assert_raise ArgumentError, ~r/result_ttl/, fn ->
        Config.new(name: :test, graph_type: :directed, result_ttl: -1)
      end
    end
  end
end
