defmodule MeliGraph.Algorithm.GlobalRank do
  @moduledoc """
  Ranking global de itens por grau de entrada (in-degree).

  Computa a "influência" de cada item no grafo baseado em quantos
  vértices distintos apontam para ele. Útil para recomendar itens
  populares a usuários sem histórico (cold start / anônimos).

  ## Fluxo

  1. Itera sobre todos os vértices conhecidos no IdMap
  2. Para cada vértice, conta seus vizinhos de entrada (in-degree)
  3. Filtra apenas itens do tipo desejado (via prefixo do external_id)
  4. Rankeia por in-degree normalizado

  ## Parâmetros (via opts)

    * `:top_k` - número de resultados a retornar (padrão: 20)
    * `:prefix` - prefixo do external_id para filtrar (ex: "professor:")
      Se nil, retorna todos os vértices rankeados (padrão: nil)
    * `:min_degree` - grau mínimo de entrada para considerar (padrão: 1)

  ## Nota

  O `entity_id` passado no `compute/4` é ignorado neste algoritmo, pois
  o ranking é global (não personalizado). Pode-se passar qualquer ID válido.
  """

  @behaviour MeliGraph.Algorithm

  alias MeliGraph.Config
  alias MeliGraph.Graph.{IdMap, SegmentManager}

  @default_top_k 20
  @default_min_degree 1

  @impl true
  def compute(%Config{} = conf, _entity_id, _type, opts) do
    top_k = Keyword.get(opts, :top_k, @default_top_k)
    prefix = Keyword.get(opts, :prefix, nil)
    min_degree = Keyword.get(opts, :min_degree, @default_min_degree)

    # 1. Obter todos os IDs internos do grafo
    all_ids = IdMap.all_ids(conf)

    # 2. Para cada ID, computar in-degree e filtrar por prefixo
    ranked =
      all_ids
      |> Enum.map(fn {internal_id, external_id} ->
        {internal_id, external_id}
      end)
      |> maybe_filter_prefix(prefix)
      |> Enum.map(fn {internal_id, external_id} ->
        in_degree =
          SegmentManager.neighbors_in(conf, internal_id)
          |> Enum.map(fn {id, _type} -> id end)
          |> Enum.uniq()
          |> length()

        {external_id, in_degree}
      end)
      |> Enum.filter(fn {_id, degree} -> degree >= min_degree end)
      |> Enum.sort_by(fn {_id, degree} -> degree end, :desc)
      |> Enum.take(top_k)

    # 3. Normalizar scores
    results = normalize(ranked)

    {:ok, results}
  end

  # --- Private ---

  defp maybe_filter_prefix(ids, nil), do: ids

  defp maybe_filter_prefix(ids, prefix) do
    Enum.filter(ids, fn {_internal_id, external_id} ->
      is_binary(external_id) and String.starts_with?(external_id, prefix)
    end)
  end

  defp normalize([]), do: []

  defp normalize(ranked) do
    max_degree = ranked |> Enum.map(fn {_id, d} -> d end) |> Enum.max()

    if max_degree == 0 do
      Enum.map(ranked, fn {id, _d} -> {id, 0.0} end)
    else
      Enum.map(ranked, fn {id, degree} -> {id, degree / max_degree} end)
    end
  end
end
