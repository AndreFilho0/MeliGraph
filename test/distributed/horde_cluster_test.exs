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
