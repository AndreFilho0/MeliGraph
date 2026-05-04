# MeliGraph

Motor de Recomendação baseado em Grafos para Elixir.

Inspirado nos sistemas [WTF (Who to Follow)](https://stanford.edu/~rezab/papers/wtf_overview.pdf) e [GraphJet](http://www.vldb.org/pvldb/vol9/p1281-sharma.pdf) do Twitter, e nos padrões OTP do [Oban](https://github.com/oban-bg/oban).

## Features

- **Grafo em memória** com segmentação temporal (GraphJet-style)
- **Pesos nas arestas** (v0.2.1) — `insert_edge/5` aceita `weight` opcional, usado pelo LightGCN para construir `Ã = D^(-1/2)·W·D^(-1/2)` ponderada
- **PageRank Personalizado** via Monte Carlo random walks
- **SALSA** para grafos bipartidos (hubs/authorities)
- **SimilarItems** — co-ocorrência 2-hop com normalização Jaccard/Cosine
- **GlobalRank** — ranking global por in-degree para cold start
- **LightGCN** — embeddings aprendidos via Nx.Defn + BPR loss (v0.2) com fallback automático para SALSA
- **Single-writer / multi-reader** via GenServer + ETS
- **Múltiplas instâncias** isoladas via Registry
- **Telemetry-first** — todas as operações emitem eventos
- **Modo de testing `:sync`** — testes determinísticos sem processos async
- **Plugin system** — Pruner, CacheCleaner extensíveis

## Instalação

```elixir
def deps do
  [
    {:meli_graph, "~> 0.2.1"},
    # Recomendado para o LightGCN em produção:
    {:exla, "~> 0.9"}    # backend XLA (CPU/GPU) para o trainer
  ]
end
```

> **Mudança em v0.2.1:** `:nx` agora é dependência obrigatória do `meli_graph`
> (era `optional`). Não precisa declará-la nas suas deps — vem transitivamente.

E configure o EXLA como compilador padrão de `Nx.Defn`:

```elixir
# config/config.exs (ou config/runtime.exs no app caller)
config :nx, default_backend: EXLA.Backend
config :nx, :default_defn_options, compiler: EXLA
```

Sem EXLA o LightGCN ainda compila e roda (via `Nx.BinaryBackend`), mas é
ordens de magnitude mais lento — em produção, EXLA é obrigatório para
treinos noturnos caberem em janela de horas. Quando o trainer detecta a
ausência de EXLA, emite um `Logger.warning` uma vez por VM no primeiro
treino.

## Quick Start

```elixir
# Iniciar uma instância
{:ok, _} = MeliGraph.start_link(
  name: :my_graph,
  graph_type: :bipartite,
  testing: :sync
)

# Inserir arestas (usuário → conteúdo). Peso opcional (default 1.0).
MeliGraph.insert_edge(:my_graph, "user:1", "post:a", :like)
MeliGraph.insert_edge(:my_graph, "user:2", "post:a", :like)
MeliGraph.insert_edge(:my_graph, "user:2", "post:b", :comment, 1.5)

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
| **LightGCN** | Bipartido | Recomendação personalizada via embeddings aprendidos |

Algoritmos customizados podem ser adicionados implementando o behaviour `MeliGraph.Algorithm`.

## Pesos nas Arestas (v0.2.1)

Toda aresta carrega um campo `weight :: float()` (default `1.0`) que
representa a força do sinal user↔item. Pesos são consumidos pelo
**LightGCN** ao construir a matriz de adjacência ponderada
`Ã = D^(-1/2) · W · D^(-1/2)`. Os demais algoritmos (PageRank, SALSA,
SimilarItems, GlobalRank) ignoram o peso na v0.2.1 — comportamento
idêntico ao de v0.2.0.

```elixir
# Click é sinal mais forte que like; like mais que view.
MeliGraph.insert_edge(:feed, "profile:42", "post:7", :view, 0.5)
MeliGraph.insert_edge(:feed, "profile:42", "post:7", :like, 1.0)
MeliGraph.insert_edge(:feed, "profile:42", "post:7", :comment, 1.5)
```

### Acumulação de pesos

Quando múltiplas arestas conectam o mesmo par `(user, item)`, o
**LightGCN soma os pesos** ao construir `W`. No exemplo acima, o par
`profile:42 ↔ post:7` entra na matriz com `W[u,i] = 3.0` (0.5 + 1.0 + 1.5).
Interpretação: cada interação positiva adiciona evidência ao sinal.

> **Mudança de comportamento (v0.2.1, importante):** chamar `insert_edge`
> repetidamente para o mesmo par **não é mais idempotente** do ponto de vista
> do LightGCN — cada chamada adiciona peso. Em v0.2.0 inserções duplicadas
> eram deduplicadas. Para grafos do tipo `:directed` (ex.: follows recíprocos),
> evite inserir o mesmo par duas vezes — ou aceite que o LightGCN tratará
> como sinal acumulado.

### Recomendações sobre escolha de pesos

- **Range pequeno e estável** funciona melhor (`0.5` a `3.0`). Pesos grandes
  desbalanceiam a normalização `D^(-1/2)` e dominam o ranking.
- **Sinais implícitos** (view, click) costumam pesar menos que **explícitos**
  (like, comentário, favorito).
- Se o range natural dos pesos for amplo (ex.: dwell time em segundos),
  aplique `:math.log/1` ou clamp manual antes de inserir.
- Pesos em testes A/B: comece **uniforme** (`1.0` em tudo), valide o pipeline
  fim-a-fim com SALSA/LightGCN, e só depois introduza pesos diferenciados
  comparando recall@K.

## LightGCN (v0.2)

Modelo de embedding colaborativo (paper *He et al., SIGIR 2020*) treinado
via `Nx.Defn` + BPR loss. A lib **não persiste embeddings** — produz e
consome `binary`; o app caller decide onde guardar (Postgres, R2, S3...).

A v0.2.1 incorpora **pesos das arestas** na matriz de adjacência:
`Ã = D^(-1/2) · W · D^(-1/2)` em vez da `A` binária do paper original.
Pesos somam quando múltiplas arestas conectam o mesmo par user↔item.

```elixir
# 1. Treinar — lê o grafo atual e devolve um binary serializado
{:ok, binary} = MeliGraph.train_embeddings(:professor_graph,
  user_prefix: "profile:",
  embedding_dim: 64,
  layers: 3,
  epochs: 1000
)

# 2. App persiste o binary onde quiser (Postgres bytea, R2, etc.)
Repo.insert(%GraphEmbedding{graph_name: "professor_graph", data: binary})

# 3. Carregar embeddings na instância (ETS com TTL :infinity)
:ok = MeliGraph.load_embeddings(:professor_graph, binary)

# 4. Recomendar — top-K via dot product
{:ok, recs} = MeliGraph.recommend(:professor_graph, "profile:42", :content,
  algorithm: :lightgcn, top_k: 16)

# 5. Health check — fallback automático para SALSA quando false
MeliGraph.embeddings_ready?(:professor_graph)
# => true
```

Quando os embeddings ainda não foram carregados, `algorithm: :lightgcn`
faz **fallback transparente para SALSA** — o caller não precisa tratar
esse caso. Veja [docs/lightgcn.md](docs/lightgcn.md) para arquitetura,
fluxo de treino, hiperparâmetros e validação empírica.

### Recomendação para feed heterogêneo (posts + reviews + ads)

LightGCN não distingue tipos de item — ele só vê uma matriz bipartida
`users × items`. Para um feed que mistura posts normais, reviews de
professor e anúncios, basta unificar tudo num pool de itens com IDs
**namespaced** (`post:42`, `review:128`, `ad:7`).

**Exemplo end-to-end:** monte o grafo a partir das tabelas do app,
diferenciando o sinal por tipo de interação via `weight`:

```elixir
# config/config.exs
config :meli_graph,
  weights: %{
    view: 0.5,
    like: 1.0,
    comment: 1.5,
    click: 2.0
  }

# Pipeline de ingestão (ex.: job noturno + stream de eventos novos)
defmodule MyApp.GraphIngestion do
  @weights Application.compile_env(:meli_graph, :weights)

  def rebuild_graph! do
    {:ok, _} = MeliGraph.start_link(
      name: :feed,
      graph_type: :bipartite,
      segment_max_edges: 5_000_000
    )

    # Posts normais — likes
    Repo.all(
      from l in Like,
        join: p in Post, on: p.id == l.post_id,
        where: l.like_type == "upvote" and p.type == "normal" and not p.removed,
        select: {l.profile_id, l.post_id}
    )
    |> Enum.each(fn {profile_id, post_id} ->
      MeliGraph.insert_edge(
        :feed,
        "profile:#{profile_id}",
        "post:#{post_id}",
        :like,
        @weights.like
      )
    end)

    # Posts normais — comentários (sinal mais forte)
    Repo.all(
      from c in Comment,
        join: p in Post, on: p.id == c.post_id,
        where: not c.removed and p.type == "normal" and not p.removed,
        select: {c.profile_id, c.post_id}
    )
    |> Enum.each(fn {profile_id, post_id} ->
      MeliGraph.insert_edge(
        :feed,
        "profile:#{profile_id}",
        "post:#{post_id}",
        :comment,
        @weights.comment
      )
    end)

    # Reviews de professor (posts type=sobre_professor) — likes
    Repo.all(
      from l in Like,
        join: p in Post, on: p.id == l.post_id,
        where: l.like_type == "upvote" and p.type == "sobre_professor" and not p.removed,
        select: {l.profile_id, l.post_id}
    )
    |> Enum.each(fn {profile_id, post_id} ->
      MeliGraph.insert_edge(
        :feed,
        "profile:#{profile_id}",
        "review:#{post_id}",
        :like,
        @weights.like
      )
    end)

    # Ads — cliques (sinal mais forte de todos)
    Repo.all(from c in Click, select: {c.profile_id, c.ad_id})
    |> Enum.each(fn {profile_id, ad_id} ->
      MeliGraph.insert_edge(
        :feed,
        "profile:#{profile_id}",
        "ad:#{ad_id}",
        :click,
        @weights.click
      )
    end)
  end
end

# Job noturno: treina embeddings e persiste o binary
defmodule MyApp.NightlyTrain do
  def run do
    MyApp.GraphIngestion.rebuild_graph!()

    {:ok, binary} = MeliGraph.train_embeddings(:feed,
      user_prefix: "profile:",
      embedding_dim: 64,
      layers: 3,
      epochs: 1_000
    )

    Repo.insert!(%GraphEmbedding{
      graph_name: "feed",
      data: binary,
      trained_at: DateTime.utc_now()
    })

    :ok = MeliGraph.load_embeddings(:feed, binary)
  end
end

# Endpoint do feed
def get_feed(profile_id) do
  {:ok, recs} = MeliGraph.recommend(:feed, "profile:#{profile_id}", :content,
    algorithm: :lightgcn, top_k: 50)

  # Cada rec é {namespaced_id, score}. O caller resolve o tipo pelo prefixo:
  Enum.map(recs, fn {item_id, score} ->
    case String.split(item_id, ":", parts: 2) do
      ["post", id]   -> {:post, String.to_integer(id), score}
      ["review", id] -> {:review, String.to_integer(id), score}
      ["ad", id]     -> {:ad, String.to_integer(id), score}
    end
  end)
end
```

**Pontos importantes:**

- **IDs colidem entre tabelas** (`posts.id = 42` e `ads.id = 42` coexistem).
  O namespacing (`post:42`, `ad:42`) resolve isso e é a chave que aparece
  no resultado de `recommend/4` — o caller decompõe pelo prefixo.
- **Ranking misto:** o feed final mistura naturalmente os três tipos
  conforme o sinal histórico do usuário. Se quiser garantir presença
  mínima de cada tipo, faça pós-filtragem no caller (ex.: pegar top-20
  posts, top-10 reviews, top-5 ads do resultado).
- **Cold start:** usuário sem interações cai no fallback SALSA — que
  por sua vez precisa de pelo menos algum vizinho. Para anônimos, use
  `algorithm: :global_rank` direto.
- **Frequência de treino:** ads entram/saem rápido. Considere treino
  diário + stream de inserções incremental no grafo (próximo treino
  reaprende). Retreino incremental fica para v0.3.

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
181 tests, 0 failures, 37 excluded (integration)
```

Veja [docs/testing.md](docs/testing.md) para testes de integração com dados reais.

## Documentação Técnica

- [Arquitetura](docs/architecture.md) — Camadas, supervision tree e fluxo de dados
- [Graph Storage](docs/graph-storage.md) — Segmentação temporal, ETS e ID mapping
- [Estruturas de Dados](docs/data-structures.md) — Cada estrutura usada, justificativa e trade-offs
- [Algoritmos](docs/algorithms.md) — PageRank, SALSA, extensibilidade
- [LightGCN (v0.2)](docs/lightgcn.md) — Arquitetura, fluxo de treino, dependências e validação empírica
- [Plano LightGCN v0.2](docs/lightgcn-v02-implementation.md) — Plano de implementação fase a fase
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
│   │   ├── global_rank.ex           # Ranking global por in-degree
│   │   └── lightgcn.ex              # Inferência via dot product (v0.2)
│   ├── lightgcn/                    # v0.2 — embeddings aprendidos
│   │   ├── matrix.ex                # Ã = D^(-1/2)·A·D^(-1/2) via Nx
│   │   ├── trainer.ex               # BPR loss + Adam em defn
│   │   └── embedding_store.ex       # Ciclo de vida do payload no ETS
│   ├── query/
│   │   └── query.ex                 # Cache-first + fallback :lightgcn → :salsa
│   ├── store/
│   │   ├── store.ex                 # Store behaviour
│   │   └── ets.ex                   # ETS + TTL (numérico ou :infinity)
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

### v0.1
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

### v0.2 — LightGCN
- [x] `Store.ETS` com TTL `:infinity` (embeddings nunca expiram por tempo)
- [x] `LightGCN.Matrix` — `Ã = D^(-1/2)·A·D^(-1/2)` via Nx
- [x] `LightGCN.Trainer` — BPR loss + Adam manual em `defn`, autodiff via `value_and_grad`
- [x] `LightGCN.EmbeddingStore` — ciclo de vida no ETS, payload validado
- [x] `Algorithm.LightGCN` — inferência via dot product
- [x] `Query` — fallback transparente para SALSA quando embeddings não estão prontos
- [x] API pública: `train_embeddings/2`, `load_embeddings/2`, `embeddings_ready?/1`
- [x] EXLA opcional para JIT do trainer (treino Gowalla 500u/100ep em ~99s)
- [x] Validação empírica no dataset Gowalla do paper (recall@20 18.6× acima de random)
- [x] 181 testes unitários (94 → 181, +87 desde v0.1)

### v0.2.1 (atual) — Pesos + Nx obrigatório
- [x] Campo `weight :: float()` em `MeliGraph.Graph.Edge` (default `1.0`)
- [x] `MeliGraph.insert_edge/5` aceita peso opcional
- [x] `Segment` armazena `{src, dst, type, weight}` em ETS (tabela `:bag`)
- [x] `LightGCN.Matrix` constrói `Ã = D^(-1/2)·W·D^(-1/2)` ponderada
- [x] Pesos somam quando múltiplas arestas conectam o mesmo par `(u, i)`
- [x] `:nx` agora é dependência obrigatória do hex (era `optional`)
- [x] `:exla` segue opcional, com `Logger.warning` no primeiro treino sem ele
- [x] Algoritmos legados (PageRank, SALSA, SimilarItems, GlobalRank) — comportamento idêntico (ignoram peso)
- [x] 183 testes unitários (181 → 183, +2 cobertura de pesos no `Matrix`)

#### Breaking changes (v0.2.0 → v0.2.1)

- **`MeliGraph.insert_edge/4` → `/5`** com `weight` opcional. Chamadas antigas
  (`insert_edge(name, src, dst, type)`) seguem funcionando — o peso default
  é `1.0`.
- **`MeliGraph.neighbors_*/2` retornam `{id, type, weight}`** (era `{id, type}`).
  Quem desestruturava a tupla precisa adicionar `_weight`.
- **`insert_edge` não é mais idempotente** do ponto de vista do LightGCN —
  inserir o mesmo par duas vezes soma pesos. Em v0.2.0 era deduplicado.
- **`:nx` virou dep obrigatória.** Quem usava `meli_graph` só para PageRank
  e listava `{:nx, ..., optional: true}` pode remover essa linha.

### v0.3 (planejado)
- [ ] Matriz sparse no LightGCN (escalar para grafos > 50k nós)
- [ ] Retreinamento incremental (warm start)
- [ ] Pesos respeitados por PageRank (random walk ponderado) e SALSA
- [ ] PageRank via Nx power method
- [ ] Sonar (health check do Writer) + Backpressure
- [ ] Precomputer plugin

### v0.4 (futuro)
- [ ] Peer behaviour + distribuição
- [ ] Algoritmos adicionais (Node2Vec)

## Referências

1. Gupta et al., **"WTF: The Who to Follow Service at Twitter"**, WWW 2013
2. Sharma et al., **"GraphJet: Real-Time Content Recommendations at Twitter"**, VLDB 2016
3. Lempel & Moran, **"SALSA: The Stochastic Approach for Link-Structure Analysis"**, ACM TOIS 2001
4. Fogaras et al., **"Towards Scaling Fully Personalized PageRank"**, Internet Mathematics 2005
5. Page et al., **"The PageRank Citation Ranking"**, Stanford 1999

## Licença

Veja [LICENSE](LICENSE).
