defmodule MeliGraph.Plugins.CacheCleanerTest do
  use ExUnit.Case, async: false

  alias MeliGraph.Plugins.CacheCleaner

  describe "validate/1" do
    test "accepts valid options" do
      assert :ok = CacheCleaner.validate(interval: 1000)
    end

    test "rejects missing interval" do
      assert {:error, _} = CacheCleaner.validate([])
    end
  end
end
