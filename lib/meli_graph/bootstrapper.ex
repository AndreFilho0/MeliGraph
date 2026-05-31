defmodule MeliGraph.Bootstrapper do
  @moduledoc """
  Reconstrói o grafo no boot (e, no modo `:horde`, em cada realocação) via a MFA
  `on_ready` do `Config`, e expõe o estado de prontidão (`ready?/1`).

  **Por que existe:** a lib não conhece a fonte da verdade (Postgres, etc.). O
  `on_ready: {mod, fun, args}` é o gancho que o app fornece para repovoar a ETS.
  Como em `:horde` a árvore da instância só existe no **nó dono** e é recriada no
  failover, o Bootstrapper roda **só no dono**, no boot e a cada realocação — a
  ETS está sempre fresca (vazia) nesse momento, então o replay é correto. Em
  `:local` roda 1× no boot, dando paridade dev/single-node.

  **Não-bloqueante:** `init/1` apenas agenda `:run` e retorna na hora. Um load
  lento de Postgres não pode segurar o `init` — em `:horde` isso estouraria o
  timeout do `start_child` do `Horde.DynamicSupervisor` e o Horde acharia que a
  árvore não subiu.

  **Falha de rebuild:** a MFA roda numa `Task` linkada. Se ela levanta, o
  Bootstrapper cai junto (não fazemos `trap_exit`); como é o **último** filho de
  um supervisor `:rest_for_one`, restarts repetidos escalam para o restart da
  árvore inteira (ETS volta vazia) → retry limpo. Contrato do loader: **assuma
  grafo vazio** (o `insert_edge` da v0.2.x soma pesos no re-insert, então não é
  idempotente sobre ETS já populada).
  """

  use GenServer

  alias MeliGraph.Config

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient
    }
  end

  def start_link(opts) do
    conf = Keyword.fetch!(opts, :conf)
    GenServer.start_link(__MODULE__, conf, name: MeliGraph.Registry.via(conf, :bootstrapper))
  end

  @doc """
  `true` quando a MFA `on_ready` terminou (ou quando `on_ready` é `nil`).
  """
  @spec ready?(Config.t()) :: boolean()
  def ready?(%Config{} = conf) do
    GenServer.call(MeliGraph.Registry.via(conf, :bootstrapper), :ready?)
  end

  @impl true
  def init(%Config{} = conf) do
    send(self(), :run)
    {:ok, %{conf: conf, ready?: is_nil(conf.on_ready), task: nil}}
  end

  @impl true
  def handle_info(:run, %{conf: %Config{on_ready: nil}} = state) do
    emit_ready(state.conf)
    {:noreply, %{state | ready?: true}}
  end

  def handle_info(:run, %{conf: %Config{on_ready: {m, f, a}}} = state) do
    task = Task.async(fn -> apply(m, f, a) end)
    {:noreply, %{state | task: task}}
  end

  # Task concluída com sucesso → instância pronta.
  def handle_info({ref, _result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    emit_ready(state.conf)
    {:noreply, %{state | ready?: true, task: nil}}
  end

  # Falha da Task chega via link (não trapamos exit) → este processo cai; o
  # :DOWN abaixo só é alcançado se a Task tiver terminado normal mas tardio.
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:ready?, _from, state) do
    {:reply, state.ready?, state}
  end

  defp emit_ready(%Config{} = conf) do
    :telemetry.execute([:meli_graph, :instance, :ready], %{}, %{name: conf.name, node: node()})
  end
end
