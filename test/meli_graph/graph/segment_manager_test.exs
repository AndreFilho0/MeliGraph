defmodule MeliGraph.Graph.SegmentManagerTest do
  use ExUnit.Case, async: false

  import MeliGraph.TestHelpers

  alias MeliGraph.Graph.SegmentManager

  setup do
    name = start_test_instance(segment_max_edges: 3)
    conf = get_conf(name)
    %{conf: conf}
  end

  describe "insert/4" do
    test "inserts edge into active segment", %{conf: conf} do
      assert :ok = SegmentManager.insert(conf, 0, 1, :follow)
      assert SegmentManager.total_edge_count(conf) == 1
    end

    test "rotates segment when full", %{conf: conf} do
      SegmentManager.insert(conf, 0, 1, :follow)
      SegmentManager.insert(conf, 1, 2, :follow)
      SegmentManager.insert(conf, 2, 3, :follow)
      # This should trigger rotation
      SegmentManager.insert(conf, 3, 4, :follow)

      segments = SegmentManager.all_segments(conf)
      assert length(segments) == 2
      assert SegmentManager.total_edge_count(conf) == 4
    end
  end

  describe "neighbors_out/2" do
    test "returns neighbors across all segments", %{conf: conf} do
      # Fill first segment (3 edges)
      SegmentManager.insert(conf, 0, 1, :follow)
      SegmentManager.insert(conf, 0, 2, :follow)
      SegmentManager.insert(conf, 10, 11, :follow)
      # Rotated to new segment
      SegmentManager.insert(conf, 0, 3, :like)

      neighbors = SegmentManager.neighbors_out(conf, 0)
      assert length(neighbors) == 3
    end
  end

  describe "neighbors_in/2" do
    test "returns incoming neighbors", %{conf: conf} do
      SegmentManager.insert(conf, 0, 5, :follow)
      SegmentManager.insert(conf, 1, 5, :like)

      neighbors = SegmentManager.neighbors_in(conf, 5)
      assert length(neighbors) == 2
    end
  end

  describe "prune/2" do
    test "removes segments older than cutoff", %{conf: conf} do
      # Fill and rotate
      SegmentManager.insert(conf, 0, 1, :follow)
      SegmentManager.insert(conf, 1, 2, :follow)
      SegmentManager.insert(conf, 2, 3, :follow)
      SegmentManager.insert(conf, 3, 4, :follow)

      # Prune everything before "now + future"
      cutoff = System.monotonic_time(:millisecond) + 1000
      {:ok, pruned} = SegmentManager.prune(conf, cutoff)

      assert pruned == 1

      # Active segment should still be there
      segments = SegmentManager.all_segments(conf)
      assert length(segments) == 1
    end

    test "does not prune active segment", %{conf: conf} do
      SegmentManager.insert(conf, 0, 1, :follow)

      cutoff = System.monotonic_time(:millisecond) + 1000
      {:ok, pruned} = SegmentManager.prune(conf, cutoff)

      # Active segment is not in frozen list, so 0 pruned
      assert pruned == 0
      assert SegmentManager.total_edge_count(conf) == 1
    end
  end

  describe "all_segments/1" do
    test "returns active segment initially", %{conf: conf} do
      segments = SegmentManager.all_segments(conf)
      assert length(segments) == 1
    end
  end

  defp get_conf(name) do
    registry = Module.concat(name, Registry)
    [{_pid, conf}] = Registry.lookup(registry, :conf)
    conf
  end
end
