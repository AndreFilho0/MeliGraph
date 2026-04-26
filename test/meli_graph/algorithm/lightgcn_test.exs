defmodule MeliGraph.Algorithm.LightGCNTest do
  use ExUnit.Case, async: false

  import MeliGraph.TestHelpers

  alias MeliGraph.Algorithm.LightGCN
  alias MeliGraph.Graph.IdMap
  alias MeliGraph.LightGCN.{EmbeddingStore, Trainer}

  setup do
    name = start_test_instance()
    conf = get_conf(name)
    %{name: name, conf: conf}
  end

  describe "compute/4 — pré-requisitos" do
    test "retorna :embeddings_not_ready quando nada foi carregado", %{conf: conf} do
      assert {:error, :embeddings_not_ready} = LightGCN.compute(conf, 0, :content, [])
    end

    test "retorna [] para usuário não visto no treino", %{name: name, conf: conf} do
      train_and_load(name, conf)

      # Usuário inexistente no IdMap → o Query layer já tratou isso, mas
      # também queremos blindagem aqui: passamos um internal_id qualquer
      # que não existe no user_index (ex: o internal_id de um item).
      item_internal_id = IdMap.get_internal(conf, "post:a")
      assert {:ok, []} = LightGCN.compute(conf, item_internal_id, :content, [])
    end

    test "retorna [] para usuário existente no IdMap mas fora do user_index",
         %{name: name, conf: conf} do
      train_and_load(name, conf)

      # Inserimos um novo user APÓS o treino — ele não está no payload
      MeliGraph.insert_edge(name, "profile:99", "post:a", :curtiu)
      new_user_internal = IdMap.get_internal(conf, "profile:99")

      assert {:ok, []} = LightGCN.compute(conf, new_user_internal, :content, [])
    end
  end

  describe "compute/4 — top-K" do
    test "retorna pares {external_id, score} ordenados por score desc",
         %{name: name, conf: conf} do
      train_and_load(name, conf)

      user_internal = IdMap.get_internal(conf, "profile:1")
      {:ok, results} = LightGCN.compute(conf, user_internal, :content, top_k: 4)

      assert length(results) == 4
      assert Enum.all?(results, fn {ext, score} -> is_binary(ext) and is_float(score) end)

      scores = Enum.map(results, fn {_, s} -> s end)
      assert scores == Enum.sort(scores, :desc)
    end

    test "respeita o limite de top_k", %{name: name, conf: conf} do
      train_and_load(name, conf)

      user_internal = IdMap.get_internal(conf, "profile:1")
      {:ok, results} = LightGCN.compute(conf, user_internal, :content, top_k: 2)

      assert length(results) == 2
    end

    test "default de top_k é 20", %{name: name, conf: conf} do
      train_and_load(name, conf)

      user_internal = IdMap.get_internal(conf, "profile:1")
      {:ok, results} = LightGCN.compute(conf, user_internal, :content, [])

      # Só temos 4 itens no grafo, então retorna no máximo 4
      assert length(results) == 4
    end

    test "todos os resultados são external_ids de itens (não users)",
         %{name: name, conf: conf} do
      train_and_load(name, conf)

      user_internal = IdMap.get_internal(conf, "profile:1")
      {:ok, results} = LightGCN.compute(conf, user_internal, :content, top_k: 10)

      Enum.each(results, fn {ext_id, _score} ->
        refute String.starts_with?(ext_id, "profile:"),
               "esperado item, recebeu user: #{ext_id}"
      end)
    end
  end

  describe "compute/4 — qualidade do ranking" do
    @tag timeout: 60_000
    test "user prefere itens do seu cluster a itens de outro cluster",
         %{name: name, conf: conf} do
      # Cluster A: u1, u2 ↔ post:a, post:b
      # Cluster B: u3, u4 ↔ post:c, post:d
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

      :ok = EmbeddingStore.load(conf, binary)

      user_internal = IdMap.get_internal(conf, "profile:1")
      {:ok, results} = LightGCN.compute(conf, user_internal, :content, top_k: 4)

      score_for = fn ext_id ->
        {_id, score} = Enum.find(results, fn {id, _} -> id == ext_id end)
        score
      end

      best_in_cluster = max(score_for.("post:a"), score_for.("post:b"))
      best_out_cluster = max(score_for.("post:c"), score_for.("post:d"))

      assert best_in_cluster > best_out_cluster,
             "esperado score do cluster do usuário > score de outro cluster, " <>
               "got in=#{best_in_cluster} out=#{best_out_cluster}"
    end
  end

  # --- helpers ---

  defp get_conf(name) do
    registry = Module.concat(name, Registry)
    [{_pid, conf}] = Registry.lookup(registry, :conf)
    conf
  end

  defp train_and_load(name, conf) do
    MeliGraph.insert_edge(name, "profile:1", "post:a", :curtiu)
    MeliGraph.insert_edge(name, "profile:1", "post:b", :curtiu)
    MeliGraph.insert_edge(name, "profile:2", "post:a", :curtiu)
    MeliGraph.insert_edge(name, "profile:2", "post:c", :curtiu)
    MeliGraph.insert_edge(name, "profile:3", "post:b", :curtiu)
    MeliGraph.insert_edge(name, "profile:3", "post:d", :curtiu)

    {:ok, binary} =
      Trainer.train(conf, "profile:",
        embedding_dim: 8,
        epochs: 10,
        batch_size: 4,
        layers: 3
      )

    :ok = EmbeddingStore.load(conf, binary)
  end
end
