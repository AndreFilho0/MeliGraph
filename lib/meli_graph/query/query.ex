defmodule MeliGraph.Query do
  @moduledoc """
  Query layer — ponto de entrada para consultas de recomendação.

  Respeita o modo de testing:
    * `:disabled` — cache-first, computa em background se miss
    * `:sync` — computa inline, sem cache, sem processos async
  """

  alias MeliGraph.Config
  alias MeliGraph.Graph.IdMap
  alias MeliGraph.Store.ETS, as: Store
  alias MeliGraph.Telemetry

  @doc """
  Retorna top-N recomendações para um vértice.
  """
  @spec recommend(Config.t(), term(), atom(), keyword()) ::
          {:ok, [{term(), float()}]} | {:error, term()}
  def recommend(conf, external_id, type, opts \\ []) do
    Telemetry.span([:query, :recommend], %{conf: conf, entity_id: external_id}, fn ->
      result = do_recommend(conf, external_id, type, opts)
      {result, %{type: type}}
    end)
  end

  # --- Private ---

  defp do_recommend(%Config{testing: :sync} = conf, external_id, type, opts) do
    compute_inline(conf, external_id, type, opts)
  end

  defp do_recommend(conf, external_id, type, opts) do
    cache_key = {:recommend, external_id, type, opts[:algorithm]}

    case Store.get(conf, cache_key) do
      {:ok, cached} ->
        {:ok, cached}

      :miss ->
        case compute_inline(conf, external_id, type, opts) do
          {:ok, results} = ok ->
            Store.put(conf, cache_key, results, conf.result_ttl)
            ok

          error ->
            error
        end
    end
  end

  defp compute_inline(conf, external_id, type, opts) do
    algorithm = resolve_algorithm(Keyword.get(opts, :algorithm, :pagerank))

    if global_algorithm?(algorithm) do
      algorithm.compute(conf, 0, type, opts)
    else
      case IdMap.get_internal(conf, external_id) do
        nil ->
          {:ok, []}

        internal_id ->
          algorithm.compute(conf, internal_id, type, opts)
      end
    end
  end

  defp global_algorithm?(MeliGraph.Algorithm.GlobalRank), do: true
  defp global_algorithm?(_), do: false

  defp resolve_algorithm(:pagerank), do: MeliGraph.Algorithm.PageRank
  defp resolve_algorithm(:salsa), do: MeliGraph.Algorithm.SALSA
  defp resolve_algorithm(:similar_items), do: MeliGraph.Algorithm.SimilarItems
  defp resolve_algorithm(:global_rank), do: MeliGraph.Algorithm.GlobalRank

  defp resolve_algorithm(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :compute, 4) do
      module
    else
      raise ArgumentError, "Unknown algorithm: #{inspect(module)}"
    end
  end
end
