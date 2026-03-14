defmodule MeliGraph.Plugins.PrunerTest do
  use ExUnit.Case, async: false

  alias MeliGraph.Plugins.Pruner

  describe "validate/1" do
    test "accepts valid options" do
      assert :ok = Pruner.validate(interval: 5000)
    end

    test "rejects missing interval" do
      assert {:error, _} = Pruner.validate([])
    end

    test "rejects non-integer interval" do
      assert {:error, _} = Pruner.validate(interval: "5000")
    end
  end
end
