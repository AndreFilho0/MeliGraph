defmodule MeliGraph.Algorithm.PageRankTest do
  use ExUnit.Case, async: false

  import MeliGraph.TestHelpers

  alias MeliGraph.Algorithm.PageRank
  alias MeliGraph.Graph.IdMap

  setup do
    name = start_test_instance(graph_type: :directed)
    conf = get_conf(name)

    # Criar um grafo simples:
    # A → B → D
    # A → C → D
    # D → A (ciclo)
    for {s, t} <- [{"A", "B"}, {"A", "C"}, {"B", "D"}, {"C", "D"}, {"D", "A"}] do
      MeliGraph.insert_edge(name, s, t, :follow)
    end

    entity_id = IdMap.get_internal(conf, "A")
    %{conf: conf, entity_id: entity_id, name: name}
  end

  describe "compute/4" do
    test "returns ranked results", %{conf: conf, entity_id: entity_id} do
      opts = [num_walks: 500, walk_length: 8, top_k: 10]
      {:ok, results} = PageRank.compute(conf, entity_id, :users, opts)

      assert is_list(results)
      assert length(results) > 0

      # All results should have {external_id, score} format
      Enum.each(results, fn {id, score} ->
        assert is_binary(id)
        assert is_float(score)
        assert score > 0.0
      end)
    end

    test "scores sum to approximately 1.0", %{conf: conf, entity_id: entity_id} do
      opts = [num_walks: 2000, walk_length: 10, top_k: 10]
      {:ok, results} = PageRank.compute(conf, entity_id, :users, opts)

      total = Enum.reduce(results, 0.0, fn {_, score}, acc -> acc + score end)
      # Should be close to 1.0 (minus the seed node's visits)
      assert total > 0.0
      assert total <= 1.0
    end

    test "D should rank high (reachable from both B and C)", %{conf: conf, entity_id: entity_id} do
      opts = [num_walks: 2000, walk_length: 10, top_k: 10]
      {:ok, results} = PageRank.compute(conf, entity_id, :users, opts)

      ids = Enum.map(results, fn {id, _} -> id end)
      assert "D" in ids
    end

    test "returns empty for isolated node", %{conf: conf} do
      # Create an isolated node
      IdMap.get_or_create(conf, "isolated")
      internal = IdMap.get_internal(conf, "isolated")

      {:ok, results} = PageRank.compute(conf, internal, :users, num_walks: 100, top_k: 10)
      assert results == []
    end
  end

  defp get_conf(name) do
    registry = Module.concat(name, Registry)
    [{_pid, conf}] = Registry.lookup(registry, :conf)
    conf
  end
end
