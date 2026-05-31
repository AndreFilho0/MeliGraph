defmodule MeliGraph.HordeClusterTest do
  @moduledoc """
  Testes ponta-a-ponta do modo distribuído num cluster `:peer` real.

  Excluídos por default (`@moduletag :distributed`). Rode com:

      epmd -daemon
      mix test --include distributed
  """
  use ExUnit.Case, async: false

  import MeliGraph.TestHelpers
  alias MeliGraph.ClusterHelpers
  alias MeliGraph.Distributed

  @moduletag :distributed
  @moduletag timeout: 120_000

  # Cluster fresco por teste: o teste de failover MATA um peer, então um cluster
  # compartilhado (`setup_all`) quebraria os demais. Peers são linkados ao
  # processo do teste → morrem no fim do teste (limpeza automática).
  setup do
    peers = ClusterHelpers.start_cluster(2)
    on_exit(fn -> ClusterHelpers.stop_cluster(peers) end)
    %{peers: peers}
  end

  defp uname, do: :"feed_#{:erlang.unique_integer([:positive])}"

  defp owner_node(name) do
    case Distributed.lookup_owner(name) do
      {:ok, pid, _conf} -> node(pid)
      :error -> nil
    end
  end

  defp seeded_opts(name) do
    [
      name: name,
      graph_type: :bipartite,
      testing: :sync,
      distribution: :horde,
      on_ready: {MeliGraph.TestHelpers, :seed_edges, [name]}
    ]
  end

  defp start_seeded(name) do
    {:ok, _} = ClusterHelpers.start_instance(seeded_opts(name))
    assert wait_until(fn -> owner_node(name) != nil end, 10_000)
    assert wait_until(fn -> MeliGraph.ready?(name) end, 10_000)
    name
  end

  test "descoberta cross-node: o dono é visível de qualquer nó", %{peers: [{_pid, peer_node} | _]} do
    name = start_seeded(uname())
    owner = owner_node(name)
    assert owner != nil

    # O mesmo dono é resolvido a partir de um peer remoto (com retry para a
    # janela de propagação do delta_crdt).
    assert wait_until(
             fn ->
               match?(
                 {:ok, _, _},
                 :erpc.call(peer_node, MeliGraph.Distributed, :lookup_owner, [name])
               )
             end,
             10_000
           )

    {:ok, pid, _conf} = :erpc.call(peer_node, MeliGraph.Distributed, :lookup_owner, [name])
    assert node(pid) == owner
  end

  test "insert + recommend a partir de um nó NÃO-dono são computados no dono",
       %{peers: peers} do
    name = start_seeded(uname())
    owner = owner_node(name)

    # Escolhe um peer VIVO que NÃO é o dono para originar as chamadas.
    {_pid, non_owner_node} = Enum.find(peers, fn {_pid, n} -> n != owner end)

    assert :ok =
             :erpc.call(non_owner_node, MeliGraph, :insert_edge, [name, "user:9", "post:z", :like])

    assert {:ok, recs} =
             :erpc.call(non_owner_node, MeliGraph, :recommend, [name, "user:2", :content, []])

    assert is_list(recs)

    # A escrita remota chegou ao dono: 3 (seed) + 1 = 4.
    assert wait_until(fn -> MeliGraph.edge_count(name) == 4 end, 5_000)
  end

  # A recuperação aqui é garantida pelo MeliGraph.Reconciler (rede de segurança):
  # sob queda abrupta, o failover automático do Horde é uma corrida que perde
  # ~50-60% das vezes; o reconciliador re-dispara a alocação após `reconcile_grace`.
  test "failover: matar o dono realoca o grafo e re-roda on_ready", %{peers: peers} do
    # Acha uma instância cujo dono seja um PEER (o primário não pode ser morto).
    {name, owner_node, _owner_peer_pid} = start_until_owned_by_peer(peers)

    assert MeliGraph.edge_count(name) == 3

    # Mata o nó dono abruptamente (crash, não shutdown gracioso).
    ClusterHelpers.kill_node(owner_node)

    # Horde realoca para um nó sobrevivente; on_ready repovoa a ETS nova.
    assert wait_until(
             fn ->
               case owner_node(name) do
                 nil -> false
                 ^owner_node -> false
                 new -> new in [node() | Node.list()]
               end
             end,
             30_000
           )

    assert wait_until(fn -> safe_ready?(name) end, 30_000)
    assert wait_until(fn -> safe_edge_count(name) == 3 end, 30_000)
  end

  # O reaper (MeliGraph.Reconciler) desfaz a corrida de boot/split: o
  # Horde.Registry (:unique) é um árbitro forte que converge para UM dono; o
  # start_child do Horde.DynamicSupervisor é a parte fraca que pode subir árvores
  # duplicadas. A cada tick, quem tem árvore local mas perdeu a eleição do
  # Registry reapa a própria árvore. Aqui injetamos uma duplicata sintética num
  # nó não-dono e provamos que ela morre, convergindo para uma única árvore.
  test "reaper: duplicata num nó não-dono é encerrada (corrida de boot/split)",
       %{peers: peers} do
    name = uname()
    opts = reaper_opts(name)
    peer_nodes = Enum.map(peers, fn {_pid, n} -> n end)
    all_nodes = [node() | peer_nodes]
    local_name = MeliGraph.Supervisor.local_name(name)

    # Fiação de produção: Reconciler em TODOS os nós (o reaper roda em todo lugar).
    {:ok, _} = MeliGraph.start_link(opts)
    Enum.each(peer_nodes, fn n -> {:ok, _} = ClusterHelpers.start_instance_on(n, opts) end)

    # Converge para um dono único, pronto e visível de todos os nós.
    assert wait_until(fn -> owner_node(name) != nil end, 10_000)
    owner = owner_node(name)
    assert wait_until(fn -> MeliGraph.ready?(name) end, 10_000)

    assert wait_until(
             fn ->
               Enum.all?(all_nodes, fn n ->
                 case :erpc.call(n, Distributed, :lookup_owner, [name]) do
                   {:ok, pid, _} -> node(pid) == owner
                   :error -> false
                 end
               end)
             end,
             10_000
           )

    # Estado limpo: SÓ o dono tem árvore local (cobre uma eventual duplicata da
    # própria corrida de boot, já reapada) antes de injetarmos a nossa.
    assert wait_until(fn -> only_owner_has_tree?(all_nodes, owner, local_name) end, 15_000)

    non_owner = Enum.find(all_nodes, &(&1 != owner))
    refute is_nil(non_owner)

    # Captura o evento de reap (handler roda NO nó não-dono; encaminha ao test pid).
    handler_id = "reap-#{System.unique_integer([:positive])}"

    :ok =
      :erpc.call(non_owner, :telemetry, :attach, [
        handler_id,
        [:meli_graph, :reconciler, :reap],
        &ClusterHelpers.forward_telemetry/4,
        self()
      ])

    # Injeta a árvore zumbi no nó não-dono.
    {:ok, zombie} = ClusterHelpers.inject_duplicate_on(non_owner, opts)
    assert :erpc.call(non_owner, Process, :whereis, [local_name]) == zombie

    # O reaper encerra a duplicata em 1-2 ticks e emite a telemetria correta.
    assert_receive {:telemetry, [:meli_graph, :reconciler, :reap], meta}, 10_000
    assert meta.name == name
    assert meta.node == non_owner
    assert meta.owner_node == owner

    assert wait_until(
             fn -> :erpc.call(non_owner, Process, :whereis, [local_name]) == nil end,
             10_000
           )

    # Estado convergido: exatamente UMA árvore (no dono original), sem dupla-carga
    # (edge_count roteia para o dono :unique = 3 do seed, não 6).
    assert owner_node(name) == owner
    assert only_owner_has_tree?(all_nodes, owner, local_name)
    assert MeliGraph.edge_count(name) == 3

    :erpc.call(non_owner, :telemetry, :detach, [handler_id])
  end

  test "degradação: distribution: :horde sem cluster sobe árvore local" do
    # Num nó isolado (sem contexto distribuído visível para um nome novo), a API
    # continua funcionando; aqui validamos via o caminho local explícito.
    # (A degradação pura por Node.alive?()==false é coberta na suíte default.)
    name = :"local_in_cluster_#{System.unique_integer([:positive])}"

    {:ok, _} =
      MeliGraph.start_link(name: name, graph_type: :bipartite, testing: :sync)

    MeliGraph.insert_edge(name, "a", "b", :follow)
    assert MeliGraph.edge_count(name) == 1
    assert MeliGraph.owner_node(name) == node()
  end

  # --- helpers ---

  # Opts do teste do reaper: como seeded_opts, mas com tick/grace curtos para o
  # reaper agir em ~sub-segundo. Idênticos por nó (contrato de ensure_started).
  defp reaper_opts(name) do
    [reconcile_interval: 300, reconcile_grace: 600] ++ seeded_opts(name)
  end

  # `true` quando exatamente o nó `owner` hospeda a árvore local `local_name` e
  # nenhum outro nó a hospeda.
  defp only_owner_has_tree?(all_nodes, owner, local_name) do
    Enum.all?(all_nodes, fn n ->
      has_tree? = is_pid(:erpc.call(n, Process, :whereis, [local_name]))
      if n == owner, do: has_tree?, else: not has_tree?
    end)
  end

  defp start_until_owned_by_peer(peers, attempt \\ 0)

  defp start_until_owned_by_peer(_peers, attempt) when attempt >= 8 do
    flunk("nenhuma instância ficou sob um peer em #{attempt} tentativas")
  end

  defp start_until_owned_by_peer(peers, attempt) do
    name = uname()
    start_seeded(name)
    owner = owner_node(name)

    case Enum.find(peers, fn {_pid, n} -> n == owner end) do
      {peer_pid, ^owner} -> {name, owner, peer_pid}
      nil -> start_until_owned_by_peer(peers, attempt + 1)
    end
  end

  defp safe_ready?(name) do
    MeliGraph.ready?(name) == true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp safe_edge_count(name) do
    MeliGraph.edge_count(name)
  rescue
    _ -> -1
  catch
    _, _ -> -1
  end
end
