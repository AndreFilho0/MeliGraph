defmodule MeliGraph.Reconciler do
  @moduledoc """
  Rede de segurança do failover no modo `:horde` (v0.3).

  **Por que existe.** O failover automático do Horde sofre de uma **corrida** sob
  queda abrupta do nó dono: o `Horde.NodeListener` (`members: :auto`) reage ao
  `:nodedown` removendo o membro morto do CRDT *sem* realocar seus processos,
  enquanto o caminho via monitor (`{:DOWN}` → marca o membro `:dead`) é o único
  que dispara o `handoff_processes`. Quando o NodeListener ganha a corrida, o
  grafo órfão **nunca** é reiniciado e fica perdido até intervenção manual
  (observado ~50-60% das vezes). Veja `docs/distribution.md`.

  **O que este processo faz.** Roda em **cada nó** (é o que o app adiciona à
  árvore via `{MeliGraph, distribution: :horde, ...}`). A cada `reconcile_interval`
  ele pergunta ao `Horde.Registry` "existe um dono vivo para este grafo?"
  (`lookup_owner/1`, leitura local do CRDT, ~µs). Se sim, não faz nada. Se o grafo
  está sem dono por mais de `reconcile_grace`, re-chama `MeliGraph.Distributed.ensure_started/1`,
  que pede ao Horde para colocar uma árvore **nova e vazia** num nó vivo; o
  `Bootstrapper` dessa árvore roda o `on_ready` e repovoa a ETS a partir da fonte
  da verdade (Postgres). **O grafo nunca é transferido entre nós** — é
  reconstruído.

  **Por que o guard é `lookup_owner` e não a idempotência por id.** O handoff do
  Horde reinicia com `randomize_child_id`, então após uma recuperação dirigida
  pelo Horde o id do filho deixa de ser o nosso `{MeliGraph.Supervisor, name}`
  estável — `start_child` não o veria como já-iniciado e subiria uma 2ª árvore
  (dupla-carga → bug de soma de pesos da v0.2.x). O `ConfigHolder` registra sob o
  `conf.name` **estável** no `HordeRegistry`, então `lookup_owner` enxerga
  qualquer árvore viva (id estável OU randomizado) e nos mantém fora do caminho
  quando o Horde já recuperou. O `reconcile_grace` (> recuperação normal do Horde)
  fecha a janela de sobreposição.
  """

  use GenServer

  require Logger

  alias MeliGraph.{Config, Distributed}

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :name)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  def start_link(opts) do
    conf = Config.new(opts)
    GenServer.start_link(__MODULE__, conf)
  end

  @impl true
  def init(%Config{} = conf) do
    state = %{
      conf: conf,
      interval: conf.reconcile_interval,
      grace: conf.reconcile_grace,
      missing_since: nil
    }

    # Aloca no boot via handle_continue (roda logo após o init retornar, sem
    # bloquear o supervisor do app), depois entra no loop de polling.
    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    assert_started(state.conf)
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    new_state =
      case Distributed.lookup_owner(state.conf.name) do
        {:ok, _pid, _conf} -> %{state | missing_since: nil}
        :error -> handle_missing(state)
      end

    schedule(new_state.interval)
    {:noreply, new_state}
  end

  # Primeira observação de ausência: marca o instante e espera o grace.
  defp handle_missing(%{missing_since: nil} = state) do
    %{state | missing_since: now()}
  end

  # Ausência persistente: passou do grace → re-dispara a alocação. O guard por
  # `lookup_owner` acima garante que só chegamos aqui se NÃO há dono registrado,
  # então não há dupla-alocação com uma recuperação do próprio Horde.
  defp handle_missing(%{missing_since: since, grace: grace, conf: conf} = state) do
    if now() - since >= grace do
      Logger.warning(
        "MeliGraph: graph #{inspect(conf.name)} has no owner for >#{grace}ms — " <>
          "re-asserting allocation (failover safety net)"
      )

      :telemetry.execute(
        [:meli_graph, :reconciler, :reassert],
        %{missing_ms: now() - since},
        %{name: conf.name, node: node()}
      )

      assert_started(conf)
      # Zera o relógio: dá tempo da nova árvore subir e propagar antes de
      # reavaliar (evita re-disparos em rajada enquanto o boot acontece).
      %{state | missing_since: nil}
    else
      state
    end
  end

  defp assert_started(%Config{} = conf) do
    case Distributed.ensure_started(conf) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "MeliGraph: ensure_started for #{inspect(conf.name)} failed: #{inspect(reason)} " <>
            "(will retry on next reconcile tick)"
        )

        :error
    end
  end

  defp schedule(interval), do: Process.send_after(self(), :tick, interval)

  defp now, do: System.monotonic_time(:millisecond)
end
