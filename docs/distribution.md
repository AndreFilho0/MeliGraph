# Modo Distribuído (v0.3) — Guia do Operador

> Para o **design** e o plano de implementação, veja
> [distributed-v0.3-implementation.md](distributed-v0.3-implementation.md).
> Este documento é o guia prático de quem **opera** a MeliGraph num cluster.

## O que é

Por padrão a MeliGraph é **single-node**: o grafo vive em ETS local. Num cluster
BEAM, cada nó subiria sua própria cópia e elas **divergiriam** (uma escrita
incremental só atinge o nó que a processou).

O modo distribuído (**opt-in**, v0.3) resolve isso alocando cada grafo em **um
nó dono** (consistent hashing por `name`), descoberto cluster-wide via Horde. A
API roteia chamadas transparentemente: de qualquer nó você chama
`MeliGraph.recommend(:feed, ...)` e a operação executa no dono, contra a ETS
local dele — o que cruza a rede é **comando + resultado**, via 1 `:erpc.call`.

`distribution: :local` (default) = **comportamento single-node 100% idêntico**,
sem Horde, sem overhead.

## Pré-requisitos

1. **Cluster Erlang** formado (responsabilidade do app — ex.: `libcluster`). A
   MeliGraph **não** clusteriza; ela se apoia no `Node.list()` existente.
2. **Deps opcionais** no `mix.exs` do app:

   ```elixir
   {:meli_graph, "~> 0.3"},
   {:horde, "~> 0.10"},
   {:libring, "~> 1.7"}
   ```

3. **Nó vivo** (`Node.alive?() == true`). Sem isso, `distribution: :horde`
   degrada para `:local` (gate `MeliGraph.Distributed.distributed_context?/0`).

## Setup no app

1. Adicione **`MeliGraph.Distributed` uma única vez** na árvore de supervisão
   do app (junto a outros componentes Horde, se houver):

   ```elixir
   children = [
     MeliGraph.Distributed,
     # ... resto do app ...
   ]
   ```

2. Suba cada grafo com `distribution: :horde` e um `on_ready` que reconstrói o
   grafo da fonte da verdade (Postgres, etc.). Use os **mesmos opts em todos os
   nós** (o dedup do Horde é por `name`):

   ```elixir
   children = [
     MeliGraph.Distributed,
     {MeliGraph,
        name: :feed,
        graph_type: :bipartite,
        distribution: :horde,
        on_ready: {MyApp.FeedLoader, :load, [:feed]}}
   ]
   ```

3. **Remova** os `Task.start(fn -> ...Loader.load() end)` do boot: o `on_ready`
   passa a dispará-los — **só no dono**, com re-trigger automático no failover
   (em dev single-node, roda 1× no boot).

> **Contrato do loader:** a MFA `on_ready` deve **assumir o grafo vazio** e
> inserir todas as arestas. No modo distribuído a ETS está sempre fresca quando
> ela roda (boot ou realocação). Lembre que `insert_edge` **soma pesos** no
> re-insert (não é idempotente), por isso o contrato "assuma vazio".

## API

A assinatura é **a mesma** do single-node. Novidades:

| Função | Uso |
|---|---|
| `MeliGraph.ready?(name)` | `true` quando o `on_ready` terminou. Útil para gatear leituras no boot frio / pós-failover. |
| `MeliGraph.owner_node(name)` | Nó que hospeda o grafo (`Node.self()` se local/dono). Use para rodar operações longas como `train_embeddings/2` **no dono**. |

**Erros novos** a tratar (a API de `recommend` já é `{:ok,_} | {:error,_}`):

- `{:error, :graph_unavailable}` — descoberta não convergiu / grafo realocando.
- `{:error, :graph_timeout}` — o `:erpc.call` ao dono estourou `cluster_call_timeout`.

`insert_edge` em modo `:disabled` (fire-and-forget) **dropa com warning** quando
o grafo está indisponível — a fonte da verdade é o Postgres + `on_ready` (replay).

## Comportamento

- **Leitura repetida** é absorvida pelo cache de resultados (`Store.ETS` +
  `result_ttl`) que mora **no dono** — chamadas remotas de vários nós reusam o
  mesmo cache.
- **Failover:** se o nó dono cai, a árvore do grafo é reiniciada num nó
  sobrevivente; a ETS sobe **vazia** e o `on_ready` repovoa do Postgres.
  `ready?/1` volta a `true` quando termina. Durante a janela fria, as
  recomendações degradam (grafo vazio → cold start).
- **Rede de segurança do failover (`MeliGraph.Reconciler`):** o failover
  automático do Horde sofre uma **corrida** sob queda abrupta do dono — em parte
  das vezes o `Horde.NodeListener` (`members: :auto`) remove o nó morto do CRDT
  antes que o processo órfão seja realocado, e o grafo fica perdido. Por isso
  cada nó roda um reconciliador: a cada `reconcile_interval` (2s) ele checa
  `lookup_owner`; se o grafo fica sem dono por mais de `reconcile_grace` (5s),
  re-dispara `ensure_started/1`. Assim a recuperação acontece sempre — pelo Horde
  (~1s) ou pelo reconciliador (~`grace`). O guard por `lookup_owner` (registro no
  `conf.name` estável) evita dupla-alocação mesmo com o `randomize_child_id` do
  handoff do Horde. Emite `[:meli_graph, :reconciler, :reassert]` quando atua.
- **`train_embeddings/2`** é longo: roteie no dono (`owner_node/1`) com timeout
  generoso.

## Lab de 2 nós (smoke manual)

```bash
epmd -daemon
PORT=4000 iex --name app1@127.0.0.1 --cookie lab -S mix phx.server
PORT=4001 iex --name app2@127.0.0.1 --cookie lab -S mix phx.server
```

```elixir
Node.list()                                      # cluster formado
Horde.Cluster.members(MeliGraph.HordeRegistry)   # 2 membros
MeliGraph.Distributed.lookup_owner(:feed)        # {:ok, pid, conf} — dono único
MeliGraph.owner_node(:feed)                       # mesmo nó nos dois IEx

# do nó que NÃO é dono:
MeliGraph.insert_edge(:feed, "profile:1", "post:9", :like)
MeliGraph.recommend(:feed, "profile:1", :content, algorithm: :pagerank)
MeliGraph.ready?(:feed)                           # true após on_ready
```

Failover: `:init.stop` / kill no nó dono → no outro IEx, `lookup_owner` migra de
nó e `edge_count` volta ao esperado (rebuild via `on_ready`).

## Trade-offs honestos

- **Hot spot de leitura no dono:** toda recomendação de um grafo bate num nó.
  Mitigado pelo cache por-nó e pela escala atual (grafos cabem folgado em 1 nó).
  Read-replicas opt-in ficam para a v0.4.
- **Janela fria no failover:** enquanto o `on_ready` reconstrói, recomendações
  degradam. Sinalizável via `ready?/1`.
- **Latência de recuperação:** quando o Horde acerta o handoff, ~1s; quando o
  reconciliador precisa atuar, ~`reconcile_grace` + `reconcile_interval` + rebuild.
  Ajuste os dois via `Config` se precisar recuperação mais agressiva (ao custo de
  aproximar a janela de dupla-alocação descrita abaixo).
- **Dupla-alocação (rara):** se o handoff do Horde e o reconciliador disparam na
  mesma janela, pode subir uma 2ª árvore-zumbi (memória + um `on_ready` extra; sem
  tráfego, pois não vence o registro `:unique`). O `reconcile_grace` (> ~1-2s da
  recuperação do Horde) torna isso improvável; não há limpeza automática do zumbi.
- **Eventual consistency da descoberta:** janela de ms (delta_crdt); tratada com
  retry/backoff no Router. Sob netsplit, o comportamento é reconciliado-do-Postgres
  no heal (sem merge CRDT de estado de grafo — fora de escopo da v0.3).
- **Tráfego entre nós** depende do cookie Erlang; em produção, mesma VPC/região
  ou malha tipo WireGuard.

## Testes

```bash
epmd -daemon
mix test --include distributed
```

A suíte `test/distributed/horde_cluster_test.exs` sobe um cluster `:peer` real e
valida descoberta cross-node, insert/recommend remoto, failover + rebuild e
degradação para `:local`.
