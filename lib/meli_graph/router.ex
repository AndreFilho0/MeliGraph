defmodule MeliGraph.Router do
  @moduledoc """
  Roteamento transparente entre o nó local e o nó dono de um grafo (v0.3).

  Stateless. Duas responsabilidades:

    * **Resolver a rota** de cada operação: se o `conf` está no `Registry` local
      (modo `:local` **ou** este nó é o dono em `:horde`) → *fast path* (chamada
      direta contra a ETS local, multi-reader, zero Horde/`:erpc`). Caso
      contrário → `:erpc.call` para o nó dono.
    * **Executar a operação no dono** (`run_local/3`): roda o **mesmo código de
      hoje** (`Query`, `Writer`, `SegmentManager`, ...) contra a ETS local. O que
      cruza a rede é **comando + resultado**, nunca acesso ao dado.

  Por que `:erpc.call` e não um `GenServer.call` central: rotear leitura por um
  único processo serializaria as leituras (mata o multi-reader). O `:erpc.call`
  roda a função num processo **novo** no dono → ETS concorrente preservada.
  """

  require Logger

  alias MeliGraph.Graph.{IdMap, SegmentManager}
  alias MeliGraph.Ingestion.Writer
  alias MeliGraph.LightGCN.{EmbeddingStore, Trainer}
  alias MeliGraph.Query
  alias MeliGraph.Telemetry

  # Backoff do lookup de descoberta — cobre a janela de consistência eventual do
  # Horde.Registry (delta_crdt ainda não propagou). Soma < ~1s.
  @lookup_backoffs [25, 50, 100, 200, 400]

  @type route :: {:local, MeliGraph.Config.t()} | {:remote, node(), MeliGraph.Config.t()}

  # --- API de roteamento ---

  @doc """
  Roteia uma leitura. Local → direto; remoto → `:erpc.call` no dono.
  Propaga `{:error, :graph_unavailable | :graph_timeout}` no caminho remoto.
  """
  @spec route_read(atom(), atom(), [term()]) :: term()
  def route_read(name, op, args) do
    case resolve_route(name) do
      {:local, conf} -> apply_op(conf, op, args)
      {:remote, owner, conf} -> remote_call(owner, name, op, args, timeout_for(op, conf))
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Roteia uma escrita. Política por op:

    * `insert_edge` remoto em `testing: :disabled` → `:erpc.cast` (fire-and-forget,
      espelha o `GenServer.cast` local); em `:sync` → `:erpc.call`. Grafo
      indisponível → **dropa com warning** (a fonte da verdade é o Postgres +
      `on_ready`, que faz replay).
    * demais escritas → `:erpc.call`.
  """
  @spec route_write(atom(), atom(), [term()]) :: term()
  def route_write(name, :insert_edge = op, args) do
    case resolve_route(name) do
      {:local, conf} ->
        apply_op(conf, op, args)

      {:remote, owner, %{testing: :sync} = conf} ->
        remote_call(owner, name, op, args, conf.cluster_call_timeout)

      {:remote, owner, _conf} ->
        :erpc.cast(owner, __MODULE__, :run_local, [name, op, args])
        :ok

      {:error, :graph_unavailable} ->
        Logger.warning(
          "MeliGraph: dropping insert_edge for #{inspect(name)} — graph unavailable " <>
            "(will be replayed via on_ready)"
        )

        :ok
    end
  end

  def route_write(name, op, args) do
    case resolve_route(name) do
      {:local, conf} -> apply_op(conf, op, args)
      {:remote, owner, conf} -> remote_call(owner, name, op, args, conf.cluster_call_timeout)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resolve a rota de um grafo: `{:local, conf}`, `{:remote, owner_node, conf}` ou
  `{:error, :graph_unavailable}`.

  Em contexto **não-distribuído** (sem cluster), um grafo ausente localmente
  levanta `ArgumentError` — paridade exata com o single-node de hoje.
  """
  @spec resolve_route(atom()) :: route() | {:error, :graph_unavailable}
  def resolve_route(name) do
    case local_conf(name) do
      {:ok, conf} ->
        {:local, conf}

      :error ->
        if MeliGraph.Distributed.distributed_context?() do
          resolve_remote(name)
        else
          raise ArgumentError,
                "MeliGraph instance #{inspect(name)} not found. " <>
                  "Did you start it with MeliGraph.start_link(name: #{inspect(name)}, ...)?"
        end
    end
  end

  # --- Execução no nó dono ---

  @doc """
  Executa a operação **no nó dono**, contra a ETS local. Invocada via `:erpc`.
  É o mesmo código de hoje; só muda *onde* roda.
  """
  @spec run_local(atom(), atom(), [term()]) :: term()
  def run_local(name, op, args) do
    conf = MeliGraph.Supervisor.get_conf(name)
    apply_op(conf, op, args)
  end

  @doc """
  Corpo de `neighbors/4` extraído (rodava inline na API pública). Roda inteiro no
  dono porque encadeia vários acessos à ETB (`IdMap` + `SegmentManager`).
  """
  @spec do_neighbors(MeliGraph.Config.t(), term(), :outgoing | :incoming, keyword()) :: [term()]
  def do_neighbors(conf, entity_id, direction, opts) do
    case IdMap.get_internal(conf, entity_id) do
      nil ->
        []

      internal_id ->
        edge_type = Keyword.get(opts, :type)

        internal_neighbors =
          case {direction, edge_type} do
            {:outgoing, nil} ->
              SegmentManager.neighbors_out(conf, internal_id)
              |> Enum.map(fn {id, _type, _weight} -> id end)

            {:incoming, nil} ->
              SegmentManager.neighbors_in(conf, internal_id)
              |> Enum.map(fn {id, _type, _weight} -> id end)

            {:outgoing, type} ->
              SegmentManager.neighbors_out(conf, internal_id, type)

            {:incoming, type} ->
              SegmentManager.neighbors_in(conf, internal_id, type)
          end

        internal_neighbors
        |> Enum.uniq()
        |> Enum.map(&IdMap.get_external(conf, &1))
    end
  end

  # --- Despacho op → função (mesmo código de hoje) ---

  defp apply_op(conf, :recommend, [entity_id, type, opts]),
    do: Query.recommend(conf, entity_id, type, opts)

  defp apply_op(conf, :insert_edge, [source, target, edge_type, weight]),
    do: Writer.insert_edge(conf, source, target, edge_type, weight)

  defp apply_op(conf, :neighbors, [entity_id, direction, opts]),
    do: do_neighbors(conf, entity_id, direction, opts)

  defp apply_op(conf, :edge_count, []), do: SegmentManager.total_edge_count(conf)
  defp apply_op(conf, :vertex_count, []), do: IdMap.size(conf)

  defp apply_op(conf, :train_embeddings, [user_prefix, opts]),
    do: Trainer.train(conf, user_prefix, opts)

  defp apply_op(conf, :load_embeddings, [binary]), do: EmbeddingStore.load(conf, binary)
  defp apply_op(conf, :embeddings_ready?, []), do: EmbeddingStore.ready?(conf)
  defp apply_op(conf, :ready?, []), do: MeliGraph.Bootstrapper.ready?(conf)

  # --- Resolução de rota ---

  defp local_conf(name) do
    registry = Module.concat(name, Registry)

    case Registry.lookup(registry, :conf) do
      [{_pid, conf}] -> {:ok, conf}
      [] -> :error
    end
  rescue
    # Registry da instância não existe neste nó (não é o dono em :horde).
    ArgumentError -> :error
  end

  defp resolve_remote(name) do
    case lookup_owner_with_retry(name, @lookup_backoffs) do
      {:ok, pid, conf} -> {:remote, node(pid), conf}
      :error -> {:error, :graph_unavailable}
    end
  end

  defp lookup_owner_with_retry(name, []), do: MeliGraph.Distributed.lookup_owner(name)

  defp lookup_owner_with_retry(name, [wait | rest]) do
    case MeliGraph.Distributed.lookup_owner(name) do
      {:ok, _pid, _conf} = ok -> ok
      :error -> Process.sleep(wait) && lookup_owner_with_retry(name, rest)
    end
  end

  # --- Chamada remota (:erpc com tratamento de erro) ---

  defp timeout_for(:train_embeddings, _conf), do: :infinity
  defp timeout_for(_op, conf), do: conf.cluster_call_timeout

  # `:erpc.call/5` LEVANTA (não retorna {:error,_}). Capturamos tudo e nunca
  # deixamos exceção vazar. `:timeout` → erro específico; falhas de conexão /
  # dono stale → re-resolve o dono e tenta 1× (failover acabou de migrar).
  defp remote_call(owner, name, op, args, timeout, retried? \\ false) do
    Telemetry.span([:router, :remote_call], %{name: name, op: op, node: owner}, fn ->
      result =
        try do
          :erpc.call(owner, __MODULE__, :run_local, [name, op, args], timeout)
        catch
          :error, {:erpc, :timeout} ->
            {:error, :graph_timeout}

          kind, reason ->
            retry_or_unavailable(name, op, args, timeout, retried?, {kind, reason})
        end

      {result, %{op: op}}
    end)
  end

  defp retry_or_unavailable(_name, _op, _args, _timeout, true, _err),
    do: {:error, :graph_unavailable}

  defp retry_or_unavailable(name, op, args, timeout, false, _err) do
    case resolve_remote(name) do
      {:remote, owner, _conf} -> remote_call(owner, name, op, args, timeout, true)
      {:error, _} = err -> err
    end
  end
end
