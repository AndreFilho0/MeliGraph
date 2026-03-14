defmodule MeliGraph.QueryTest do
  use ExUnit.Case, async: false

  import MeliGraph.TestHelpers

  alias MeliGraph.Query

  setup do
    name = start_test_instance(graph_type: :directed)
    conf = get_conf(name)

    # Grafo: A → B → C → A (ciclo), A → D
    for {s, t} <- [{"A", "B"}, {"B", "C"}, {"C", "A"}, {"A", "D"}] do
      MeliGraph.insert_edge(name, s, t, :follow)
    end

    %{conf: conf, name: name}
  end

  describe "recommend/4 (sync mode)" do
    test "returns recommendations via pagerank", %{conf: conf} do
      {:ok, results} = Query.recommend(conf, "A", :users, algorithm: :pagerank, num_walks: 500, top_k: 5)

      assert is_list(results)
      assert length(results) > 0
    end

    test "returns empty for unknown entity", %{conf: conf} do
      {:ok, results} = Query.recommend(conf, "nonexistent", :users)
      assert results == []
    end
  end

  defp get_conf(name) do
    registry = Module.concat(name, Registry)
    [{_pid, conf}] = Registry.lookup(registry, :conf)
    conf
  end
end
