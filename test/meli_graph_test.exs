defmodule MeliGraphTest do
  use ExUnit.Case, async: false

  import MeliGraph.TestHelpers

  describe "start_link/1" do
    test "starts a named instance" do
      name = unique_name()
      assert {:ok, pid} = MeliGraph.start_link(name: name, graph_type: :bipartite, testing: :sync)
      assert is_pid(pid)
    end

    test "supports multiple instances" do
      name1 = start_test_instance(graph_type: :directed)
      name2 = start_test_instance(graph_type: :bipartite)

      MeliGraph.insert_edge(name1, "a", "b", :follow)
      MeliGraph.insert_edge(name2, "x", "y", :like)

      assert MeliGraph.edge_count(name1) == 1
      assert MeliGraph.edge_count(name2) == 1
    end
  end

  describe "insert_edge/4 and edge_count/1" do
    test "inserts edges and counts them" do
      name = start_test_instance()

      MeliGraph.insert_edge(name, "user:1", "post:a", :like)
      MeliGraph.insert_edge(name, "user:1", "post:b", :like)
      MeliGraph.insert_edge(name, "user:2", "post:a", :view)

      assert MeliGraph.edge_count(name) == 3
    end
  end

  describe "vertex_count/1" do
    test "counts unique vertices" do
      name = start_test_instance()

      MeliGraph.insert_edge(name, "user:1", "post:a", :like)
      MeliGraph.insert_edge(name, "user:2", "post:a", :like)

      assert MeliGraph.vertex_count(name) == 3
    end
  end

  describe "neighbors/4" do
    test "returns outgoing neighbors" do
      name = start_test_instance()

      MeliGraph.insert_edge(name, "user:1", "post:a", :like)
      MeliGraph.insert_edge(name, "user:1", "post:b", :view)

      neighbors = MeliGraph.neighbors(name, "user:1", :outgoing)
      assert length(neighbors) == 2
      assert "post:a" in neighbors
      assert "post:b" in neighbors
    end

    test "returns incoming neighbors" do
      name = start_test_instance()

      MeliGraph.insert_edge(name, "user:1", "post:a", :like)
      MeliGraph.insert_edge(name, "user:2", "post:a", :view)

      neighbors = MeliGraph.neighbors(name, "post:a", :incoming)
      assert length(neighbors) == 2
      assert "user:1" in neighbors
      assert "user:2" in neighbors
    end

    test "filters by edge type" do
      name = start_test_instance()

      MeliGraph.insert_edge(name, "user:1", "post:a", :like)
      MeliGraph.insert_edge(name, "user:1", "post:b", :view)

      neighbors = MeliGraph.neighbors(name, "user:1", :outgoing, type: :like)
      assert neighbors == ["post:a"]
    end

    test "returns empty for unknown vertex" do
      name = start_test_instance()
      assert MeliGraph.neighbors(name, "unknown", :outgoing) == []
    end
  end

  describe "recommend/4" do
    test "recommends content via pagerank" do
      name = start_test_instance(graph_type: :directed)

      MeliGraph.insert_edge(name, "A", "B", :follow)
      MeliGraph.insert_edge(name, "B", "C", :follow)
      MeliGraph.insert_edge(name, "C", "A", :follow)

      {:ok, recs} = MeliGraph.recommend(name, "A", :users,
        algorithm: :pagerank, num_walks: 500, top_k: 5)

      assert is_list(recs)
      assert length(recs) > 0

      ids = Enum.map(recs, fn {id, _} -> id end)
      assert "B" in ids or "C" in ids
    end

    test "returns empty for unknown user" do
      name = start_test_instance()
      {:ok, recs} = MeliGraph.recommend(name, "nobody", :content)
      assert recs == []
    end
  end

  describe "child_spec/1" do
    test "returns correct child spec" do
      spec = MeliGraph.child_spec(name: :my_graph, graph_type: :directed)
      assert spec.id == :my_graph
      assert spec.type == :supervisor
    end
  end
end
