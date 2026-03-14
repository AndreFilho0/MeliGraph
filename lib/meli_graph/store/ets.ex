defmodule MeliGraph.Store.ETS do
  @moduledoc """
  Implementação do Store behaviour usando ETS com TTL.

  Cada entrada é armazenada como `{key, value, expires_at}`.
  Entradas expiradas são ignoradas na leitura e removidas pelo CacheCleaner.
  """

  use GenServer

  @behaviour MeliGraph.Store

  alias MeliGraph.Config

  # --- Client API ---

  def start_link(opts) do
    conf = Keyword.fetch!(opts, :conf)
    GenServer.start_link(__MODULE__, conf, name: MeliGraph.Registry.via(conf, :store))
  end

  @impl MeliGraph.Store
  def get(conf, key) do
    table = table_name(conf)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(table, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        {:ok, value}

      [{^key, _value, _expired}] ->
        :ets.delete(table, key)
        :miss

      [] ->
        :miss
    end
  end

  @impl MeliGraph.Store
  def put(conf, key, value, ttl) do
    table = table_name(conf)
    expires_at = System.monotonic_time(:millisecond) + ttl
    :ets.insert(table, {key, value, expires_at})
    :ok
  end

  @impl MeliGraph.Store
  def delete(conf, key) do
    :ets.delete(table_name(conf), key)
    :ok
  end

  @impl MeliGraph.Store
  def clear(conf) do
    :ets.delete_all_objects(table_name(conf))
    :ok
  end

  @doc """
  Remove todas as entradas expiradas. Chamado pelo plugin CacheCleaner.
  """
  @spec clean_expired(Config.t()) :: non_neg_integer()
  def clean_expired(conf) do
    table = table_name(conf)
    now = System.monotonic_time(:millisecond)

    # Match spec: select keys where expires_at <= now
    match_spec = [{{:"$1", :_, :"$2"}, [{:"=<", :"$2", now}], [:"$1"]}]
    expired_keys = :ets.select(table, match_spec)

    Enum.each(expired_keys, &:ets.delete(table, &1))
    length(expired_keys)
  end

  # --- Server callbacks ---

  @impl true
  def init(conf) do
    table = :ets.new(table_name(conf), [:set, :named_table, :public, read_concurrency: true])
    {:ok, %{conf: conf, table: table}}
  end

  # --- Private ---

  defp table_name(%Config{name: name}) do
    Module.concat(name, Store)
  end
end
