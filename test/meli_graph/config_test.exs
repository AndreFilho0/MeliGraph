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

    test "applies distribution defaults" do
      conf = Config.new(name: :test_dist_defaults, graph_type: :bipartite)

      assert conf.distribution == :local
      assert conf.on_ready == nil
      assert conf.cluster_call_timeout == :timer.seconds(15)
      assert conf.reconcile_interval == :timer.seconds(2)
      assert conf.reconcile_grace == :timer.seconds(5)
    end

    test "allows overriding distribution options" do
      conf =
        Config.new(
          name: :test_dist_override,
          graph_type: :bipartite,
          distribution: :horde,
          on_ready: {SomeLoader, :load, [:feed]},
          cluster_call_timeout: 30_000,
          reconcile_interval: 1_000,
          reconcile_grace: 3_000
        )

      assert conf.distribution == :horde
      assert conf.on_ready == {SomeLoader, :load, [:feed]}
      assert conf.cluster_call_timeout == 30_000
      assert conf.reconcile_interval == 1_000
      assert conf.reconcile_grace == 3_000
    end

    test "raises on invalid distribution" do
      assert_raise ArgumentError, ~r/distribution/, fn ->
        Config.new(name: :test, graph_type: :directed, distribution: :invalid)
      end
    end

    test "raises on invalid cluster_call_timeout" do
      assert_raise ArgumentError, ~r/cluster_call_timeout/, fn ->
        Config.new(name: :test, graph_type: :directed, cluster_call_timeout: 0)
      end

      assert_raise ArgumentError, ~r/cluster_call_timeout/, fn ->
        Config.new(name: :test, graph_type: :directed, cluster_call_timeout: -1)
      end
    end

    test "raises on invalid on_ready shape" do
      assert_raise ArgumentError, ~r/on_ready/, fn ->
        Config.new(name: :test, graph_type: :directed, on_ready: :nope)
      end

      assert_raise ArgumentError, ~r/on_ready/, fn ->
        Config.new(name: :test, graph_type: :directed, on_ready: {1, 2, 3})
      end
    end

    test "raises on invalid reconcile_interval" do
      assert_raise ArgumentError, ~r/reconcile_interval/, fn ->
        Config.new(name: :test, graph_type: :directed, reconcile_interval: 0)
      end
    end

    test "raises on invalid reconcile_grace" do
      assert_raise ArgumentError, ~r/reconcile_grace/, fn ->
        Config.new(name: :test, graph_type: :directed, reconcile_grace: -1)
      end

      # grace 0 (re-assert imediato, sem janela de graça) é válido
      assert Config.new(name: :test, graph_type: :directed, reconcile_grace: 0).reconcile_grace ==
               0
    end
  end
end
