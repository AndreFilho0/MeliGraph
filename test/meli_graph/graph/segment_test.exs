defmodule MeliGraph.Graph.SegmentTest do
  use ExUnit.Case, async: true

  alias MeliGraph.Graph.Segment

  setup do
    segment = Segment.new(0, 10)
    %{segment: segment}
  end

  describe "new/2" do
    test "creates segment with correct initial state", %{segment: segment} do
      assert segment.id == 0
      assert segment.max_edges == 10
      assert segment.edge_count == 0
      assert segment.created_at != 0
    end
  end

  describe "insert/4" do
    test "inserts edge and increments count", %{segment: segment} do
      assert {:ok, updated} = Segment.insert(segment, 0, 1, :follow)
      assert updated.edge_count == 1
    end

    test "returns :full when segment is at capacity" do
      segment = Segment.new(1, 2)

      {:ok, segment} = Segment.insert(segment, 0, 1, :follow)
      {:ok, segment} = Segment.insert(segment, 1, 2, :follow)
      assert :full = Segment.insert(segment, 2, 3, :follow)

      Segment.destroy(segment)
    end
  end

  describe "neighbors_out/2" do
    test "returns outgoing neighbors", %{segment: segment} do
      {:ok, segment} = Segment.insert(segment, 0, 1, :follow)
      {:ok, _segment} = Segment.insert(segment, 0, 2, :like)

      neighbors = Segment.neighbors_out(segment, 0)
      assert length(neighbors) == 2
      assert {1, :follow, 1.0} in neighbors
      assert {2, :like, 1.0} in neighbors
    end

    test "returns empty for vertex with no outgoing edges", %{segment: segment} do
      assert Segment.neighbors_out(segment, 99) == []
    end
  end

  describe "neighbors_in/2" do
    test "returns incoming neighbors", %{segment: segment} do
      {:ok, segment} = Segment.insert(segment, 0, 2, :follow)
      {:ok, _segment} = Segment.insert(segment, 1, 2, :follow)

      neighbors = Segment.neighbors_in(segment, 2)
      assert length(neighbors) == 2
      assert {0, :follow, 1.0} in neighbors
      assert {1, :follow, 1.0} in neighbors
    end
  end

  describe "neighbors_out/3 (filtered by type)" do
    test "filters by edge type", %{segment: segment} do
      {:ok, segment} = Segment.insert(segment, 0, 1, :follow)
      {:ok, segment} = Segment.insert(segment, 0, 2, :like)
      {:ok, _segment} = Segment.insert(segment, 0, 3, :follow)

      follows = Segment.neighbors_out(segment, 0, :follow)
      assert length(follows) == 2
      assert 1 in follows
      assert 3 in follows
    end
  end

  describe "neighbors_in/3 (filtered by type)" do
    test "filters by edge type", %{segment: segment} do
      {:ok, segment} = Segment.insert(segment, 0, 2, :follow)
      {:ok, _segment} = Segment.insert(segment, 1, 2, :like)

      follows = Segment.neighbors_in(segment, 2, :follow)
      assert follows == [0]
    end
  end

  describe "full?/1" do
    test "returns false when not full", %{segment: segment} do
      refute Segment.full?(segment)
    end

    test "returns true when full" do
      segment = Segment.new(2, 1)
      {:ok, segment} = Segment.insert(segment, 0, 1, :follow)
      assert Segment.full?(segment)
      Segment.destroy(segment)
    end
  end

  describe "edge_count/1" do
    test "returns current edge count", %{segment: segment} do
      assert Segment.edge_count(segment) == 0
      {:ok, segment} = Segment.insert(segment, 0, 1, :follow)
      assert Segment.edge_count(segment) == 1
    end
  end
end
