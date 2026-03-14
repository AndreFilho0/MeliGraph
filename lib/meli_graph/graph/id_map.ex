defmodule MeliGraph.Graph.IdMap do
  @moduledoc """
  Mapeamento bidirecional entre IDs externos (qualquer termo) e IDs internos
  (inteiros compactos). Usa uma tabela ETS global por instância para manter
  consistência cross-segment.

  ## Design

  Duas tabelas ETS:
    * `forward` — external_id → internal_id
    * `reverse` — internal_id → external_id

  Um counter atômico mantém o próximo ID interno disponível.
  """

  use GenServer

  alias MeliGraph.Config

  @type t :: %__MODULE__{
          forward: :ets.tid(),
          reverse: :ets.tid(),
          counter: :atomics.atomics_ref()
        }

  defstruct [:forward, :reverse, :counter]

  # --- Client API ---

  def start_link(opts) do
    conf = Keyword.fetch!(opts, :conf)
    GenServer.start_link(__MODULE__, conf, name: MeliGraph.Registry.via(conf, :id_map))
  end

  @doc """
  Retorna o ID interno para um ID externo, criando um novo mapeamento se necessário.
  """
  @spec get_or_create(Config.t(), term()) :: non_neg_integer()
  def get_or_create(conf, external_id) do
    GenServer.call(MeliGraph.Registry.via(conf, :id_map), {:get_or_create, external_id})
  end

  @doc """
  Retorna o ID interno para um ID externo, ou `nil` se não existe.
  """
  @spec get_internal(Config.t(), term()) :: non_neg_integer() | nil
  def get_internal(conf, external_id) do
    case :ets.lookup(table_name(conf, :forward), external_id) do
      [{^external_id, internal_id}] -> internal_id
      [] -> nil
    end
  end

  @doc """
  Retorna o ID externo para um ID interno, ou `nil` se não existe.
  """
  @spec get_external(Config.t(), non_neg_integer()) :: term() | nil
  def get_external(conf, internal_id) do
    case :ets.lookup(table_name(conf, :reverse), internal_id) do
      [{^internal_id, external_id}] -> external_id
      [] -> nil
    end
  end

  @doc """
  Retorna o número total de IDs mapeados.
  """
  @spec size(Config.t()) :: non_neg_integer()
  def size(conf) do
    :ets.info(table_name(conf, :forward), :size)
  end

  @doc """
  Retorna todos os pares `{internal_id, external_id}` mapeados.
  Usado pelo GlobalRank para iterar sobre todos os vértices do grafo.
  """
  @spec all_ids(Config.t()) :: [{non_neg_integer(), term()}]
  def all_ids(conf) do
    :ets.tab2list(table_name(conf, :reverse))
  end

  # --- Server callbacks ---

  @impl true
  def init(conf) do
    forward = :ets.new(table_name(conf, :forward), [:set, :named_table, :public, read_concurrency: true])
    reverse = :ets.new(table_name(conf, :reverse), [:set, :named_table, :public, read_concurrency: true])
    counter = :atomics.new(1, signed: false)

    state = %__MODULE__{forward: forward, reverse: reverse, counter: counter}
    {:ok, {conf, state}}
  end

  @impl true
  def handle_call({:get_or_create, external_id}, _from, {conf, state} = full_state) do
    case :ets.lookup(state.forward, external_id) do
      [{^external_id, internal_id}] ->
        {:reply, internal_id, full_state}

      [] ->
        internal_id = :atomics.add_get(state.counter, 1, 1) - 1
        :ets.insert(state.forward, {external_id, internal_id})
        :ets.insert(state.reverse, {internal_id, external_id})
        {:reply, internal_id, {conf, state}}
    end
  end

  defp table_name(%Config{name: name}, direction) do
    Module.concat([name, IdMap, direction])
  end
end
