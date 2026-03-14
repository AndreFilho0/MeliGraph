# MeliGraph

Motor de Recomendação baseado em Grafos para Elixir.

Inspirado nos sistemas [WTF (Who to Follow)](https://stanford.edu/~rezab/papers/wtf_overview.pdf) e [GraphJet](http://www.vldb.org/pvldb/vol9/p1281-sharma.pdf) do Twitter, e nos padrões OTP do [Oban](https://github.com/oban-bg/oban).

## Features

- **Grafo em memória** com segmentação temporal (GraphJet-style)
- **PageRank Personalizado** via Monte Carlo random walks
- **SALSA** para grafos bipartidos (hubs/authorities)
- **Single-writer / multi-reader** via GenServer + ETS
- **Múltiplas instâncias** isoladas via Registry
- **Telemetry-first** — todas as operações emitem eventos
- **Modo de testing `:sync`** — testes determinísticos sem processos async
- **Plugin system** — Pruner, CacheCleaner extensíveis

## Instalação

```elixir
def deps do
  [
    {:meli_graph, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Iniciar uma instância
{:ok, _} = MeliGraph.start_link(
  name: :my_graph,
  graph_type: :bipartite,
  testing: :sync
)

# Inserir arestas (usuário → conteúdo)
MeliGraph.insert_edge(:my_graph, "user:1", "post:a", :like)
MeliGraph.insert_edge(:my_graph, "user:2", "post:a", :like)
MeliGraph.insert_edge(:my_graph, "user:2", "post:b", :like)

# Recomendações
{:ok, recs} = MeliGraph.recommend(:my_graph, "user:1", :content,
  algorithm: :salsa, seed_size: 10, top_k: 5)

# Explorar o grafo
MeliGraph.neighbors(:my_graph, "user:1", :outgoing)
# => ["post:a"]

MeliGraph.edge_count(:my_graph)
# => 3
```

## Múltiplas Instâncias

```elixir
# Em uma Application supervision tree
children = [
  {MeliGraph, name: :follows, graph_type: :directed},
  {MeliGraph, name: :interactions, graph_type: :bipartite}
]

Supervisor.start_link(children, strategy: :one_for_one)

# Cada instância é isolada
MeliGraph.insert_edge(:follows, "user:1", "user:2", :follow)
MeliGraph.insert_edge(:interactions, "user:1", "post:a", :like)
```

## Algoritmos

| Algoritmo | Tipo de Grafo | Caso de Uso |
|-----------|--------------|-------------|
| **PageRank** | Dirigido | "Who to Follow", Circle of Trust |
| **SALSA** | Bipartido | "Posts para você", recomendação de conteúdo |

Algoritmos customizados podem ser adicionados implementando o behaviour `MeliGraph.Algorithm`.

## Configuração

```elixir
MeliGraph.start_link(
  name: :my_graph,                         # obrigatório
  graph_type: :bipartite,                  # obrigatório (:directed | :bipartite)
  segment_max_edges: 1_000_000,            # arestas por segmento
  segment_ttl: :timer.hours(24),           # TTL dos segmentos
  result_ttl: :timer.minutes(30),          # TTL do cache
  testing: :disabled,                      # :disabled | :sync
  plugins: [
    {MeliGraph.Plugins.Pruner, interval: :timer.minutes(5)},
    {MeliGraph.Plugins.CacheCleaner, interval: :timer.minutes(1)}
  ]
)
```

## Telemetry

Eventos emitidos para observabilidade:

```elixir
[:meli_graph, :ingestion, :insert_edge, :start | :stop | :exception]
[:meli_graph, :query, :recommend, :start | :stop | :exception]
[:meli_graph, :graph, :create_segment, :start | :stop | :exception]
[:meli_graph, :plugin, :prune, :start | :stop | :exception]
[:meli_graph, :plugin, :cache_clean, :start | :stop | :exception]
```

## Documentação Técnica

- [Arquitetura](docs/architecture.md) — Camadas, supervision tree e fluxo de dados
- [Graph Storage](docs/graph-storage.md) — Segmentação temporal, ETS e ID mapping
- [Estruturas de Dados](docs/data-structures.md) — Cada estrutura usada, justificativa e trade-offs
- [Algoritmos](docs/algorithms.md) — PageRank, SALSA, extensibilidade
- [Padrões OTP](docs/otp-patterns.md) — Config struct, Registry, plugins, telemetry
- [Testing](docs/testing.md) — Modo `:sync`, helpers, exemplos de testes
- [API Reference](docs/api-reference.md) — Referência completa da API pública

## Estrutura do Projeto

```
lib/
├── meli_graph.ex                    # API pública
├── meli_graph/
│   ├── config.ex                    # Config struct centralizado
│   ├── config_holder.ex             # Registra config no Registry
│   ├── registry.ex                  # Registry helpers
│   ├── supervisor.ex                # Supervision tree
│   ├── telemetry.ex                 # Telemetry spans
│   ├── graph/
│   │   ├── edge.ex                  # Struct de aresta
│   │   ├── id_map.ex                # Mapeamento de IDs
│   │   ├── segment.ex               # Segmento temporal
│   │   └── segment_manager.ex       # Gerenciador de segmentos
│   ├── ingestion/
│   │   └── writer.ex                # Single-writer + graceful shutdown
│   ├── algorithm/
│   │   ├── algorithm.ex             # Behaviour genérico
│   │   ├── pagerank.ex              # Monte Carlo random walks
│   │   └── salsa.ex                 # Subgraph SALSA
│   ├── query/
│   │   └── query.ex                 # Cache-first, respeita testing mode
│   ├── store/
│   │   ├── store.ex                 # Store behaviour
│   │   └── ets.ex                   # ETS + TTL
│   └── plugins/
│       ├── plugin.ex                # Plugin behaviour
│       ├── pruner.ex                # Remove segmentos expirados
│       ├── cache_cleaner.ex         # TTL cleanup
│       └── supervisor.ex            # Supervisor dos plugins
test/
├── 14 arquivos de teste (75 testes)
└── support/graph_helpers.ex         # Test helpers
```

## Roadmap

### v0.1 (atual)
- [x] Config struct + Registry + Supervisor
- [x] Graph storage com ETS + segmentação temporal
- [x] ID mapping global
- [x] Single-writer ingestion + graceful shutdown
- [x] PageRank Personalizado (Monte Carlo)
- [x] SALSA (Subgraph)
- [x] Store ETS com TTL
- [x] Query layer (sync + cache)
- [x] Plugin system (Pruner + CacheCleaner)
- [x] Telemetry spans
- [x] Modo de testing `:sync`
- [x] 75 testes

### v0.2 (planejado)
- [ ] Similarity queries (cosine via sampling)
- [ ] PageRank via Nx power method
- [ ] Sonar (health check do Writer)
- [ ] Precomputer plugin
- [ ] Backpressure no Writer

### v0.3 (futuro)
- [ ] Peer behaviour + distribuição
- [ ] Pesos nas arestas
- [ ] Algoritmos adicionais (Node2Vec)

## Referências

1. Gupta et al., **"WTF: The Who to Follow Service at Twitter"**, WWW 2013
2. Sharma et al., **"GraphJet: Real-Time Content Recommendations at Twitter"**, VLDB 2016
3. Lempel & Moran, **"SALSA: The Stochastic Approach for Link-Structure Analysis"**, ACM TOIS 2001
4. Fogaras et al., **"Towards Scaling Fully Personalized PageRank"**, Internet Mathematics 2005
5. Page et al., **"The PageRank Citation Ranking"**, Stanford 1999

## Licença

Veja [LICENSE](LICENSE).
