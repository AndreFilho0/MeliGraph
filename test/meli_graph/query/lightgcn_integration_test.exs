defmodule MeliGraph.Query.LightGCNIntegrationTest do
  use ExUnit.Case, async: false

  import MeliGraph.TestHelpers

  alias MeliGraph.Query

  setup do
    name = start_test_instance()
    conf = get_conf(name)

    # Grafo bipartido pequeno reusado pelos cenários
    for {u, p} <- [
          {"profile:1", "post:a"},
          {"profile:1", "post:b"},
          {"profile:2", "post:a"},
          {"profile:2", "post:c"},
          {"profile:3", "post:b"},
          {"profile:3", "post:d"}
        ] do
      MeliGraph.insert_edge(name, u, p, :curtiu)
    end

    %{name: name, conf: conf}
  end

  describe "recommend/4 com algorithm: :lightgcn" do
    test "fallback transparente para SALSA quando embeddings não estão prontos",
         %{conf: conf} do
      # Sem load_embeddings prévio → LightGCN devolve :embeddings_not_ready,
      # mas Query deve ocultar isso e devolver resultados de SALSA.
      assert {:ok, results} =
               Query.recommend(conf, "profile:1", :content,
                 algorithm: :lightgcn,
                 seed_size: 5,
                 top_k: 3
               )

      assert is_list(results)
      assert Enum.all?(results, fn {ext, score} -> is_binary(ext) and is_number(score) end)
    end

    test "usa LightGCN quando embeddings estão carregados", %{name: name, conf: conf} do
      {:ok, binary} =
        MeliGraph.train_embeddings(name,
          user_prefix: "profile:",
          embedding_dim: 8,
          epochs: 10,
          batch_size: 4
        )

      :ok = MeliGraph.load_embeddings(name, binary)

      {:ok, results} =
        Query.recommend(conf, "profile:1", :content, algorithm: :lightgcn, top_k: 4)

      # Top-K do LightGCN é determinístico para um payload fixo: ordenado por score desc
      scores = Enum.map(results, fn {_, s} -> s end)
      assert scores == Enum.sort(scores, :desc)
      assert length(results) == 4
    end

    test "user inexistente → []", %{conf: conf} do
      assert {:ok, []} =
               Query.recommend(conf, "profile:nope", :content, algorithm: :lightgcn)
    end
  end

  describe "API pública MeliGraph.*" do
    test "embeddings_ready?/1 retorna false antes de load", %{name: name} do
      refute MeliGraph.embeddings_ready?(name)
    end

    test "embeddings_ready?/1 retorna true após load", %{name: name} do
      {:ok, binary} =
        MeliGraph.train_embeddings(name,
          user_prefix: "profile:",
          embedding_dim: 8,
          epochs: 5,
          batch_size: 4
        )

      :ok = MeliGraph.load_embeddings(name, binary)
      assert MeliGraph.embeddings_ready?(name)
    end

    test "train_embeddings/2 sem :user_prefix levanta", %{name: name} do
      assert_raise KeyError, fn ->
        MeliGraph.train_embeddings(name, embedding_dim: 8)
      end
    end

    test "train_embeddings/2 retorna :empty_graph em instância sem arestas user↔item" do
      empty_name = start_test_instance()

      assert {:error, :empty_graph} =
               MeliGraph.train_embeddings(empty_name, user_prefix: "profile:")
    end

    test "load_embeddings/2 rejeita binário inválido", %{name: name} do
      assert {:error, :invalid_binary} = MeliGraph.load_embeddings(name, <<0, 1, 2>>)
      refute MeliGraph.embeddings_ready?(name)
    end
  end

  defp get_conf(name) do
    registry = Module.concat(name, Registry)
    [{_pid, conf}] = Registry.lookup(registry, :conf)
    conf
  end
end
