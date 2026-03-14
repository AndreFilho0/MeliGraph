defmodule MeliGraph.Graph.SegmentManager do
  @moduledoc """
  GenServer que gerencia os segmentos temporais do grafo.

  Responsável por:
    * Manter o segmento ativo (escrita)
    * Rotacionar segmentos quando o ativo atinge capacidade máxima
    * Fornecer acesso de leitura a todos os segmentos
    * Remover segmentos expirados (chamado pelo Pruner)
  """

  use GenServer

  alias MeliGraph.Config
  alias MeliGraph.Graph.Segment
  alias MeliGraph.Telemetry

  @type state :: %{
          conf: Config.t(),
          active: Segment.t(),
          frozen: [Segment.t()],
          next_id: non_neg_integer()
        }

  # --- Client API ---

  def start_link(opts) do
    conf = Keyword.fetch!(opts, :conf)
    GenServer.start_link(__MODULE__, conf, name: MeliGraph.Registry.via(conf, :segment_manager))
  end

  @doc """
  Insere uma aresta no segmento ativo. Se o segmento está cheio,
  rotaciona automaticamente e insere no novo segmento.
  """
  @spec insert(Config.t(), non_neg_integer(), non_neg_integer(), atom()) :: :ok
  def insert(conf, source, target, edge_type) do
    GenServer.call(MeliGraph.Registry.via(conf, :segment_manager), {:insert, source, target, edge_type})
  end

  @doc """
  Retorna todos os vizinhos de saída de um vértice, agregando todos os segmentos.
  Operação de leitura direta nas ETS (sem passar pelo GenServer).
  """
  @spec neighbors_out(Config.t(), non_neg_integer()) :: [{non_neg_integer(), atom()}]
  def neighbors_out(conf, source) do
    segments = all_segments(conf)
    Enum.flat_map(segments, &Segment.neighbors_out(&1, source))
  end

  @doc """
  Retorna todos os vizinhos de entrada de um vértice, agregando todos os segmentos.
  """
  @spec neighbors_in(Config.t(), non_neg_integer()) :: [{non_neg_integer(), atom()}]
  def neighbors_in(conf, target) do
    segments = all_segments(conf)
    Enum.flat_map(segments, &Segment.neighbors_in(&1, target))
  end

  @doc """
  Retorna vizinhos de saída filtrados por tipo de aresta.
  """
  @spec neighbors_out(Config.t(), non_neg_integer(), atom()) :: [non_neg_integer()]
  def neighbors_out(conf, source, edge_type) do
    segments = all_segments(conf)
    Enum.flat_map(segments, &Segment.neighbors_out(&1, source, edge_type))
  end

  @doc """
  Retorna vizinhos de entrada filtrados por tipo de aresta.
  """
  @spec neighbors_in(Config.t(), non_neg_integer(), atom()) :: [non_neg_integer()]
  def neighbors_in(conf, target, edge_type) do
    segments = all_segments(conf)
    Enum.flat_map(segments, &Segment.neighbors_in(&1, target, edge_type))
  end

  @doc """
  Retorna lista de todos os segmentos (ativo + congelados).
  Leitura direta via ETS (sem GenServer).
  """
  @spec all_segments(Config.t()) :: [Segment.t()]
  def all_segments(conf) do
    GenServer.call(MeliGraph.Registry.via(conf, :segment_manager), :all_segments)
  end

  @doc """
  Retorna o número total de arestas em todos os segmentos.
  """
  @spec total_edge_count(Config.t()) :: non_neg_integer()
  def total_edge_count(conf) do
    all_segments(conf)
    |> Enum.reduce(0, fn seg, acc -> acc + Segment.edge_count(seg) end)
  end

  @doc """
  Remove segmentos criados antes de `cutoff_time` (monotonic ms).
  Chamado pelo plugin Pruner.
  """
  @spec prune(Config.t(), integer()) :: {:ok, non_neg_integer()}
  def prune(conf, cutoff_time) do
    GenServer.call(MeliGraph.Registry.via(conf, :segment_manager), {:prune, cutoff_time})
  end

  # --- Server callbacks ---

  @impl true
  def init(conf) do
    segment = Segment.new(0, conf.segment_max_edges)

    state = %{
      conf: conf,
      active: segment,
      frozen: [],
      next_id: 1
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:insert, source, target, edge_type}, _from, state) do
    case Segment.insert(state.active, source, target, edge_type) do
      {:ok, updated_segment} ->
        {:reply, :ok, %{state | active: updated_segment}}

      :full ->
        new_state = rotate_segment(state)

        case Segment.insert(new_state.active, source, target, edge_type) do
          {:ok, updated_segment} ->
            {:reply, :ok, %{new_state | active: updated_segment}}
        end
    end
  end

  def handle_call(:all_segments, _from, state) do
    {:reply, [state.active | state.frozen], state}
  end

  def handle_call({:prune, cutoff_time}, _from, state) do
    {to_prune, to_keep} = Enum.split_with(state.frozen, fn seg -> seg.created_at < cutoff_time end)

    Enum.each(to_prune, &Segment.destroy/1)

    {:reply, {:ok, length(to_prune)}, %{state | frozen: to_keep}}
  end

  # --- Private ---

  defp rotate_segment(state) do
    Telemetry.span([:graph, :create_segment], %{conf: state.conf}, fn ->
      new_segment = Segment.new(state.next_id, state.conf.segment_max_edges)

      new_state = %{
        state
        | active: new_segment,
          frozen: [state.active | state.frozen],
          next_id: state.next_id + 1
      }

      {new_state, %{segment_id: state.next_id}}
    end)
  end
end
