defmodule MeliGraph.ClusterHelpers do
  @moduledoc """
  Helpers para subir um cluster BEAM efêmero com `:peer` (OTP 25+) nos testes
  `@tag :distributed`.

  Faz o nó primário (o VM do ExUnit) virar distribuído via `:net_kernel.start`,
  sobe N nós-peer conectados por distribuição, carrega o code path da lib em cada
  um e inicia `MeliGraph.Distributed` (Horde) no cluster inteiro. Espera a
  membership do Horde convergir antes de devolver.

  Requer EPMD rodando (`epmd -daemon`).
  """

  @primary :"meli_primary@127.0.0.1"
  @host ~c"127.0.0.1"
  @apps [:logger, :telemetry, :libring, :horde, :meli_graph]

  @doc """
  Garante que o nó primário é distribuído. Idempotente.
  """
  def ensure_primary do
    unless Node.alive?() do
      {:ok, _} = :net_kernel.start(@primary, %{name_domain: :longnames})
    end

    :ok
  end

  @doc """
  Sobe um cluster com `count` peers + o primário, todos rodando
  `MeliGraph.Distributed`. Retorna a lista de `{peer_pid, node}` dos peers.
  """
  def start_cluster(count) do
    ensure_primary()
    do_start_distributed()

    peers =
      for _ <- 1..count do
        start_peer(:erlang.unique_integer([:positive]))
      end

    nodes = [node() | Enum.map(peers, fn {_pid, n} -> n end)]
    wait_for_horde_members(length(nodes))
    peers
  end

  @doc false
  # Sobe `MeliGraph.Distributed` sob um processo "holder" NÃO-linkado ao chamador.
  # Necessário porque, via `:erpc`, o processo chamador é efêmero — se o
  # supervisor linkasse a ele, morreria assim que o erpc retornasse. O holder
  # dorme para sempre, mantendo a árvore Horde viva pelo tempo do teste.
  def do_start_distributed do
    if Process.whereis(MeliGraph.Distributed) do
      :ok
    else
      spawn_distributed_holder()
    end
  end

  defp spawn_distributed_holder do
    ref = make_ref()
    parent = self()

    {:ok, _holder} =
      Task.start(fn ->
        res =
          case MeliGraph.Distributed.start_link() do
            {:ok, pid} -> {:ok, pid}
            {:error, {:already_started, pid}} -> {:ok, pid}
          end

        send(parent, {ref, res})
        Process.sleep(:infinity)
      end)

    receive do
      {^ref, {:ok, _}} -> :ok
    after
      10_000 -> raise "MeliGraph.Distributed failed to start on #{inspect(node())}"
    end
  end

  @doc "Para todos os peers (tolera peers já mortos)."
  def stop_cluster(peers) do
    Enum.each(peers, fn {pid, _node} -> safe_stop(pid) end)
  end

  @doc "Para um peer específico (shutdown gracioso)."
  def stop_peer(pid), do: safe_stop(pid)

  @doc """
  Mata um nó abruptamente (`:erlang.halt`), simulando um CRASH — não um shutdown
  gracioso. Importante para o teste de failover: com `restart: :transient`, um
  `:shutdown` normal NÃO seria reiniciado pelo Horde; uma queda abrupta sim.
  """
  def kill_node(node) do
    :erpc.call(node, :erlang, :halt, [], 2_000)
  catch
    _, _ -> :ok
  end

  @doc """
  Inicia uma instância distribuída a partir de QUALQUER nó (alocada no dono pelo
  Horde). Basta chamar de um nó; o Horde reposiciona no failover sozinho.
  """
  def start_instance(opts) do
    MeliGraph.start_link(Keyword.put_new(opts, :distribution, :horde))
  end

  @doc """
  Inicia uma instância (e seu `Reconciler`) **num nó específico**, sob um holder
  que sobrevive ao retorno do `:erpc`. Espelha a fiação de produção, onde TODO nó
  adiciona `{MeliGraph, name: ..., distribution: :horde}` à própria árvore — logo
  todo nó roda um `Reconciler` (e, com ele, o reaper de duplicata).
  """
  def start_instance_on(node, opts) do
    :erpc.call(node, __MODULE__, :hold, [MeliGraph, :start_link, [opts]])
  end

  @doc """
  Injeta uma árvore local "crua" (`MeliGraph.Supervisor.start_link/1`) num nó —
  uma **duplicata** sintética, como a que uma corrida de boot/split produziria.
  Sob um holder não-linkado ao `:erpc` para sobreviver até o reaper agir.
  """
  def inject_duplicate_on(node, opts) do
    :erpc.call(node, __MODULE__, :hold, [MeliGraph.Supervisor, :start_link, [opts]])
  end

  @doc false
  # Roda no nó alvo: sobe `mod.fun(args)` dentro de uma Task NÃO-linkada ao
  # processo efêmero do `:erpc` e devolve o resultado do start. A Task dorme para
  # sempre, mantendo a árvore (linkada a ela) viva pelo tempo do teste.
  def hold(mod, fun, args) do
    ref = make_ref()
    parent = self()

    {:ok, _holder} =
      Task.start(fn ->
        res = apply(mod, fun, args)
        send(parent, {ref, res})
        Process.sleep(:infinity)
      end)

    receive do
      {^ref, res} -> res
    after
      10_000 -> raise "#{inspect(mod)}.#{fun} failed to start on #{inspect(node())}"
    end
  end

  @doc false
  # Handler de telemetria portável entre nós (capture `&Mod.fun/4` vira MFA, não
  # closure): encaminha o evento para o `test_pid` (que pode viver noutro nó).
  def forward_telemetry(event, _measurements, meta, test_pid) do
    send(test_pid, {:telemetry, event, meta})
  end

  # --- internals ---

  defp start_peer(i) do
    {:ok, pid, node} =
      :peer.start_link(%{
        name: :"meli_peer#{i}",
        host: @host,
        longnames: true
      })

    # Controle remoto via :erpc (a distribuição já conecta o peer ao primário).
    # `:peer.call/4` é evitado de propósito: em alguns OTP ele não usa a conexão
    # de distribuição e devolve :noconnection.
    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])

    Enum.each(@apps, fn app ->
      :erpc.call(node, Application, :ensure_all_started, [app])
    end)

    :ok = :erpc.call(node, __MODULE__, :do_start_distributed, [])
    {pid, node}
  end

  defp wait_for_horde_members(expected) do
    MeliGraph.TestHelpers.wait_until(
      fn ->
        length(Horde.Cluster.members(MeliGraph.Distributed.registry_name())) >= expected
      end,
      5_000
    ) || raise "Horde members did not converge to #{expected}"
  end

  defp safe_stop(pid) do
    :peer.stop(pid)
  catch
    _, _ -> :ok
  end
end
