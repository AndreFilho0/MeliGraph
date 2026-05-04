defmodule MeliGraph.Algorithm.SimilarItems do
  @moduledoc """
  Algoritmo de co-ocorrência para encontrar itens similares via 2-hop.

  Dado um item semente (ex: professor), encontra outros itens que compartilham
  usuários em comum, ponderando pela sobreposição de audiência.

  ## Fluxo (2-hop)

  1. Partindo do item semente, coleta todos os usuários que interagiram (neighbors_in)
  2. Para cada usuário, coleta os outros itens com que interagiu (neighbors_out)
  3. Conta co-ocorrências: quantos usuários em comum cada item tem com o semente
  4. Normaliza pelo grau do item (Jaccard-like) para não favorecer itens populares demais
  5. Retorna top-K itens rankeados por similaridade

  ## Parâmetros (via opts)

    * `:top_k` - número de resultados a retornar (padrão: 20)
    * `:min_overlap` - mínimo de usuários em comum para considerar (padrão: 1)
    * `:normalize` - `:jaccard` | `:cosine` | `:raw` (padrão: `:jaccard`)

  ## Exemplo

  Num grafo bipartido profile → professor:

      professor:silva ←── [profile:42, profile:99, profile:77]
                                ↓           ↓           ↓
                          professor:costa  professor:oliveira  professor:costa

      Co-ocorrências com professor:silva:
        professor:costa    → 2 usuários em comum (profile:42, profile:77)
        professor:oliveira → 1 usuário em comum  (profile:99)
  """

  @behaviour MeliGraph.Algorithm

  alias MeliGraph.Config
  alias MeliGraph.Graph.{IdMap, SegmentManager}

  @default_top_k 20
  @default_min_overlap 1
  @default_normalize :jaccard

  @impl true
  def compute(%Config{} = conf, entity_id, _type, opts) do
    top_k = Keyword.get(opts, :top_k, @default_top_k)
    min_overlap = Keyword.get(opts, :min_overlap, @default_min_overlap)
    normalize = Keyword.get(opts, :normalize, @default_normalize)

    # 1. Usuários que interagiram com o item semente (neighbors_in)
    seed_users =
      SegmentManager.neighbors_in(conf, entity_id)
      |> Enum.map(fn {user_id, _type, _weight} -> user_id end)
      |> Enum.uniq()

    if seed_users == [] do
      {:ok, []}
    else
      seed_user_set = MapSet.new(seed_users)
      seed_degree = MapSet.size(seed_user_set)

      # 2. Para cada usuário, coletar os outros itens (neighbors_out)
      # 3. Contar co-ocorrências por item
      {co_occurrences, item_degrees} =
        Enum.reduce(seed_users, {%{}, %{}}, fn user_id, {co_occ, degrees} ->
          items =
            SegmentManager.neighbors_out(conf, user_id)
            |> Enum.map(fn {item_id, _type, _weight} -> item_id end)
            |> Enum.uniq()

          Enum.reduce(items, {co_occ, degrees}, fn item_id, {co_acc, deg_acc} ->
            if item_id == entity_id do
              {co_acc, deg_acc}
            else
              co_acc = Map.update(co_acc, item_id, 1, &(&1 + 1))
              deg_acc = Map.update(deg_acc, item_id, MapSet.new([user_id]), &MapSet.put(&1, user_id))
              {co_acc, deg_acc}
            end
          end)
        end)

      # 4. Normalizar e filtrar
      results =
        co_occurrences
        |> Enum.filter(fn {_item_id, overlap} -> overlap >= min_overlap end)
        |> Enum.map(fn {item_id, overlap} ->
          score = normalize_score(normalize, overlap, seed_degree, MapSet.size(Map.get(item_degrees, item_id, MapSet.new())))
          {item_id, score}
        end)
        |> Enum.sort_by(fn {_id, score} -> score end, :desc)
        |> Enum.take(top_k)

      # 5. Resolver IDs externos
      results =
        Enum.map(results, fn {internal_id, score} ->
          {IdMap.get_external(conf, internal_id), score}
        end)

      {:ok, results}
    end
  end

  # --- Normalização ---

  defp normalize_score(:raw, overlap, _seed_degree, _item_degree), do: overlap / 1.0

  defp normalize_score(:jaccard, overlap, seed_degree, item_degree) do
    union = seed_degree + item_degree - overlap
    if union > 0, do: overlap / union, else: 0.0
  end

  defp normalize_score(:cosine, overlap, seed_degree, item_degree) do
    denominator = :math.sqrt(seed_degree * item_degree)
    if denominator > 0, do: overlap / denominator, else: 0.0
  end
end
