# MeliGraph

Motor de Recomendação baseado em Grafos para Elixir.

Inspirado nos sistemas [WTF (Who to Follow)](https://stanford.edu/~rezab/papers/wtf_overview.pdf) e [GraphJet](http://www.vldb.org/pvldb/vol9/p1281-sharma.pdf) do Twitter, e nos padrões OTP do [Oban](https://github.com/oban-bg/oban).

## Features

- **Grafo em memória** com segmentação temporal (GraphJet-style)
- **PageRank Personalizado** via Monte Carlo random walks
- **SALSA** para grafos bipartidos (hubs/authorities)
- **SimilarItems** — co-ocorrência 2-hop com normalização Jaccard/Cosine
- **GlobalRank** — ranking global por in-degree para cold start
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
| **SimilarItems** | Bipartido | "Professores similares a X", itens co-consumidos |
| **GlobalRank** | Qualquer | Top itens para anônimos, cold start |

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

## Testes

```bash
# Testes unitários (sem dependências externas)
mix test
```

```
94 tests, 0 failures
```

Veja [docs/testing.md](docs/testing.md) para testes de integração com dados reais.

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
│   │   ├── salsa.ex                 # Subgraph SALSA
│   │   ├── similar_items.ex         # Co-ocorrência 2-hop (Jaccard/Cosine)
│   │   └── global_rank.ex           # Ranking global por in-degree
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
├── meli_graph_test.exs              # Testes de integração da API pública
├── meli_graph/                      # Testes unitários por módulo
│   ├── config_test.exs
│   ├── registry_test.exs
│   ├── telemetry_test.exs
│   ├── graph/
│   ├── ingestion/
│   ├── algorithm/
│   ├── query/
│   ├── store/
│   └── plugins/
├── integration/                     # Testes com dados reais (tag :integration)
│   ├── dataset_stats_test.exs       # Valida integridade dos CSVs
│   ├── follows_graph_test.exs       # Who to Follow com dados reais
│   ├── likes_graph_test.exs         # Feed de recomendações com dados reais
│   └── professors_graph_test.exs    # Recomendação de professores (SALSA, SimilarItems, GlobalRank)
└── support/
    ├── graph_helpers.ex             # Helpers para testes unitários
    └── dataset_loader.ex            # Carrega CSVs de produção
tmp/
├── meli_graph_follows.csv              # Exportado do banco (não versionado)
├── meli_graph_likes.csv
├── meli_graph_posts.csv
├── meli_graph_professors.csv           # Metadados dos professores
├── meli_graph_professor_ratings.csv    # Avaliações profile → professor
└── meli_graph_professor_posts.csv      # Posts sobre professores
```

## Roadmap

### v0.1 (atual)
- [x] Config struct + Registry + Supervisor
- [x] Graph storage com ETS + segmentação temporal
- [x] ID mapping global
- [x] Single-writer ingestion + graceful shutdown
- [x] PageRank Personalizado (Monte Carlo)
- [x] SALSA (Subgraph)
- [x] SimilarItems (co-ocorrência 2-hop com Jaccard/Cosine)
- [x] GlobalRank (ranking global por in-degree)
- [x] Store ETS com TTL
- [x] Query layer (sync + cache) com suporte a algoritmos globais
- [x] Plugin system (Pruner + CacheCleaner)
- [x] Telemetry spans
- [x] Modo de testing `:sync`
- [x] 94 testes unitários + 37 testes de integração com dados reais

### v0.2 (planejado)
- [ ] Pesos nas arestas (`:avaliou` pesar mais que `:postou`)
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
