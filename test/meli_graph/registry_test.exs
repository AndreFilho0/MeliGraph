defmodule MeliGraph.RegistryTest do
  use ExUnit.Case, async: true

  alias MeliGraph.Config

  setup do
    name = :"reg_test_#{System.unique_integer([:positive])}"
    registry_name = Module.concat(name, Registry)
    start_supervised!({Registry, keys: :unique, name: registry_name})
    conf = %Config{name: name, graph_type: :directed, registry: registry_name}
    %{conf: conf}
  end

  describe "via/2" do
    test "returns via tuple", %{conf: conf} do
      assert {:via, Registry, {conf.registry, :some_key}} == MeliGraph.Registry.via(conf, :some_key)
    end
  end

  describe "whereis/2" do
    test "returns nil when process not registered", %{conf: conf} do
      assert MeliGraph.Registry.whereis(conf, :missing) == nil
    end

    test "returns pid when process is registered", %{conf: conf} do
      {:ok, _} = Registry.register(conf.registry, :my_process, nil)
      assert MeliGraph.Registry.whereis(conf, :my_process) == self()
    end
  end
end
