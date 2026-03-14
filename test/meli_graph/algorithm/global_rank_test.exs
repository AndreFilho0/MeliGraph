defmodule MeliGraph.Algorithm.GlobalRankTest do
  use ExUnit.Case, async: false

  import MeliGraph.TestHelpers

  alias MeliGraph.Algorithm.GlobalRank
  alias MeliGraph.Graph.IdMap

  # Grafo bipartido: profiles → professors
  #
  # profile:1 → prof:A, prof:B
  # profile:2 → prof:A, prof:C
  # profile:3 → prof:A, prof:B, prof:C
  # profile:4 → prof:A
  # profile:5 → prof:D
  #
  # In-degree (número de profiles distintos):
  #   prof:A → 4 (profile:1, 2, 3, 4)
  #   prof:B → 2 (profile:1, 3)
  #   prof:C → 2 (profile:2, 3)
  #   prof:D → 1 (profile:5)

  setup do
    name = start_test_instance(graph_type: :bipartite)
    conf = get_conf(name)

    edges = [
      {"profile:1", "prof:A"},
      {"profile:1", "prof:B"},
      {"profile:2", "prof:A"},
      {"profile:2", "prof:C"},
      {"profile:3", "prof:A"},
      {"profile:3", "prof:B"},
      {"profile:3", "prof:C"},
      {"profile:4", "prof:A"},
      {"profile:5", "prof:D"}
    ]

    for {s, t} <- edges do
      MeliGraph.insert_edge(name, s, t, :avaliou)
    end

    # entity_id não importa para GlobalRank, mas a interface exige
    dummy_id = IdMap.get_internal(conf, "profile:1")
    %{conf: conf, name: name, dummy_id: dummy_id}
  end

  describe "compute/4" do
    test "ranks items by in-degree", %{conf: conf, dummy_id: dummy_id} do
      {:ok, results} = GlobalRank.compute(conf, dummy_id, :global, top_k: 10, prefix: "prof:")

      assert is_list(results)
      assert length(results) > 0

      # prof:A deve ser o primeiro (4 profiles apontam)
      [{top_id, top_score} | _] = results
      assert top_id == "prof:A"
      assert top_score == 1.0
    end

    test "normalizes scores relative to max degree", %{conf: conf, dummy_id: dummy_id} do
      {:ok, results} = GlobalRank.compute(conf, dummy_id, :global, top_k: 10, prefix: "prof:")

      scores_map = Map.new(results)

      # prof:A = 4/4 = 1.0
      assert scores_map["prof:A"] == 1.0
      # prof:B = 2/4 = 0.5
      assert scores_map["prof:B"] == 0.5
      # prof:C = 2/4 = 0.5
      assert scores_map["prof:C"] == 0.5
      # prof:D = 1/4 = 0.25
      assert scores_map["prof:D"] == 0.25
    end

    test "prefix filter only returns matching items", %{conf: conf, dummy_id: dummy_id} do
      {:ok, results} = GlobalRank.compute(conf, dummy_id, :global, top_k: 10, prefix: "prof:")

      Enum.each(results, fn {id, _score} ->
        assert String.starts_with?(id, "prof:")
      end)
    end

    test "without prefix returns all vertices with in-degree", %{conf: conf, dummy_id: dummy_id} do
      {:ok, results} = GlobalRank.compute(conf, dummy_id, :global, top_k: 20)

      assert length(results) > 0
    end

    test "min_degree filters low-degree items", %{conf: conf, dummy_id: dummy_id} do
      {:ok, results} = GlobalRank.compute(conf, dummy_id, :global, top_k: 10, prefix: "prof:", min_degree: 2)

      ids = Enum.map(results, fn {id, _score} -> id end)
      # prof:D tem degree 1, deve ser filtrado
      refute "prof:D" in ids
      assert "prof:A" in ids
      assert "prof:B" in ids
      assert "prof:C" in ids
    end

    test "top_k limits results", %{conf: conf, dummy_id: dummy_id} do
      {:ok, results} = GlobalRank.compute(conf, dummy_id, :global, top_k: 2, prefix: "prof:")

      assert length(results) == 2
    end

    test "results are sorted by score descending", %{conf: conf, dummy_id: dummy_id} do
      {:ok, results} = GlobalRank.compute(conf, dummy_id, :global, top_k: 10, prefix: "prof:")

      scores = Enum.map(results, fn {_id, score} -> score end)
      assert scores == Enum.sort(scores, :desc)
    end

    test "returns empty when no items match prefix", %{conf: conf, dummy_id: dummy_id} do
      {:ok, results} = GlobalRank.compute(conf, dummy_id, :global, top_k: 10, prefix: "nonexistent:")

      assert results == []
    end

    test "returns empty for empty graph" do
      name = start_test_instance(graph_type: :bipartite)
      conf = get_conf(name)
      IdMap.get_or_create(conf, "dummy")
      dummy_id = IdMap.get_internal(conf, "dummy")

      {:ok, results} = GlobalRank.compute(conf, dummy_id, :global, top_k: 10, prefix: "prof:")
      assert results == []
    end

    test "works via public API with algorithm option", %{name: name} do
      {:ok, results} = MeliGraph.recommend(name, "profile:1", :global,
        algorithm: :global_rank, top_k: 10, prefix: "prof:")

      assert is_list(results)
      assert length(results) == 4
    end
  end

  defp get_conf(name) do
    registry = Module.concat(name, Registry)
    [{_pid, conf}] = Registry.lookup(registry, :conf)
    conf
  end
end
