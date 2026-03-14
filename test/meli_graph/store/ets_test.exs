defmodule MeliGraph.Store.ETSTest do
  use ExUnit.Case, async: false

  import MeliGraph.TestHelpers

  alias MeliGraph.Store.ETS, as: Store

  setup do
    name = start_test_instance()
    conf = get_conf(name)
    %{conf: conf}
  end

  describe "put/4 and get/2" do
    test "stores and retrieves values", %{conf: conf} do
      :ok = Store.put(conf, :key1, "value1", 60_000)
      assert {:ok, "value1"} = Store.get(conf, :key1)
    end

    test "returns :miss for unknown keys", %{conf: conf} do
      assert :miss = Store.get(conf, :nonexistent)
    end

    test "returns :miss for expired entries", %{conf: conf} do
      :ok = Store.put(conf, :expires, "old", 1)
      Process.sleep(5)
      assert :miss = Store.get(conf, :expires)
    end

    test "overwrites existing entries", %{conf: conf} do
      Store.put(conf, :key, "v1", 60_000)
      Store.put(conf, :key, "v2", 60_000)
      assert {:ok, "v2"} = Store.get(conf, :key)
    end
  end

  describe "delete/2" do
    test "removes entry", %{conf: conf} do
      Store.put(conf, :to_delete, "bye", 60_000)
      :ok = Store.delete(conf, :to_delete)
      assert :miss = Store.get(conf, :to_delete)
    end
  end

  describe "clear/1" do
    test "removes all entries", %{conf: conf} do
      Store.put(conf, :a, 1, 60_000)
      Store.put(conf, :b, 2, 60_000)
      :ok = Store.clear(conf)
      assert :miss = Store.get(conf, :a)
      assert :miss = Store.get(conf, :b)
    end
  end

  describe "clean_expired/1" do
    test "removes expired entries and returns count", %{conf: conf} do
      Store.put(conf, :fresh, "keep", 60_000)
      Store.put(conf, :stale1, "remove", 1)
      Store.put(conf, :stale2, "remove", 1)
      Process.sleep(5)

      cleaned = Store.clean_expired(conf)
      assert cleaned == 2
      assert {:ok, "keep"} = Store.get(conf, :fresh)
      assert :miss = Store.get(conf, :stale1)
    end
  end

  defp get_conf(name) do
    registry = Module.concat(name, Registry)
    [{_pid, conf}] = Registry.lookup(registry, :conf)
    conf
  end
end
