defmodule MeliGraph.LightGCN.Matrix do
  @moduledoc """
  Constrói a matriz de adjacência normalizada `Ã = D^(-1/2) · W · D^(-1/2)`
  para um grafo bipartido user↔item, no formato esperado pelo LightGCN.

  ## Estrutura de W

      W = [  0    R  ]    shape (M+N) × (M+N)
          [ R^T   0  ]

  onde M = número de usuários, N = número de itens, e R[u,i] é o peso
  agregado das interações entre o usuário u e o item i. Quando múltiplas
  arestas conectam o mesmo par (ex.: like + comentário), os pesos são
  somados — interpretação: cada interação positiva adiciona evidência
  ao sinal user↔item.

  ## Particionamento por user_prefix

  O lado "usuário" do grafo é identificado pelo prefixo dos external IDs.
  Exemplo: com `user_prefix: "profile:"`, todos os vértices `"profile:*"`
  são classificados como usuários e o restante como itens.

  ## Reindexação

  IDs internos do `IdMap` podem ter gaps (após pruning ou inserções
  intercaladas). Esta função reindexa todos os usuários para o intervalo
  `[0, M-1]` e todos os itens para `[M, M+N-1]` na matriz, mantendo um
  mapa `internal_id → row_index` para uso na inferência.

  ## Limites

  Materializa a matriz como tensor denso. Adequado para grafos
  com até ~50k vértices. Para grafos maiores, usar representação sparse
  (planejado para v0.3).
  """

  alias MeliGraph.Config
  alias MeliGraph.Graph.{IdMap, SegmentManager}

  @type index_map :: %{non_neg_integer() => non_neg_integer()}

  @type build_result :: %{
          adj_norm: Nx.Tensor.t(),
          user_index: index_map(),
          item_index: index_map(),
          positive_pairs: [{non_neg_integer(), non_neg_integer()}],
          user_count: non_neg_integer(),
          item_count: non_neg_integer(),
          node_count: non_neg_integer()
        }

  @doc """
  Constrói `Ã` para o grafo identificado por `conf` usando `user_prefix`
  para separar os dois lados do grafo bipartido.

  O resultado também inclui `positive_pairs`, a lista deduplicada de
  pares `(user_row, item_row)` representando interações observadas —
  usada pelo Trainer para amostrar mini-batches BPR.

  Retorna `{:error, :empty_graph}` quando não há usuários, itens ou
  arestas user↔item após o particionamento.
  """
  @spec build(Config.t(), String.t()) ::
          {:ok, build_result()} | {:error, :empty_graph}
  def build(%Config{} = conf, user_prefix) when is_binary(user_prefix) do
    {users, items} = partition_nodes(conf, user_prefix)

    user_count = map_size(users)
    item_count = map_size(items)

    cond do
      user_count == 0 or item_count == 0 ->
        {:error, :empty_graph}

      true ->
        case collect_weighted_pairs(conf, users, items) do
          [] ->
            {:error, :empty_graph}

          weighted_pairs ->
            adj = build_adjacency(weighted_pairs, user_count + item_count)
            adj_norm = normalize(adj)
            positive_pairs = Enum.map(weighted_pairs, fn {u, i, _w} -> {u, i} end)

            {:ok,
             %{
               adj_norm: adj_norm,
               user_index: users,
               item_index: items,
               positive_pairs: positive_pairs,
               user_count: user_count,
               item_count: item_count,
               node_count: user_count + item_count
             }}
        end
    end
  end

  # --- Private ---

  # Lê todos os vértices do IdMap e separa em users (prefixo bate) e items.
  # Retorna dois mapas: internal_id → row_index. Users ocupam [0, M),
  # items ocupam [M, M+N).
  defp partition_nodes(conf, user_prefix) do
    {user_pairs, item_pairs} =
      conf
      |> IdMap.all_ids()
      |> Enum.split_with(fn {_internal_id, external_id} ->
        is_binary(external_id) and String.starts_with?(external_id, user_prefix)
      end)

    user_count = length(user_pairs)

    users =
      user_pairs
      |> Enum.with_index()
      |> Map.new(fn {{internal_id, _ext}, row} -> {internal_id, row} end)

    items =
      item_pairs
      |> Enum.with_index()
      |> Map.new(fn {{internal_id, _ext}, idx} -> {internal_id, user_count + idx} end)

    {users, items}
  end

  # Lê todas as arestas LTR dos segmentos (rtl é redundante: cada aresta
  # lógica aparece uma única vez em ltr), filtra as que cruzam o
  # particionamento user↔item e soma pesos por par. Múltiplas interações no
  # mesmo par (like + comentário, etc.) acumulam — assim like (1.0) +
  # comentário (1.5) na mesma dupla vira `weight = 2.5`.
  defp collect_weighted_pairs(conf, users, items) do
    conf
    |> SegmentManager.all_segments()
    |> Enum.flat_map(fn segment -> :ets.tab2list(segment.ltr) end)
    |> Enum.reduce(%{}, fn {src, dst, _edge_type, weight}, acc ->
      cond do
        Map.has_key?(users, src) and Map.has_key?(items, dst) ->
          Map.update(acc, {users[src], items[dst]}, weight, &(&1 + weight))

        Map.has_key?(items, src) and Map.has_key?(users, dst) ->
          Map.update(acc, {users[dst], items[src]}, weight, &(&1 + weight))

        true ->
          acc
      end
    end)
    |> Enum.map(fn {{u, i}, w} -> {u, i, w} end)
  end

  # Constrói W como tensor denso `n × n` usando indexed_put.
  # Cada par positivo (u, i, w) gera duas entradas: W[u,i] = w e W[i,u] = w
  # (matriz bipartida simétrica e ponderada).
  defp build_adjacency(weighted_pairs, n) do
    indices =
      weighted_pairs
      |> Enum.flat_map(fn {u, i, _w} -> [[u, i], [i, u]] end)
      |> Nx.tensor(type: :s64)

    values =
      weighted_pairs
      |> Enum.flat_map(fn {_u, _i, w} -> [w, w] end)
      |> Nx.tensor(type: :f32)

    0.0
    |> Nx.broadcast({n, n})
    |> Nx.indexed_put(indices, values)
  end

  # Ã = D^(-1/2) · A · D^(-1/2)
  # Implementado elementwise: Ã[i,j] = A[i,j] · d_inv_sqrt[i] · d_inv_sqrt[j]
  defp normalize(adj) do
    degree = Nx.sum(adj, axes: [1])

    # Evita rsqrt(0) = +Inf zerando manualmente onde degree = 0.
    safe_degree = Nx.max(degree, 1.0)

    d_inv_sqrt =
      Nx.select(
        Nx.greater(degree, 0),
        Nx.rsqrt(safe_degree),
        0.0
      )

    norm_outer =
      Nx.multiply(
        Nx.new_axis(d_inv_sqrt, 1),
        Nx.new_axis(d_inv_sqrt, 0)
      )

    Nx.multiply(adj, norm_outer)
  end
end
