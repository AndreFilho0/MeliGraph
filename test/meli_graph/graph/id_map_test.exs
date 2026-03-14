defmodule MeliGraph.Graph.IdMapTest do
  use ExUnit.Case, async: false

  import MeliGraph.TestHelpers

  alias MeliGraph.Graph.IdMap

  setup do
    name = start_test_instance()
    conf = get_conf(name)
    %{conf: conf, name: name}
  end

  describe "get_or_create/2" do
    test "assigns sequential internal IDs", %{conf: conf} do
      id0 = IdMap.get_or_create(conf, "user:1")
      id1 = IdMap.get_or_create(conf, "user:2")
      id2 = IdMap.get_or_create(conf, "user:3")

      assert id0 == 0
      assert id1 == 1
      assert id2 == 2
    end

    test "returns same ID for same external ID", %{conf: conf} do
      id1 = IdMap.get_or_create(conf, "user:1")
      id2 = IdMap.get_or_create(conf, "user:1")

      assert id1 == id2
    end

    test "handles various external ID types", %{conf: conf} do
      _str = IdMap.get_or_create(conf, "string_id")
      _int = IdMap.get_or_create(conf, 42)
      _tuple = IdMap.get_or_create(conf, {:user, 1})

      assert IdMap.size(conf) == 3
    end
  end

  describe "get_internal/2" do
    test "returns internal ID for known external ID", %{conf: conf} do
      expected = IdMap.get_or_create(conf, "user:1")
      assert IdMap.get_internal(conf, "user:1") == expected
    end

    test "returns nil for unknown external ID", %{conf: conf} do
      assert IdMap.get_internal(conf, "unknown") == nil
    end
  end

  describe "get_external/2" do
    test "returns external ID for known internal ID", %{conf: conf} do
      IdMap.get_or_create(conf, "user:42")
      internal = IdMap.get_internal(conf, "user:42")
      assert IdMap.get_external(conf, internal) == "user:42"
    end

    test "returns nil for unknown internal ID", %{conf: conf} do
      assert IdMap.get_external(conf, 9999) == nil
    end
  end

  describe "size/1" do
    test "returns 0 initially", %{conf: conf} do
      assert IdMap.size(conf) == 0
    end

    test "increases with new mappings", %{conf: conf} do
      IdMap.get_or_create(conf, "a")
      IdMap.get_or_create(conf, "b")
      assert IdMap.size(conf) == 2
    end
  end

  defp get_conf(name) do
    registry = Module.concat(name, Registry)
    [{_pid, conf}] = Registry.lookup(registry, :conf)
    conf
  end
end
