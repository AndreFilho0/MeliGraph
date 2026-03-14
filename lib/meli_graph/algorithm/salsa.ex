defmodule MeliGraph.Algorithm.SALSA do
  @moduledoc """
  Algoritmo SALSA para grafos bipartidos.

  Baseado nos papers WTF (seção 5.2) e GraphJet (seção 5.1/5.2).
  Implementa a variante Subgraph SALSA: materializa um subgrafo bipartido
  pequeno e distribui pesos iterativamente entre hubs e authorities.

  ## Fluxo

  1. Computa Circle of Trust via PageRank (seed set)
  2. Constrói subgrafo bipartido: hubs (seed) ↔ authorities (vizinhos)
  3. Itera distribuição de pesos L→R e R→L
  4. Retorna authorities rankeadas por peso final

  ## Parâmetros (via opts)

    * `:seed_size` - tamanho do seed set do PageRank (padrão: 100)
    * `:iterations` - número de iterações SALSA (padrão: 5)
    * `:top_k` - resultados a retornar (padrão: 20)
  """

  @behaviour MeliGraph.Algorithm

  alias MeliGraph.Config
  alias MeliGraph.Graph.{IdMap, SegmentManager}
  alias MeliGraph.Algorithm.PageRank

  @default_seed_size 100
  @default_iterations 5
  @default_top_k 20

  @impl true
  def compute(%Config{} = conf, entity_id, type, opts) do
    seed_size = Keyword.get(opts, :seed_size, @default_seed_size)
    iterations = Keyword.get(opts, :iterations, @default_iterations)
    top_k = Keyword.get(opts, :top_k, @default_top_k)

    # 1. Computar circle of trust via PageRank
    pagerank_opts = [num_walks: 500, top_k: seed_size]

    with {:ok, cot} <- PageRank.compute(conf, entity_id, type, pagerank_opts) do
      seed_internal_ids =
        cot
        |> Enum.map(fn {ext_id, _score} -> IdMap.get_internal(conf, ext_id) end)
        |> Enum.reject(&is_nil/1)

      seed_set = MapSet.new(seed_internal_ids)

      # 2. Construir subgrafo bipartido
      {hub_edges, authority_set} = build_bipartite(conf, seed_set)

      if map_size(hub_edges) == 0 or MapSet.size(authority_set) == 0 do
        {:ok, []}
      else
        # 3. Iterar SALSA
        authority_scores = iterate_salsa(hub_edges, seed_set, authority_set, iterations)

        # 4. Rankear e retornar
        results =
          authority_scores
          |> Enum.reject(fn {id, _score} -> MapSet.member?(seed_set, id) end)
          |> Enum.sort_by(fn {_id, score} -> score end, :desc)
          |> Enum.take(top_k)
          |> Enum.map(fn {internal_id, score} ->
            {IdMap.get_external(conf, internal_id), score}
          end)

        {:ok, results}
      end
    end
  end

  # --- Private ---

  defp build_bipartite(conf, seed_set) do
    Enum.reduce(seed_set, {%{}, MapSet.new()}, fn hub_id, {edges, authorities} ->
      neighbors = SegmentManager.neighbors_out(conf, hub_id)
      targets = Enum.map(neighbors, fn {target, _type} -> target end)

      if targets == [] do
        {edges, authorities}
      else
        {
          Map.put(edges, hub_id, targets),
          Enum.reduce(targets, authorities, &MapSet.put(&2, &1))
        }
      end
    end)
  end

  defp iterate_salsa(hub_edges, seed_set, _authority_set, iterations) do
    # Pesos iniciais uniformes nos hubs
    hub_count = MapSet.size(seed_set)
    initial_weight = if hub_count > 0, do: 1.0 / hub_count, else: 0.0

    hub_weights =
      seed_set
      |> Enum.map(&{&1, initial_weight})
      |> Map.new()

    # Construir reverse index: authority → [hubs que apontam para ela]
    reverse_index = build_reverse_index(hub_edges)

    Enum.reduce(1..iterations, %{}, fn _iter, _authority_scores ->
      # L→R: distribuir peso dos hubs para authorities
      authority_scores =
        Enum.reduce(hub_edges, %{}, fn {hub_id, targets}, acc ->
          weight = Map.get(hub_weights, hub_id, 0.0)
          share = if length(targets) > 0, do: weight / length(targets), else: 0.0

          Enum.reduce(targets, acc, fn target, inner_acc ->
            Map.update(inner_acc, target, share, &(&1 + share))
          end)
        end)

      # R→L: distribuir peso das authorities de volta para hubs
      _hub_weights =
        Enum.reduce(reverse_index, %{}, fn {authority_id, hubs}, acc ->
          weight = Map.get(authority_scores, authority_id, 0.0)
          share = if length(hubs) > 0, do: weight / length(hubs), else: 0.0

          Enum.reduce(hubs, acc, fn hub, inner_acc ->
            Map.update(inner_acc, hub, share, &(&1 + share))
          end)
        end)

      authority_scores
    end)
  end

  defp build_reverse_index(hub_edges) do
    Enum.reduce(hub_edges, %{}, fn {hub_id, targets}, acc ->
      Enum.reduce(targets, acc, fn target, inner_acc ->
        Map.update(inner_acc, target, [hub_id], &[hub_id | &1])
      end)
    end)
  end
end
