defmodule MeliGraph.Ingestion.Writer do
  @moduledoc """
  Single-writer GenServer para ingestão de arestas.

  Padrão GraphJet: um único processo de escrita evita race conditions
  no gerenciamento de segmentos. Leituras são feitas diretamente nas
  tabelas ETS (multi-reader).

  Padrão Oban: `trap_exit` + drain da mailbox no shutdown para não
  perder arestas durante graceful shutdown.

  No modo `:sync`, usa `call` em vez de `cast` para garantir que
  a inserção completou antes de retornar (essencial para testes).
  """

  use GenServer

  alias MeliGraph.Config
  alias MeliGraph.Graph.{IdMap, SegmentManager}
  alias MeliGraph.Telemetry

  # --- Client API ---

  def start_link(opts) do
    conf = Keyword.fetch!(opts, :conf)
    GenServer.start_link(__MODULE__, conf, name: MeliGraph.Registry.via(conf, :writer))
  end

  @doc """
  Insere uma aresta no grafo.

  No modo `:sync`, a chamada é síncrona (call).
  No modo `:disabled`, a chamada é assíncrona (cast).
  """
  @spec insert_edge(Config.t(), term(), term(), atom()) :: :ok
  def insert_edge(%Config{testing: :sync} = conf, source, target, edge_type) do
    GenServer.call(MeliGraph.Registry.via(conf, :writer), {:insert_edge, source, target, edge_type})
  end

  def insert_edge(conf, source, target, edge_type) do
    GenServer.cast(MeliGraph.Registry.via(conf, :writer), {:insert_edge, source, target, edge_type})
  end

  # --- Server callbacks ---

  @impl true
  def init(conf) do
    Process.flag(:trap_exit, true)
    {:ok, %{conf: conf}}
  end

  @impl true
  def handle_call({:insert_edge, source, target, edge_type}, _from, state) do
    result = do_insert(state.conf, source, target, edge_type)
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:insert_edge, source, target, edge_type}, state) do
    do_insert(state.conf, source, target, edge_type)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    drain_mailbox(state.conf)
    :ok
  end

  # --- Private ---

  defp do_insert(conf, source, target, edge_type) do
    Telemetry.span([:ingestion, :insert_edge], %{conf: conf}, fn ->
      source_id = IdMap.get_or_create(conf, source)
      target_id = IdMap.get_or_create(conf, target)
      result = SegmentManager.insert(conf, source_id, target_id, edge_type)
      {result, %{source: source, target: target, edge_type: edge_type}}
    end)
  end

  defp drain_mailbox(conf) do
    receive do
      {:"$gen_cast", {:insert_edge, source, target, edge_type}} ->
        do_insert(conf, source, target, edge_type)
        drain_mailbox(conf)
    after
      0 -> :ok
    end
  end
end
