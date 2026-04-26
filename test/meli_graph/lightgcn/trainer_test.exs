defmodule MeliGraph.LightGCN.TrainerTest do
  use ExUnit.Case, async: false

  import MeliGraph.TestHelpers

  alias MeliGraph.LightGCN.Trainer

  setup do
    name = start_test_instance()
    conf = get_conf(name)
    %{name: name, conf: conf}
  end

  describe "train/3 — casos de erro" do
    test "grafo vazio retorna :empty_graph", %{conf: conf} do
      assert {:error, :empty_graph} = Trainer.train(conf, "profile:")
    end

    test "grafo só com users retorna :empty_graph", %{name: name, conf: conf} do
      MeliGraph.insert_edge(name, "profile:1", "profile:2", :follow)
      assert {:error, :empty_graph} = Trainer.train(conf, "profile:")
    end
  end

  describe "train/3 — caminho feliz" do
    setup %{name: name} do
      # Pequeno grafo bipartido: 3 users, 4 items, 6 interações
      MeliGraph.insert_edge(name, "profile:1", "post:a", :curtiu)
      MeliGraph.insert_edge(name, "profile:1", "post:b", :curtiu)
      MeliGraph.insert_edge(name, "profile:2", "post:a", :curtiu)
      MeliGraph.insert_edge(name, "profile:2", "post:c", :curtiu)
      MeliGraph.insert_edge(name, "profile:3", "post:b", :curtiu)
      MeliGraph.insert_edge(name, "profile:3", "post:d", :curtiu)
      :ok
    end

    test "retorna binary serializável após treino curto", %{conf: conf} do
      assert {:ok, binary} =
               Trainer.train(conf, "profile:",
                 embedding_dim: 8,
                 epochs: 5,
                 batch_size: 4,
                 layers: 3
               )

      assert is_binary(binary)
      assert byte_size(binary) > 0
    end

    test "payload deserializado tem shape e estrutura corretos", %{conf: conf} do
      {:ok, binary} =
        Trainer.train(conf, "profile:",
          embedding_dim: 8,
          epochs: 5,
          batch_size: 4
        )

      payload = :erlang.binary_to_term(binary)

      assert payload.version == 1
      assert payload.user_count == 3
      assert payload.item_count == 4
      assert is_integer(payload.trained_at)

      assert map_size(payload.user_index) == 3
      assert map_size(payload.item_index) == 4

      # 7 nós (3 + 4) × 8 dims
      assert Nx.shape(payload.embeddings) == {7, 8}
    end

    test "embeddings finitos (sem NaN/Inf)", %{conf: conf} do
      {:ok, binary} =
        Trainer.train(conf, "profile:",
          embedding_dim: 8,
          epochs: 10,
          batch_size: 4
        )

      payload = :erlang.binary_to_term(binary)
      values = payload.embeddings |> Nx.to_flat_list()

      refute Enum.any?(values, &(:erlang.is_float(&1) and (&1 != &1)))
      refute Enum.any?(values, &(&1 in [:infinity, :neg_infinity]))
      assert Enum.all?(values, &is_float/1)
    end

    test "embeddings mudam após treino (não ficam iguais ao Xavier inicial)", %{conf: conf} do
      :rand.seed(:exsss, {1, 2, 3})

      {:ok, binary_1} =
        Trainer.train(conf, "profile:",
          embedding_dim: 8,
          epochs: 1,
          batch_size: 4,
          learning_rate: 0.0
        )

      :rand.seed(:exsss, {1, 2, 3})

      {:ok, binary_2} =
        Trainer.train(conf, "profile:",
          embedding_dim: 8,
          epochs: 50,
          batch_size: 4,
          learning_rate: 0.05
        )

      payload_1 = :erlang.binary_to_term(binary_1)
      payload_2 = :erlang.binary_to_term(binary_2)

      diff =
        Nx.subtract(payload_2.embeddings, payload_1.embeddings)
        |> Nx.abs()
        |> Nx.sum()
        |> Nx.to_number()

      assert diff > 0.0
    end

    test "user_index e item_index têm linhas distintas", %{conf: conf} do
      {:ok, binary} =
        Trainer.train(conf, "profile:",
          embedding_dim: 8,
          epochs: 3,
          batch_size: 4
        )

      payload = :erlang.binary_to_term(binary)

      user_rows = MapSet.new(Map.values(payload.user_index))
      item_rows = MapSet.new(Map.values(payload.item_index))

      assert MapSet.disjoint?(user_rows, item_rows)
    end
  end

  describe "train/3 — sanity check de aprendizado" do
    @tag timeout: 60_000
    test "users do mesmo cluster ficam mais próximos que de clusters diferentes",
         %{name: name, conf: conf} do
      # Cenário com sinal claro:
      #   Cluster A: u1, u2 ↔ i_a, i_b
      #   Cluster B: u3, u4 ↔ i_c, i_d
      # Após treino, dot(u1, u2) deve ser > dot(u1, u3).
      MeliGraph.insert_edge(name, "profile:1", "post:a", :curtiu)
      MeliGraph.insert_edge(name, "profile:1", "post:b", :curtiu)
      MeliGraph.insert_edge(name, "profile:2", "post:a", :curtiu)
      MeliGraph.insert_edge(name, "profile:2", "post:b", :curtiu)
      MeliGraph.insert_edge(name, "profile:3", "post:c", :curtiu)
      MeliGraph.insert_edge(name, "profile:3", "post:d", :curtiu)
      MeliGraph.insert_edge(name, "profile:4", "post:c", :curtiu)
      MeliGraph.insert_edge(name, "profile:4", "post:d", :curtiu)

      :rand.seed(:exsss, {42, 42, 42})

      {:ok, binary} =
        Trainer.train(conf, "profile:",
          embedding_dim: 16,
          epochs: 300,
          batch_size: 8,
          learning_rate: 0.05
        )

      payload = :erlang.binary_to_term(binary)

      u1 = embedding_for(payload, conf, "profile:1")
      u2 = embedding_for(payload, conf, "profile:2")
      u3 = embedding_for(payload, conf, "profile:3")

      same_cluster = dot(u1, u2)
      cross_cluster = dot(u1, u3)

      assert same_cluster > cross_cluster,
             "esperado dot(u1, u2)=#{same_cluster} > dot(u1, u3)=#{cross_cluster}"
    end
  end

  # --- helpers ---

  defp get_conf(name) do
    registry = Module.concat(name, Registry)
    [{_pid, conf}] = Registry.lookup(registry, :conf)
    conf
  end

  defp embedding_for(payload, conf, external_id) do
    internal_id = MeliGraph.Graph.IdMap.get_internal(conf, external_id)
    row = Map.fetch!(payload.user_index, internal_id)
    Nx.slice(payload.embeddings, [row, 0], [1, Nx.axis_size(payload.embeddings, 1)])
  end

  defp dot(a, b) do
    Nx.dot(a, [1], b, [1]) |> Nx.reshape({}) |> Nx.to_number()
  end
end
