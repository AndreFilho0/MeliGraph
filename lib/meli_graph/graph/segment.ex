defmodule MeliGraph.Graph.Segment do
  @moduledoc """
  Um segmento temporal do grafo, inspirado no GraphJet.

  Cada segmento contém um subconjunto de arestas inseridas em um intervalo
  de tempo. Quando o segmento atinge `max_edges`, um novo é criado.
  Segmentos antigos são read-only e podem ser removidos pelo Pruner.

  ## Armazenamento

  Usa ETS com tipo `:bag` para listas de adjacência, evitando cópia
  de listas grandes. Duas tabelas por segmento:

    * `ltr` (left-to-right) — source → {target, edge_type}
    * `rtl` (right-to-left) — target → {source, edge_type}
  """

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          created_at: integer(),
          edge_count: non_neg_integer(),
          max_edges: pos_integer(),
          ltr: :ets.tid(),
          rtl: :ets.tid()
        }

  @enforce_keys [:id, :max_edges]
  defstruct [
    :id,
    :ltr,
    :rtl,
    created_at: 0,
    edge_count: 0,
    max_edges: 1_000_000
  ]

  @doc """
  Cria um novo segmento com tabelas ETS.
  """
  @spec new(non_neg_integer(), pos_integer()) :: t()
  def new(id, max_edges) do
    ltr = :ets.new(:ltr, [:bag, :public, read_concurrency: true])
    rtl = :ets.new(:rtl, [:bag, :public, read_concurrency: true])

    %__MODULE__{
      id: id,
      max_edges: max_edges,
      created_at: System.monotonic_time(:millisecond),
      ltr: ltr,
      rtl: rtl
    }
  end

  @doc """
  Insere uma aresta no segmento. Retorna `{:ok, segment}` se sucesso
  ou `:full` se o segmento atingiu a capacidade máxima.
  """
  @spec insert(t(), non_neg_integer(), non_neg_integer(), atom()) :: {:ok, t()} | :full
  def insert(%{edge_count: count, max_edges: max}, _source, _target, _type)
      when count >= max do
    :full
  end

  def insert(%{ltr: ltr, rtl: rtl, edge_count: count} = segment, source, target, edge_type) do
    :ets.insert(ltr, {source, target, edge_type})
    :ets.insert(rtl, {target, source, edge_type})
    {:ok, %{segment | edge_count: count + 1}}
  end

  @doc """
  Retorna os vizinhos de saída (outgoing) de um vértice neste segmento.
  """
  @spec neighbors_out(t(), non_neg_integer()) :: [{non_neg_integer(), atom()}]
  def neighbors_out(%{ltr: ltr}, source) do
    :ets.lookup(ltr, source)
    |> Enum.map(fn {_source, target, type} -> {target, type} end)
  end

  @doc """
  Retorna os vizinhos de entrada (incoming) de um vértice neste segmento.
  """
  @spec neighbors_in(t(), non_neg_integer()) :: [{non_neg_integer(), atom()}]
  def neighbors_in(%{rtl: rtl}, target) do
    :ets.lookup(rtl, target)
    |> Enum.map(fn {_target, source, type} -> {source, type} end)
  end

  @doc """
  Retorna os vizinhos de saída filtrados por tipo de aresta.
  """
  @spec neighbors_out(t(), non_neg_integer(), atom()) :: [non_neg_integer()]
  def neighbors_out(%{ltr: ltr}, source, edge_type) do
    :ets.match(ltr, {source, :"$1", edge_type})
    |> List.flatten()
  end

  @doc """
  Retorna os vizinhos de entrada filtrados por tipo de aresta.
  """
  @spec neighbors_in(t(), non_neg_integer(), atom()) :: [non_neg_integer()]
  def neighbors_in(%{rtl: rtl}, target, edge_type) do
    :ets.match(rtl, {target, :"$1", edge_type})
    |> List.flatten()
  end

  @doc """
  Número de arestas no segmento.
  """
  @spec edge_count(t()) :: non_neg_integer()
  def edge_count(%{edge_count: count}), do: count

  @doc """
  Verifica se o segmento está cheio.
  """
  @spec full?(t()) :: boolean()
  def full?(%{edge_count: count, max_edges: max}), do: count >= max

  @doc """
  Destrói as tabelas ETS do segmento, liberando memória.
  """
  @spec destroy(t()) :: :ok
  def destroy(%{ltr: ltr, rtl: rtl}) do
    :ets.delete(ltr)
    :ets.delete(rtl)
    :ok
  end
end
