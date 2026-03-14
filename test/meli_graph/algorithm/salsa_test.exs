defmodule MeliGraph.Algorithm.SALSATest do
  use ExUnit.Case, async: false

  import MeliGraph.TestHelpers

  alias MeliGraph.Algorithm.SALSA
  alias MeliGraph.Graph.IdMap

  setup do
    name = start_test_instance(graph_type: :bipartite)
    conf = get_conf(name)

    # Grafo bipartido: usuários → conteúdo
    # user:1 → post:a, post:b
    # user:2 → post:a, post:c
    # user:3 → post:b, post:c, post:d
    edges = [
      {"user:1", "post:a"},
      {"user:1", "post:b"},
      {"user:2", "post:a"},
      {"user:2", "post:c"},
      {"user:3", "post:b"},
      {"user:3", "post:c"},
      {"user:3", "post:d"}
    ]

    for {s, t} <- edges do
      MeliGraph.insert_edge(name, s, t, :like)
    end

    entity_id = IdMap.get_internal(conf, "user:1")
    %{conf: conf, entity_id: entity_id, name: name}
  end

  describe "compute/4" do
    test "returns recommendations", %{conf: conf, entity_id: entity_id} do
      opts = [seed_size: 10, iterations: 3, top_k: 10]
      {:ok, results} = SALSA.compute(conf, entity_id, :content, opts)

      assert is_list(results)
    end

    test "returns empty for unknown node", %{conf: conf} do
      IdMap.get_or_create(conf, "user:unknown")
      internal = IdMap.get_internal(conf, "user:unknown")

      {:ok, results} = SALSA.compute(conf, internal, :content, seed_size: 5, top_k: 5)
      assert results == []
    end

    test "results have correct format", %{conf: conf, entity_id: entity_id} do
      opts = [seed_size: 10, iterations: 3, top_k: 10]
      {:ok, results} = SALSA.compute(conf, entity_id, :content, opts)

      Enum.each(results, fn {id, score} ->
        assert id != nil
        assert is_float(score)
        assert score >= 0.0
      end)
    end
  end

  defp get_conf(name) do
    registry = Module.concat(name, Registry)
    [{_pid, conf}] = Registry.lookup(registry, :conf)
    conf
  end
end
