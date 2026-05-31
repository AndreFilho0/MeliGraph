# Arquitetura

## Visão Geral

MeliGraph é organizado em camadas isoladas, onde escrita e leitura não competem por recursos. O design segue três inspirações principais:

| Fonte | O que aproveitamos |
|-------|-------------------|
| **WTF / Cassovary** (Twitter, 2013) | Grafo em memória single-server, Circle of Trust, SALSA |
| **GraphJet** (Twitter, 2016) | Grafo bipartido real-time, segmentação temporal, single-writer/multi-reader |
| **Oban** (Elixir) | Config struct, Registry, Plugin behaviour, modos de testing, telemetry spans |

## Diagrama de Camadas

```
┌──────────────────────────────────────────────────────────────┐
│                     API Pública (MeliGraph)                  │
│  MeliGraph.recommend(name, user_id, :content, top: 20)      │
│  MeliGraph.neighbors(name, entity_id, :outgoing)            │
│  MeliGraph.insert_edge(name, u, v, :like)                   │
└──────────┬───────────────────────────────┬───────────────────┘
           │                               │
           │  ┌────────────────────────┐   │
           │  │  MeliGraph.Config      │   │  ← Config struct centralizado
           │  │  (validado uma vez)    │   │    passado para todos os processos
           │  └────────────────────────┘   │
           │                               │
   ┌───────▼────────┐            ┌─────────▼──────────┐
   │  Query Layer   │            │  Ingestion Layer   │
   │  (Leitura)     │            │  (Escrita)         │
   │                │            │                    │
   │  - Lê do cache │            │  - Single writer   │
   │  - Se miss,    │            │    GenServer       │
   │    computa     │            │  - trap_exit       │
   │    inline      │            │  - drain on        │
   │  - No modo     │            │    shutdown        │
   │    :sync,      │            │  - Telemetry span  │
   │    sem cache   │            │    em cada insert  │
   └───────┬────────┘            └─────────┬──────────┘
           │                               │
   ┌───────▼───────────────────────────────▼──────────┐
   │            Graph Storage Layer                   │
   │                                                  │
   │  - ETS tables (adjacency lists, tipo :bag)       │
   │  - Segmentos temporais (GraphJet-style)          │
   │  - ID mapping global (externo → interno)         │
   │  - Processos registrados via Registry            │
   └──────────────────────┬───────────────────────────┘
                          │
   ┌──────────────────────▼───────────────────────────┐
   │         Computation Layer                        │
   │                                                  │
   │  - Algorithm behaviour genérico                  │
   │  - PageRank (Monte Carlo random walks)           │
   │  - SALSA (Subgraph bipartido)                    │
   │  - Telemetry span em cada compute                │
   │  - No modo :sync, roda no processo chamador      │
   └──────────────────────┬───────────────────────────┘
                          │
   ┌──────────────────────▼───────────────────────────┐
   │         Result Store Layer                       │
   │                                                  │
   │  - ETS para cache de resultados                  │
   │  - TTL configurável                              │
   │  - Invalidação lazy na leitura                   │
   │  - Store behaviour extensível                    │
   └──────────────────────┬───────────────────────────┘
                          │
   ┌──────────────────────▼───────────────────────────┐
   │         Plugin Layer                             │
   │                                                  │
   │  - Plugin behaviour                              │
   │  - Plugins.Pruner → remove segmentos expirados   │
   │  - Plugins.CacheCleaner → TTL cleanup            │
   │  - Cada plugin é GenServer supervisionado        │
   │  - Desabilitados no modo :sync                   │
   └──────────────────────────────────────────────────┘
```

## Supervision Tree

```
MeliGraph.Supervisor (strategy: :rest_for_one)
│
├── Registry (keys: :unique, name: :"#{name}.Registry")
│
├── MeliGraph.ConfigHolder         ← registra o Config no Registry
│
├── MeliGraph.Graph.IdMap          ← mapeamento global de IDs
│
├── MeliGraph.Graph.SegmentManager ← gerencia segmentos temporais
│
├── MeliGraph.Ingestion.Writer     ← single-writer + trap_exit + drain
│
├── MeliGraph.Store.ETS            ← cache de resultados com TTL
│
├── MeliGraph.Plugins.Supervisor   ← [SKIP no modo :sync]
│   ├── MeliGraph.Plugins.Pruner
│   └── MeliGraph.Plugins.CacheCleaner
│
└── MeliGraph.Bootstrapper         ← rebuild via on_ready (sempre o último)
```

A estratégia `rest_for_one` garante que se o `SegmentManager` crashar, o `Writer` e componentes downstream reiniciam junto, evitando inconsistências. O `Bootstrapper` é sempre o **último** filho: uma falha no rebuild não derruba o data layer, e uma falha no data layer reinicia o Bootstrapper (que re-roda a MFA `on_ready` sobre uma ETS fresca).

## Fluxo de Dados

### Inserção (Escrita)

```
insert_edge("user:1", "post:a", :like)
  │
  ▼
Writer (GenServer) ──── sync/async conforme modo testing
  │
  ├── IdMap.get_or_create("user:1") → 0
  ├── IdMap.get_or_create("post:a") → 1
  │
  ▼
SegmentManager.insert(0, 1, :like)
  │
  ├── Segmento ativo com espaço? → insere no ETS
  └── Segmento cheio? → rotaciona, insere no novo
```

### Consulta (Leitura)

```
recommend("user:1", :content, algorithm: :pagerank)
  │
  ▼
Query Layer
  │
  ├── Modo :sync → computa inline
  └── Modo :disabled → verifica cache
        │
        ├── Cache hit → retorna
        └── Cache miss → computa + armazena
              │
              ▼
        Algorithm.PageRank.compute(...)
              │
              ├── Random walks no grafo (leitura ETS direta)
              ├── Contagem de visitas → normalização
              └── Resolução de IDs internos → externos
```

## Modo Distribuído (v0.3)

Por padrão a árvore acima é **node-local** (ETS é node-local). O modo distribuído
(**opt-in**, `distribution: :horde`) aloca cada grafo em **um nó dono** e roteia a
API de qualquer nó do cluster. Guia operador: [distribution.md](distribution.md);
design completo: [distributed-v0.3-implementation.md](distributed-v0.3-implementation.md).

```
API pública (mesma assinatura)
        │
        ▼
MeliGraph.Router (stateless)
   ├── conf no Registry LOCAL? (modo :local OU este nó é o dono)
   │        → fast path: chamada direta, ETS direto, multi-reader, zero Horde
   └── senão (nó remoto) → :erpc.call(dono, Router, :run_local, [...])
        │ remoto                                       ▲
        ▼                                              │ run_local roda no dono,
MeliGraph.Distributed (app adiciona 1×)                │ contra a ETS local
   ├── Horde.Registry  MeliGraph.HordeRegistry  ───────┘ (mesmo código de hoje)
   │     descoberta {name → {pid, %Config{}}}
   └── Horde.DynamicSupervisor  MeliGraph.HordeSupervisor
         UniformDistribution elege o dono + reinicia no failover
```

**Por que 1 `:erpc.call` por operação, e não um proxy vizinho-a-vizinho:** as
leituras de algoritmo passam por `SegmentManager.all_segments/1` (um
`GenServer.call`) **milhares de vezes** por `recommend`. Proxyar cada lookup por
RPC seria inviável (latência). Em vez disso, a **operação inteira** (`compute`,
`insert_edge`, contagens) é enviada ao dono e executa lá contra a ETS local —
**comando + resultado** cruzam a rede, nunca o acesso ao dado. O cache de
resultados (`Store.ETS`) mora no dono e absorve a leitura repetida.

**Por que `:erpc.call` e não um `GenServer.call` central:** rotear leitura por um
único processo serializaria as leituras (mataria o multi-reader). `:erpc.call`
roda num processo **novo** no dono → ETS concorrente preservada. Escritas seguem
pelo `Writer` single-writer (invariante preservada).

No modo `:local` (default), `Router` resolve tudo localmente — **zero** overhead
de Horde/`:erpc`, comportamento byte-a-byte idêntico ao single-node.
