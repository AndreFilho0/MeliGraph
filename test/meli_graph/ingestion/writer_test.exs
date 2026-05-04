defmodule MeliGraph.Ingestion.WriterTest do
  use ExUnit.Case, async: false

  import MeliGraph.TestHelpers

  alias MeliGraph.Ingestion.Writer
  alias MeliGraph.Graph.{IdMap, SegmentManager}

  setup do
    name = start_test_instance()
    conf = get_conf(name)
    %{conf: conf}
  end

  describe "insert_edge/4 (sync mode)" do
    test "inserts edge and maps IDs", %{conf: conf} do
      :ok = Writer.insert_edge(conf, "user:1", "post:a", :like)

      assert IdMap.get_internal(conf, "user:1") != nil
      assert IdMap.get_internal(conf, "post:a") != nil
      assert SegmentManager.total_edge_count(conf) == 1
    end

    test "inserts multiple edges", %{conf: conf} do
      :ok = Writer.insert_edge(conf, "user:1", "post:a", :like)
      :ok = Writer.insert_edge(conf, "user:1", "post:b", :like)
      :ok = Writer.insert_edge(conf, "user:2", "post:a", :view)

      assert SegmentManager.total_edge_count(conf) == 3
      assert IdMap.size(conf) == 4
    end

    test "handles different edge types", %{conf: conf} do
      :ok = Writer.insert_edge(conf, "u1", "u2", :follow)
      :ok = Writer.insert_edge(conf, "u1", "p1", :like)
      :ok = Writer.insert_edge(conf, "u1", "p2", :view)

      source_id = IdMap.get_internal(conf, "u1")
      neighbors = SegmentManager.neighbors_out(conf, source_id)
      types = Enum.map(neighbors, fn {_id, type, _weight} -> type end) |> Enum.sort()

      assert types == [:follow, :like, :view]
    end
  end

  defp get_conf(name) do
    registry = Module.concat(name, Registry)
    [{_pid, conf}] = Registry.lookup(registry, :conf)
    conf
  end
end
