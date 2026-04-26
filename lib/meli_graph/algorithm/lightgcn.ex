defmodule MeliGraph.Algorithm.LightGCN do
  @moduledoc """
  Algoritmo de recomendação LightGCN — inferência via dot product entre
  o embedding do usuário e o de cada item.

  A inferência é puramente algébrica: o trabalho pesado (propagação +
  aprendizado) já foi feito pelo `MeliGraph.LightGCN.Trainer`. Aqui só
  recuperamos o payload do `EmbeddingStore`, calculamos `e_u · E_items^T`
  e devolvemos os top-K.

  ## Pré-requisito

  Embeddings precisam estar carregados via `MeliGraph.load_embeddings/2`
  (ou diretamente via `MeliGraph.LightGCN.EmbeddingStore.load/2`). Se não
  estiverem, retorna `{:error, :embeddings_not_ready}` — o `Query` layer
  trata esse erro fazendo fallback para SALSA na Fase 6.

  ## Parâmetros (via opts)

    * `:top_k` - número de resultados a retornar (padrão: 20)

  ## Comportamento

  - Usuário visto no treino → top-K itens por score
  - Usuário não visto no treino (cold-start) → `{:ok, []}`
  - Embeddings não carregados → `{:error, :embeddings_not_ready}`
  """

  @behaviour MeliGraph.Algorithm

  alias MeliGraph.Config
  alias MeliGraph.Graph.IdMap
  alias MeliGraph.LightGCN.EmbeddingStore

  @default_top_k 20

  @impl true
  def compute(%Config{} = conf, entity_id, _type, opts) do
    top_k = Keyword.get(opts, :top_k, @default_top_k)

    case EmbeddingStore.get(conf) do
      :miss ->
        {:error, :embeddings_not_ready}

      {:ok, payload} ->
        score_user(conf, entity_id, payload, top_k)
    end
  end

  # --- Private ---

  defp score_user(conf, entity_id, payload, top_k) do
    %{embeddings: e_all, user_index: u_idx, item_index: i_idx} = payload

    case Map.get(u_idx, entity_id) do
      nil ->
        # Usuário não estava no grafo no momento do treino — cold start.
        # O Query layer pode aplicar fallback adicional (ex: GlobalRank).
        {:ok, []}

      row_idx ->
        # `Map.to_list/1` itera na mesma ordem para chaves e valores
        # — usamos isso para alinhar internal_ids com as linhas do tensor.
        {item_internal_ids, item_rows} =
          i_idx
          |> Map.to_list()
          |> Enum.unzip()

        e_u = e_all[row_idx]
        e_items = Nx.take(e_all, Nx.tensor(item_rows, type: :s64))

        scores =
          e_items
          |> Nx.dot(e_u)
          |> Nx.to_flat_list()

        scores
        |> Enum.zip(item_internal_ids)
        |> Enum.sort_by(fn {score, _} -> score end, :desc)
        |> Enum.take(top_k)
        |> Enum.map(fn {score, internal_id} ->
          {IdMap.get_external(conf, internal_id), score}
        end)
        |> then(&{:ok, &1})
    end
  end
end
