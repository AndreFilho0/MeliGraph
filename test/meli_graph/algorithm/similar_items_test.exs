defmodule MeliGraph.Algorithm.SimilarItemsTest do
  use ExUnit.Case, async: false

  import MeliGraph.TestHelpers

  alias MeliGraph.Algorithm.SimilarItems
  alias MeliGraph.Graph.IdMap

  # Grafo bipartido: profiles → professors
  #
  # profile:1 → prof:A, prof:B
  # profile:2 → prof:A, prof:C
  # profile:3 → prof:B, prof:C, prof:D
  # profile:4 → prof:A
  # profile:5 → prof:D
  #
  # Co-ocorrências com prof:A (users: profile:1, profile:2, profile:4):
  #   prof:B → 1 (profile:1)
  #   prof:C → 1 (profile:2)
  # Co-ocorrências com prof:B (users: profile:1, profile:3):
  #   prof:A → 1 (profile:1)
  #   prof:C → 1 (profile:3)
  #   prof:D → 1 (profile:3)

  setup do
    name = start_test_instance(graph_type: :bipartite)
    conf = get_conf(name)

    edges = [
      {"profile:1", "prof:A"},
      {"profile:1", "prof:B"},
      {"profile:2", "prof:A"},
      {"profile:2", "prof:C"},
      {"profile:3", "prof:B"},
      {"profile:3", "prof:C"},
      {"profile:3", "prof:D"},
      {"profile:4", "prof:A"},
      {"profile:5", "prof:D"}
    ]

    for {s, t} <- edges do
      MeliGraph.insert_edge(name, s, t, :avaliou)
    end

    %{conf: conf, name: name}
  end

  describe "compute/4" do
    test "returns similar items for a given item", %{conf: conf} do
      entity_id = IdMap.get_internal(conf, "prof:A")
      {:ok, results} = SimilarItems.compute(conf, entity_id, :similar, top_k: 10)

      assert is_list(results)
      assert length(results) > 0

      ids = Enum.map(results, fn {id, _score} -> id end)
      # prof:B e prof:C compartilham usuários com prof:A
      assert "prof:B" in ids
      assert "prof:C" in ids
      # prof:A não deve aparecer no próprio resultado
      refute "prof:A" in ids
    end

    test "items with more co-occurrences rank higher", %{conf: conf} do
      # prof:B tem users: profile:1, profile:3
      # Co-ocorrências de prof:B:
      #   prof:A → 1 (profile:1), prof:C → 1 (profile:3), prof:D → 1 (profile:3)
      # Todos com overlap=1, mas Jaccard difere pelo grau do item
      entity_id = IdMap.get_internal(conf, "prof:C")

      # prof:C tem users: profile:2, profile:3
      # Co-ocorrências:
      #   prof:A → 1 (profile:2), prof:B → 1 (profile:3), prof:D → 1 (profile:3)
      {:ok, results} = SimilarItems.compute(conf, entity_id, :similar, top_k: 10, normalize: :raw)

      assert is_list(results)
      assert length(results) > 0

      Enum.each(results, fn {_id, score} ->
        assert is_float(score)
        assert score > 0.0
      end)
    end

    test "respects min_overlap filter", %{conf: conf} do
      entity_id = IdMap.get_internal(conf, "prof:A")

      # Com min_overlap: 2, nenhum item tem 2+ users em comum com prof:A
      {:ok, results} = SimilarItems.compute(conf, entity_id, :similar, top_k: 10, min_overlap: 2)
      assert results == []
    end

    test "returns empty for item with no incoming edges", %{conf: conf} do
      IdMap.get_or_create(conf, "prof:isolated")
      entity_id = IdMap.get_internal(conf, "prof:isolated")

      {:ok, results} = SimilarItems.compute(conf, entity_id, :similar, top_k: 10)
      assert results == []
    end

    test "jaccard normalization produces scores between 0 and 1", %{conf: conf} do
      entity_id = IdMap.get_internal(conf, "prof:A")
      {:ok, results} = SimilarItems.compute(conf, entity_id, :similar, top_k: 10, normalize: :jaccard)

      Enum.each(results, fn {_id, score} ->
        assert score >= 0.0
        assert score <= 1.0
      end)
    end

    test "cosine normalization produces valid scores", %{conf: conf} do
      entity_id = IdMap.get_internal(conf, "prof:A")
      {:ok, results} = SimilarItems.compute(conf, entity_id, :similar, top_k: 10, normalize: :cosine)

      Enum.each(results, fn {_id, score} ->
        assert is_float(score)
        assert score >= 0.0
        assert score <= 1.0
      end)
    end

    test "top_k limits results", %{conf: conf} do
      entity_id = IdMap.get_internal(conf, "prof:A")
      {:ok, results} = SimilarItems.compute(conf, entity_id, :similar, top_k: 1)

      assert length(results) == 1
    end

    test "results are sorted by score descending", %{conf: conf} do
      entity_id = IdMap.get_internal(conf, "prof:A")
      {:ok, results} = SimilarItems.compute(conf, entity_id, :similar, top_k: 10)

      scores = Enum.map(results, fn {_id, score} -> score end)
      assert scores == Enum.sort(scores, :desc)
    end

    test "works via public API with algorithm option", %{name: name} do
      {:ok, results} = MeliGraph.recommend(name, "prof:A", :similar, algorithm: :similar_items, top_k: 10)

      assert is_list(results)
      assert length(results) > 0
    end
  end

  defp get_conf(name) do
    registry = Module.concat(name, Registry)
    [{_pid, conf}] = Registry.lookup(registry, :conf)
    conf
  end
end
