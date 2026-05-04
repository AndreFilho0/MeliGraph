defmodule MeliGraph.Algorithm.PageRank do
  @moduledoc """
  PageRank Personalizado via Monte Carlo random walks.

  Baseado no paper WTF (seção 5.1): computa o "Circle of Trust" de um
  vértice semente através de random walks com reset.

  ## Parâmetros (via opts)

    * `:num_walks` - número de random walks (padrão: 1000)
    * `:walk_length` - comprimento máximo de cada walk (padrão: 10)
    * `:reset_prob` - probabilidade de reset para o vértice semente (padrão: 0.15)
    * `:top_k` - número de resultados a retornar (padrão: 100)
  """

  @behaviour MeliGraph.Algorithm

  alias MeliGraph.Config
  alias MeliGraph.Graph.{IdMap, SegmentManager}

  @default_num_walks 1_000
  @default_walk_length 10
  @default_reset_prob 0.15
  @default_top_k 100

  @impl true
  def compute(%Config{} = conf, entity_id, _type, opts) do
    num_walks = Keyword.get(opts, :num_walks, @default_num_walks)
    walk_length = Keyword.get(opts, :walk_length, @default_walk_length)
    reset_prob = Keyword.get(opts, :reset_prob, @default_reset_prob)
    top_k = Keyword.get(opts, :top_k, @default_top_k)

    visit_counts = run_walks(conf, entity_id, num_walks, walk_length, reset_prob)

    results =
      visit_counts
      |> Map.delete(entity_id)
      |> Enum.sort_by(fn {_id, count} -> count end, :desc)
      |> Enum.take(top_k)
      |> normalize_scores()
      |> resolve_external_ids(conf)

    {:ok, results}
  end

  # --- Private ---

  defp run_walks(conf, seed, num_walks, walk_length, reset_prob) do
    Enum.reduce(1..num_walks, %{}, fn _i, visits ->
      walk(conf, seed, seed, walk_length, reset_prob, visits)
    end)
  end

  defp walk(_conf, _seed, _current, 0, _reset_prob, visits), do: visits

  defp walk(conf, seed, current, steps_left, reset_prob, visits) do
    visits = Map.update(visits, current, 1, &(&1 + 1))

    if :rand.uniform() < reset_prob do
      walk(conf, seed, seed, steps_left - 1, reset_prob, visits)
    else
      neighbors = SegmentManager.neighbors_out(conf, current)

      case neighbors do
        [] ->
          walk(conf, seed, seed, steps_left - 1, reset_prob, visits)

        neighbors ->
          {next, _type, _weight} = Enum.random(neighbors)
          walk(conf, seed, next, steps_left - 1, reset_prob, visits)
      end
    end
  end

  defp normalize_scores(sorted_counts) do
    total = Enum.reduce(sorted_counts, 0, fn {_id, count}, acc -> acc + count end)

    if total == 0 do
      []
    else
      Enum.map(sorted_counts, fn {id, count} -> {id, count / total} end)
    end
  end

  defp resolve_external_ids(results, conf) do
    Enum.map(results, fn {internal_id, score} ->
      external_id = IdMap.get_external(conf, internal_id)
      {external_id, score}
    end)
  end
end
