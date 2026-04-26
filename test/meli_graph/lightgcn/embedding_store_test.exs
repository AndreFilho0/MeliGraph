defmodule MeliGraph.LightGCN.EmbeddingStoreTest do
  use ExUnit.Case, async: false

  import MeliGraph.TestHelpers

  alias MeliGraph.LightGCN.{EmbeddingStore, Trainer}

  setup do
    name = start_test_instance()
    conf = get_conf(name)
    %{name: name, conf: conf}
  end

  describe "ready?/1" do
    test "retorna false quando nada foi carregado", %{conf: conf} do
      refute EmbeddingStore.ready?(conf)
    end

    test "retorna true após load/2 bem-sucedido", %{name: name, conf: conf} do
      binary = train_small_graph(name, conf)

      :ok = EmbeddingStore.load(conf, binary)
      assert EmbeddingStore.ready?(conf)
    end
  end

  describe "get/1" do
    test "retorna :miss quando nada foi carregado", %{conf: conf} do
      assert :miss = EmbeddingStore.get(conf)
    end

    test "retorna payload completo após load", %{name: name, conf: conf} do
      binary = train_small_graph(name, conf)

      :ok = EmbeddingStore.load(conf, binary)
      assert {:ok, payload} = EmbeddingStore.get(conf)

      assert payload.version == 1
      assert payload.user_count == 3
      assert payload.item_count == 4
      assert is_integer(payload.trained_at)
      assert %Nx.Tensor{} = payload.embeddings
      assert Nx.shape(payload.embeddings) == {7, 8}
      assert map_size(payload.user_index) == 3
      assert map_size(payload.item_index) == 4
    end
  end

  describe "load/2" do
    test "substitui embeddings anteriores", %{name: name, conf: conf} do
      binary_1 = train_small_graph(name, conf)
      :ok = EmbeddingStore.load(conf, binary_1)
      {:ok, first} = EmbeddingStore.get(conf)

      Process.sleep(1100)
      binary_2 = train_small_graph(name, conf)
      :ok = EmbeddingStore.load(conf, binary_2)
      {:ok, second} = EmbeddingStore.get(conf)

      assert second.trained_at >= first.trained_at
      assert binary_1 != binary_2
    end

    test "rejeita binário inválido", %{conf: conf} do
      assert {:error, :invalid_binary} = EmbeddingStore.load(conf, <<0, 1, 2, 3>>)
      refute EmbeddingStore.ready?(conf)
    end

    test "rejeita termo válido mas com formato errado", %{conf: conf} do
      bogus = :erlang.term_to_binary(%{not: "a payload"})
      assert {:error, :invalid_binary} = EmbeddingStore.load(conf, bogus)
      refute EmbeddingStore.ready?(conf)
    end

    test "rejeita não-binário", %{conf: conf} do
      assert {:error, :invalid_binary} = EmbeddingStore.load(conf, :not_binary)
    end
  end

  # --- helpers ---

  defp get_conf(name) do
    registry = Module.concat(name, Registry)
    [{_pid, conf}] = Registry.lookup(registry, :conf)
    conf
  end

  defp train_small_graph(name, conf) do
    MeliGraph.insert_edge(name, "profile:1", "post:a", :curtiu)
    MeliGraph.insert_edge(name, "profile:1", "post:b", :curtiu)
    MeliGraph.insert_edge(name, "profile:2", "post:a", :curtiu)
    MeliGraph.insert_edge(name, "profile:2", "post:c", :curtiu)
    MeliGraph.insert_edge(name, "profile:3", "post:b", :curtiu)
    MeliGraph.insert_edge(name, "profile:3", "post:d", :curtiu)

    {:ok, binary} =
      Trainer.train(conf, "profile:",
        embedding_dim: 8,
        epochs: 5,
        batch_size: 4,
        layers: 3
      )

    binary
  end
end
