# MeliGraph — Motor de Recomendação baseado em Grafos para Elixir

## 1. Visão Geral

**MeliGraph** é uma biblioteca Elixir para recomendações baseadas em teoria dos grafos, inspirada nos sistemas WTF (Who to Follow) e GraphJet do Twitter, e nos padrões de engenharia da lib Oban. A lib aproveita a infraestrutura do Erlang/OTP (processos leves, supervisão, distribuição) para oferecer um motor de recomendação escalável, genérico e em tempo real.

### Princípios de Design

- **Genérico**: aceita diferentes tipos de entidades (usuários, posts, produtos, etc.)
- **Em camadas**: entrada, processamento e leitura são isolados e não competem por recursos
- **Real-time first**: inserção de dados em tempo real alimenta recomendações frescas
- **Single-node first, distributed later**: começar com grafo em memória numa máquina, evoluir para distribuído
- **Dependência mínima**: apenas `Nx` para computação numérica
- **Oban-inspired OTP patterns**: Config struct centralizado, Registry para lookup de processos, Plugin behaviour para extensibilidade, modos de testing para usabilidade

### Inspirações Arquiteturais

| Fonte | O que aproveitamos |
|-------|-------------------|
| **WTF / Cassovary** (Twitter, 2013) | Grafo em memória single-server, Circle of Trust, SALSA para grafos dirigidos |
| **GraphJet** (Twitter, 2016) | Grafo bipartido real-time, segmentação temporal, edge pools, alias method, single-writer/multi-reader |
| **Oban** (Elixir) | Config struct, Registry, Plugin behaviour, modos de testing, telemetry spans, graceful shutdown |

---

## 2. Requisitos Funcionais

### 2.1 Gestão do Grafo

| Requisito | Descrição |
|-----------|-----------|
| RF-01 | Suportar grafos **dirigidos** (follow) e **bipartidos** (usuário↔conteúdo) |
| RF-02 | Inserção de arestas em tempo real via API pública |
| RF-03 | Remoção de arestas por janela temporal (pruning por segmentos, como no GraphJet) |
| RF-04 | Suportar **tipos de aresta** (follow, like, retweet, view, etc.) com cardinalidade pequena e fixa |
| RF-05 | Suportar **metadados em vértices** (perfil, contagem de seguidores, etc.) |
| RF-06 | Mapeamento de IDs externos (qualquer tipo) para IDs internos inteiros compactos |

### 2.2 Algoritmos de Recomendação

| Requisito | Descrição |
|-----------|-----------|
| RF-07 | **PageRank Personalizado** — random walk egocêntrico para computar "circle of trust" |
| RF-08 | **SALSA** — algoritmo bipartido (hubs/authorities) para recomendações de usuários e conteúdo |
| RF-09 | **Algorithm behaviour** genérico (padrão Oban Engine) para adicionar novos algoritmos |
| RF-10 | Suporte a **seed sets** configuráveis (um usuário, um conjunto de usuários, etc.) |

### 2.3 Consultas

| Requisito | Descrição |
|-----------|-----------|
| RF-11 | Dado um usuário, retornar top-N recomendações de conteúdo |
| RF-12 | Dado um usuário, retornar top-N usuários similares |
| RF-13 | Dado um item, retornar itens similares (similaridade por cosseno via vizinhança) |
| RF-14 | Consultas devem retornar em < 100ms para grafos de até 10M de arestas |

### 2.4 Persistência e Cache

| Requisito | Descrição |
|-----------|-----------|
| RF-15 | Resultados de recomendações pré-computados são salvos em cache local (ETS) |
| RF-16 | Suporte a persistência opcional via adaptador (pode ser ETS, Mnesia, ou qualquer store externo) |
| RF-17 | Invalidação automática de cache quando novas arestas afetam o circle of trust do usuário |

### 2.5 Infraestrutura (inspirados no Oban)

| Requisito | Descrição |
|-----------|-----------|
| RF-18 | **Config struct** centralizado validado no `start_link`, passado para todos os processos |
| RF-19 | **Registry** para lookup de processos — sem nomes hardcoded, suporta múltiplas instâncias |
| RF-20 | **Modos de testing** — `:sync` (síncrono, sem processos async) e `:disabled` (produção) |
| RF-21 | **Plugin behaviour** para componentes periódicos (Pruner, Precomputer, CacheCleaner) |
| RF-22 | **Graceful shutdown** no Ingestion Writer com `trap_exit` e dreno de mailbox |

---

## 3. Requisitos Não-Funcionais

| Requisito | Descrição |
|-----------|-----------|
| RNF-01 | Grafo inteiro em memória (como Cassovary/GraphJet) — single-server first |
| RNF-02 | Inserção de arestas não bloqueia leituras (single-writer, multi-reader via processos OTP) |
| RNF-03 | Processamento de algoritmos pesados acontece em processos separados com scheduling justo |
| RNF-04 | Nx para operações matriciais/vetoriais quando necessário (PageRank via power method) |
| RNF-05 | **Telemetry-first**: todas as operações críticas envoltas em `:telemetry.span/3` (padrão Oban) |
| RNF-06 | Tolerância a falhas via supervision trees do OTP |
| RNF-07 | API pública via behaviour/protocol para extensibilidade |
| RNF-08 | **Múltiplas instâncias** no mesmo node via Registry (ex: grafo de follows + grafo de likes) |

---

## 4. Arquitetura em Camadas

```
┌──────────────────────────────────────────────────────────────┐
│                     API Pública (MeliGraph)                  │
│  MeliGraph.recommend(name, user_id, :content, top: 20)      │
│  MeliGraph.similar(name, item_id, top: 10)                   │
│  MeliGraph.insert_edge(name, u, v, :like)                    │
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
   │    dispara     │            │  - trap_exit       │
   │    computação  │            │  - drain on        │
   │  - No modo     │            │    shutdown        │
   │    :sync,      │            │  - Telemetry span  │
   │    computa     │            │    em cada insert  │
   │    inline      │            │                    │
   └───────┬────────┘            └─────────┬──────────┘
           │                               │
   ┌───────▼───────────────────────────────▼──────────┐
   │            Graph Storage Layer                   │
   │                                                  │
   │  - ETS tables (adjacency lists)                  │
   │  - Segmentos temporais (GraphJet-style)          │
   │  - ID mapping (externo → interno por segmento)   │
   │  - Vertex metadata                               │
   │  - Processos registrados via Registry             │
   └──────────────────────┬───────────────────────────┘
                          │
   ┌──────────────────────▼───────────────────────────┐
   │         Computation Layer                        │
   │                                                  │
   │  - Task.Supervisor para algoritmos               │
   │  - Algorithm behaviour (padrão Oban Engine)      │
   │  - PageRank (Monte Carlo + Nx power method)      │
   │  - SALSA (Full + Subgraph)                       │
   │  - Telemetry span em cada compute                │
   │  - No modo :sync, roda no processo chamador      │
   └──────────────────────┬───────────────────────────┘
                          │
   ┌──────────────────────▼───────────────────────────┐
   │         Result Store Layer                       │
   │                                                  │
   │  - ETS para cache de resultados                  │
   │  - TTL configurável                              │
   │  - Invalidação por eventos                       │
   │  - Store behaviour (padrão Oban Engine)          │
   └──────────────────────────────────────────────────┘
                          │
   ┌──────────────────────▼───────────────────────────┐
   │         Plugin Layer                             │
   │                                                  │
   │  - Plugin behaviour (padrão Oban)                │
   │  - Plugins.Pruner → remove segmentos expirados   │
   │  - Plugins.Precomputer → pré-computa recs        │
   │  - Plugins.CacheCleaner → TTL cleanup            │
   │  - Cada plugin é GenServer supervisionado         │
   └──────────────────────────────────────────────────┘
```

---

## 5. Padrões OTP Inspirados no Oban

### 5.1 Config Struct Centralizado

O Oban cria um `Config` struct validado uma vez no `start_link` e passa para todos os processos via opção `conf:`. Isso evita `Application.get_env` espalhado e permite múltiplas instâncias com configurações diferentes.

```elixir
defmodule MeliGraph.Config do
  @moduledoc """
  Configuração centralizada, validada uma vez no start_link.
  Passada para todos os processos da supervision tree via `conf:`.
  """

  @type t :: %__MODULE__{
    name: atom(),
    graph_type: :directed | :bipartite,
    segment_max_edges: pos_integer(),
    segment_ttl: pos_integer(),
    result_ttl: pos_integer(),
    algorithms: [atom()],
    testing: :disabled | :sync,
    plugins: [{module(), keyword()}],
    registry: atom()
  }

  @enforce_keys [:name, :graph_type]
  defstruct [
    :name,
    :graph_type,
    :registry,
    segment_max_edges: 1_000_000,
    segment_ttl: :timer.hours(24),
    result_ttl: :timer.minutes(30),
    algorithms: [:pagerank, :salsa],
    testing: :disabled,
    plugins: [
      {MeliGraph.Plugins.Pruner, interval: :timer.minutes(5)},
      {MeliGraph.Plugins.CacheCleaner, interval: :timer.minutes(1)}
    ]
  ]

  def new(opts) do
    conf = struct!(__MODULE__, opts)
    validate!(conf)
    %{conf | registry: Module.concat(conf.name, Registry)}
  end

  defp validate!(%{segment_max_edges: n}) when n < 1,
    do: raise(ArgumentError, "segment_max_edges must be >= 1")
  defp validate!(%{graph_type: type}) when type not in [:directed, :bipartite],
    do: raise(ArgumentError, "graph_type must be :directed or :bipartite")
  defp validate!(%{testing: mode}) when mode not in [:disabled, :sync],
    do: raise(ArgumentError, "testing must be :disabled or :sync")
  defp validate!(conf), do: conf
end
```

### 5.2 Registry para Lookup de Processos

```elixir
defmodule MeliGraph.Registry do
  def via(conf, key) do
    {:via, Registry, {conf.registry, key}}
  end

  def whereis(conf, key) do
    case Registry.lookup(conf.registry, key) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end
end
```

### 5.3 Modos de Testing

```elixir
# config/test.exs
config :my_app, MeliGraph, testing: :sync

# No código — o Query layer respeita o modo:
defp do_recommend(%{testing: :sync} = conf, entity_id, type, opts) do
  # Computa inline, sem Task.Supervisor, sem cache
  algorithm = resolve_algorithm(opts[:algorithm] || :salsa)
  algorithm.compute(conf, entity_id, type, opts)
end

# No teste — resultado imediato, sem await:
test "recommends content" do
  conf = MeliGraph.Config.new(name: :test, graph_type: :bipartite, testing: :sync)
  assert {:ok, results} = MeliGraph.recommend(conf, "user:1", :content)
end
```

### 5.4 Plugin Behaviour

```elixir
defmodule MeliGraph.Plugin do
  @callback start_link(keyword()) :: GenServer.on_start()
  @callback validate(keyword()) :: :ok | {:error, String.t()}
end

# Implementações: Pruner, CacheCleaner, Precomputer
# Cada um é GenServer supervisionado no Plugins.Supervisor
```

### 5.5 Telemetry-First com Span

```elixir
defmodule MeliGraph.Telemetry do
  @moduledoc """
  Eventos emitidos:
    - [:meli_graph, :ingestion, :insert_edge]
    - [:meli_graph, :query, :recommend]
    - [:meli_graph, :engine, :compute]
    - [:meli_graph, :plugin, :pruner]
    - [:meli_graph, :plugin, :cache_cleaner]
  """
  def span(event_suffix, meta, fun) do
    :telemetry.span([:meli_graph | event_suffix], meta, fun)
  end
end
```

### 5.6 Graceful Shutdown no Ingestion

```elixir
# No Writer:
def init(conf) do
  Process.flag(:trap_exit, true)
  {:ok, %{conf: conf}}
end

def terminate(_reason, state) do
  drain_mailbox(state.conf)
  :ok
end

defp drain_mailbox(conf) do
  receive do
    {:"$gen_cast", {:insert_edge, s, t, e}} ->
      do_insert(conf, s, t, e)
      drain_mailbox(conf)
  after
    0 -> :ok
  end
end
```

### 5.7 Peer Behaviour (preparação Fase 3)

```elixir
defmodule MeliGraph.Peer do
  @callback leader?(conf :: MeliGraph.Config.t()) :: boolean()
end

defmodule MeliGraph.Peers.Isolated do
  @behaviour MeliGraph.Peer
  def leader?(_conf), do: true
end
```

### 5.8 Sonar — Health Check (Fase 2)

```elixir
defmodule MeliGraph.Sonar do
  # Monitora periodicamente:
  # - Tamanho da mailbox do Writer (backpressure)
  # - % de capacidade do segmento ativo
  # - Emite :telemetry com métricas
end
```

---

## 6. Design Detalhado dos Componentes

### 6.1 Graph Storage — `MeliGraph.Graph`

Inspirado no GraphJet. Grafo armazenado como listas de adjacência em **segmentos temporais**.

```elixir
defmodule MeliGraph.Graph.Segment do
  @type t :: %__MODULE__{
    id: non_neg_integer(),
    created_at: DateTime.t(),
    edge_count: non_neg_integer(),
    max_edges: non_neg_integer(),
    ltr_index: :ets.tid(),    # left-to-right
    rtl_index: :ets.tid(),    # right-to-left
    id_map: :ets.tid(),       # external ↔ internal ID
    vertex_meta: :ets.tid()
  }
end
```

**Segmentação temporal:**
```
Tempo ──────────────────────────────────────────►

 [Seg 1]     [Seg 2]     [Seg 3]     [Seg 4 ✏️]
 read-only   read-only   read-only    ativo
 (prunable via Plugin)
```

**ID Mapping** (como no GraphJet): IDs externos → inteiros compactos internos ao segmento.

**Sampling entre segmentos**: alias method ponderado pelo número de arestas por segmento.

### 6.2 Algorithm Behaviour — `MeliGraph.Algorithm`

```elixir
defmodule MeliGraph.Algorithm do
  @callback compute(
    conf :: MeliGraph.Config.t(),
    entity_id :: term(),
    type :: :content | :users | :items,
    opts :: keyword()
  ) :: {:ok, [{term(), float()}]} | {:error, term()}
end
```

#### 6.2.1 PageRank Personalizado

Baseado no paper WTF, seção 5.1 (Circle of Trust). Duas estratégias:

**Monte Carlo** — memória O(visitados), ideal para grafos grandes:
```
1. Iniciar N random walks a partir de u
2. Em cada passo: com prob α, resetar para u; senão, seguir aresta aleatória
3. Contar visitas → normalizar → top-K
```

**Power Method via Nx** — convergência rápida, ideal para subgrafos:
```
1. Materializar subgrafo como tensor Nx
2. Construir matriz de transição normalizada
3. Iterar: PR(t+1) = d * M^T * PR(t) + (1-d) * personalization
4. Converter tensor → lista de {id, score}
```

```elixir
defmodule MeliGraph.Algorithm.PageRank do
  @behaviour MeliGraph.Algorithm

  @impl true
  def compute(conf, entity_id, type, opts) do
    case Keyword.get(opts, :strategy, :monte_carlo) do
      :monte_carlo -> monte_carlo(conf, entity_id, opts)
      :power_method -> power_method(conf, entity_id, opts)
    end
  end
end
```

#### 6.2.2 SALSA

Baseado nos papers WTF (seção 5.2) e GraphJet (seção 5.1/5.2). Duas variantes:

**Full SALSA** — random walks no grafo completo:
```
1. Seed set = circle of trust do usuário (top-500 do PageRank)
2. Construir grafo bipartido: hubs(seed) ↔ authorities(followings)
3. Random walk alternando L→R e R→L, com reset para seed
4. Contar visitas: authorities → recomendações, hubs → similaridade
```

**Subgraph SALSA** — materializa subgrafo, distribui pesos iterativamente:
```
1. Materializar subgrafo bipartido pequeno
2. Pesos uniformes no seed set (soma = 1)
3. Iterar: L→R distribui peso, R→L distribui de volta
4. Convergência → rankings
```

```elixir
defmodule MeliGraph.Algorithm.SALSA do
  @behaviour MeliGraph.Algorithm

  @impl true
  def compute(conf, entity_id, type, opts) do
    # 1. Computar circle of trust via PageRank
    {:ok, cot} = MeliGraph.Algorithm.PageRank.compute(conf, entity_id, type,
      strategy: :monte_carlo, top_k: Keyword.get(opts, :seed_size, 500))

    seed_set = Enum.map(cot, fn {id, _} -> id end)

    # 2. Executar variante escolhida
    case Keyword.get(opts, :variant, :full) do
      :full -> full_salsa(conf, seed_set, opts)
      :subgraph -> subgraph_salsa(conf, seed_set, opts)
    end
  end
end
```

### 6.3 Ingestion Writer

Single-writer GenServer + graceful shutdown. Registrado via Registry.

```elixir
defmodule MeliGraph.Ingestion.Writer do
  use GenServer

  def start_link(opts) do
    conf = Keyword.fetch!(opts, :conf)
    GenServer.start_link(__MODULE__, conf, name: MeliGraph.Registry.via(conf, :writer))
  end

  def insert_edge(conf, source, target, edge_type) do
    GenServer.cast(MeliGraph.Registry.via(conf, :writer),
      {:insert_edge, source, target, edge_type})
  end

  def init(conf) do
    Process.flag(:trap_exit, true)
    {:ok, %{conf: conf}}
  end

  def handle_cast({:insert_edge, source, target, edge_type}, state) do
    MeliGraph.Telemetry.span([:ingestion, :insert_edge], %{conf: state.conf}, fn ->
      result = do_insert(state.conf, source, target, edge_type)
      {result, %{source: source, target: target, edge_type: edge_type}}
    end)
    {:noreply, state}
  end

  def terminate(_reason, state) do
    drain_mailbox(state.conf)
  end
end
```

### 6.4 Query Layer

Respeita modo de testing. Cache-first em produção, inline em `:sync`.

### 6.5 Result Store

Store behaviour (padrão Oban Engine) com implementação ETS + TTL padrão.

---

## 7. Supervision Tree

```
MeliGraph.Supervisor (name: :"#{name}.Supervisor")
│
├── Registry (name: :"#{name}.Registry")
│
├── MeliGraph.Graph.SegmentManager         # gerencia segmentos temporais
│
├── MeliGraph.Ingestion.Writer             # single-writer + trap_exit + drain
│
├── MeliGraph.Engine.Supervisor            # [SKIP no modo :sync]
│   ├── MeliGraph.Engine.Scheduler
│   └── Task.Supervisor
│
├── MeliGraph.Store.ETS                    # GenServer owner da ETS table
│
└── MeliGraph.Plugins.Supervisor           # [SKIP no modo :sync]
    ├── MeliGraph.Plugins.Pruner
    ├── MeliGraph.Plugins.CacheCleaner
    └── MeliGraph.Plugins.Precomputer
```

```elixir
defmodule MeliGraph.Supervisor do
  use Supervisor

  def init(opts) do
    conf = MeliGraph.Config.new(opts)

    children =
      [
        {Registry, keys: :unique, name: conf.registry},
        {MeliGraph.Graph.SegmentManager, conf: conf},
        {MeliGraph.Ingestion.Writer, conf: conf},
        {MeliGraph.Engine.Supervisor, conf: conf},
        {MeliGraph.Store.ETS, conf: conf},
        plugins_supervisor_spec(conf)
      ]
      |> maybe_skip_async(conf)

    Supervisor.init(children, strategy: :one_for_one)
  end

  # No modo :sync, não inicia Engine nem Plugins
  defp maybe_skip_async(children, %{testing: :sync}) do
    Enum.reject(children, fn
      {MeliGraph.Engine.Supervisor, _} -> true
      %{id: MeliGraph.Plugins.Supervisor} -> true
      _ -> false
    end)
  end
  defp maybe_skip_async(children, _conf), do: children
end
```

---

## 8. API Pública Proposta

```elixir
# Configuração — múltiplas instâncias possíveis via Registry
MeliGraph.start_link(
  name: :melivra_graph,
  graph_type: :bipartite,
  segment_max_edges: 1_000_000,
  segment_ttl: :timer.hours(24),
  result_ttl: :timer.minutes(30),
  plugins: [
    {MeliGraph.Plugins.Pruner, interval: :timer.minutes(5)},
    {MeliGraph.Plugins.CacheCleaner, interval: :timer.minutes(1)}
  ]
)

# Inserção (real-time, non-blocking)
MeliGraph.insert_edge(:melivra_graph, "user:123", "post:456", :like)

# Recomendações
{:ok, recs} = MeliGraph.recommend(:melivra_graph, "user:123", :content,
  algorithm: :salsa, variant: :subgraph, top: 20)

# Similaridade
{:ok, similar} = MeliGraph.similar(:melivra_graph, "user:123", :users, top: 10)

# Consultas no grafo
MeliGraph.neighbors(:melivra_graph, "user:123", :outgoing, type: :follow)
MeliGraph.circle_of_trust(:melivra_graph, "user:123", max_nodes: 500)
```

---

## 9. Estrutura do Projeto

```
meli_graph/
├── mix.exs
├── lib/
│   ├── meli_graph.ex                          # API pública
│   ├── meli_graph/
│   │   ├── config.ex                          # Config struct (padrão Oban)
│   │   ├── registry.ex                        # Registry helpers (padrão Oban)
│   │   ├── supervisor.ex                      # Supervision tree
│   │   ├── telemetry.ex                       # Telemetry spans (padrão Oban)
│   │   │
│   │   ├── graph/
│   │   │   ├── graph.ex                       # Behaviour para operações de grafo
│   │   │   ├── segment.ex                     # Struct + lógica de um segmento
│   │   │   ├── segment_manager.ex             # GenServer gerenciando segmentos
│   │   │   ├── id_map.ex                      # Mapeamento de IDs
│   │   │   ├── adjacency.ex                   # Operações em adjacency lists (ETS)
│   │   │   └── sampling.ex                    # Alias method + random sampling
│   │   │
│   │   ├── ingestion/
│   │   │   ├── writer.ex                      # Single-writer + trap_exit + drain
│   │   │   └── edge.ex                        # Struct para arestas
│   │   │
│   │   ├── engine/
│   │   │   ├── supervisor.ex                  # Supervisor + Task.Supervisor
│   │   │   ├── scheduler.ex                   # Agenda computações
│   │   │   └── worker.ex                      # Executa algoritmos
│   │   │
│   │   ├── algorithm/
│   │   │   ├── algorithm.ex                   # Behaviour: @callback compute/4
│   │   │   ├── pagerank.ex                    # Monte Carlo + Power Method/Nx
│   │   │   ├── salsa.ex                       # Full + Subgraph SALSA
│   │   │   └── similarity.ex                  # Cosine similarity via sampling
│   │   │
│   │   ├── query/
│   │   │   └── query.ex                       # Cache-first, respeita testing mode
│   │   │
│   │   ├── store/
│   │   │   ├── store.ex                       # Behaviour (padrão Oban Engine)
│   │   │   └── ets.ex                         # ETS + TTL
│   │   │
│   │   ├── plugins/
│   │   │   ├── plugin.ex                      # Plugin behaviour (padrão Oban)
│   │   │   ├── pruner.ex                      # Remove segmentos expirados
│   │   │   ├── cache_cleaner.ex               # TTL cleanup
│   │   │   └── precomputer.ex                 # Pré-computa recs
│   │   │
│   │   ├── peer/
│   │   │   ├── peer.ex                        # Peer behaviour (Fase 3)
│   │   │   └── isolated.ex                    # Single-node: sempre leader
│   │   │
│   │   └── sonar.ex                           # Health check (Fase 2)
│   │
│   └── nx_utils.ex                            # Helpers Nx
│
├── test/
│   ├── meli_graph_test.exs
│   ├── support/test_helper.ex                 # Setup com testing: :sync
│   ├── graph/
│   ├── algorithm/
│   └── integration/
│
└── benchmarks/
    └── graph_bench.exs
```

---

## 10. Decisões Técnicas Justificadas

### 10.1 ETS para Adjacency Lists

ETS com `read_concurrency: true` oferece leitura concorrente sem locks, ideal para single-writer/multi-reader. Trade-off: para >100M arestas, considerar NIFs. Para o escopo inicial (~10M), ETS é suficiente.

### 10.2 Monte Carlo vs. Power Method

| Aspecto | Monte Carlo | Power Method (Nx) |
|---------|-------------|-------------------|
| Memória | O(visitados) | O(V²) densa, O(E) esparsa |
| Velocidade | Mais lento em grafos pequenos | Convergência rápida, GPU-friendly |
| Uso | Circle of Trust (grafos grandes) | Subgrafos pequenos no SALSA |

Implementar ambos. Monte Carlo como padrão.

### 10.3 Config Struct vs. Application.get_env

`Application.get_env` é global e não suporta múltiplas instâncias. Config struct é local, validado, passado via `conf:`. Padrão Oban.

### 10.4 Registry vs. Nomes Hardcoded

Nomes hardcoded impossibilitam múltiplas instâncias. Registry isola namespaces. Custo zero agora, evita refatoração futura. Padrão Oban.

### 10.5 Single-Writer + Graceful Shutdown

Padrão GraphJet (single writer) + Oban (trap_exit + drain). Mailbox do GenServer = fila de ingestão.

### 10.6 Plugins como GenServers Supervisionados

Pruner, CacheCleaner, Precomputer são opcionais, configuráveis e testáveis isoladamente. Desabilitados no modo `:sync`. Padrão Oban.

---

## 11. Roadmap de Implementação

### Fase 1 — Foundation (TCC)
- [ ] Config struct centralizado com validação
- [ ] Registry para lookup de processos
- [ ] Modos de testing (`:sync` e `:disabled`)
- [ ] Graph storage com ETS (directed + bipartite)
- [ ] Segmentação temporal + ID mapping
- [ ] Single-writer ingestion com graceful shutdown
- [ ] Algorithm behaviour genérico
- [ ] PageRank personalizado (Monte Carlo)
- [ ] SALSA (Full + Subgraph)
- [ ] Store behaviour + ETS store com TTL
- [ ] Query layer (respeita testing mode)
- [ ] Plugin behaviour + Pruner + CacheCleaner
- [ ] Telemetry spans em operações críticas
- [ ] Testes (modo `:sync`) + benchmarks

### Fase 2 — Refinamento
- [ ] Similarity queries (cosine via sampling)
- [ ] PageRank via Nx power method
- [ ] Sonar (health check do Writer)
- [ ] Plugins.Precomputer
- [ ] Peer behaviour (Peers.Isolated)
- [ ] HexDocs + publicação Hex.pm

### Fase 3 — Distribuído
- [ ] Peers.Global (eleição de líder via `:global`)
- [ ] Distribuição via Erlang distribution
- [ ] Particionamento do grafo entre nós
- [ ] GenStage/Broadway para streaming ingestion
- [ ] Pesos nas arestas
- [ ] Algoritmos adicionais (Node2Vec, GNN via Nx)

---

## 12. Exemplo de Uso no Melivra

```elixir
# Application
defmodule Melivra.Application do
  def start(_type, _args) do
    children = [
      {MeliGraph, name: :follows, graph_type: :directed,
        segment_ttl: :timer.hours(168)},
      {MeliGraph, name: :interactions, graph_type: :bipartite,
        segment_ttl: :timer.hours(24)},
      MelivraWeb.Endpoint
    ]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end

# Eventos
def handle_event(:follow, %{follower: f, followed: d}) do
  MeliGraph.insert_edge(:follows, f, d, :follow)
end

def handle_event(:like, %{user_id: u, post_id: p}) do
  MeliGraph.insert_edge(:interactions, u, p, :like)
end

# Feed
def get_recommended_posts(user_id) do
  {:ok, recs} = MeliGraph.recommend(:interactions, user_id, :content,
    algorithm: :salsa, variant: :subgraph, top: 50)
  post_ids = Enum.map(recs, fn {id, _} -> id end)
  Posts.get_many(post_ids)
end

# Who to Follow
def get_who_to_follow(user_id) do
  {:ok, recs} = MeliGraph.recommend(:follows, user_id, :users,
    algorithm: :salsa, top: 20)
  user_ids = Enum.map(recs, fn {id, _} -> id end)
  Users.get_many(user_ids)
end

# Testes — tudo síncrono
defmodule Melivra.RecommendationTest do
  use ExUnit.Case

  setup do
    {:ok, _} = MeliGraph.start_link(name: :test, graph_type: :bipartite, testing: :sync)
    :ok
  end

  test "recommends posts based on interactions" do
    MeliGraph.insert_edge(:test, "user:1", "post:a", :like)
    MeliGraph.insert_edge(:test, "user:2", "post:a", :like)
    MeliGraph.insert_edge(:test, "user:2", "post:b", :like)

    assert {:ok, recs} = MeliGraph.recommend(:test, "user:1", :content)
    assert Enum.any?(recs, fn {id, _} -> id == "post:b" end)
  end
end
```

---

## 13. Referências

### Algoritmos e Sistemas
1. **WTF Paper** — Gupta et al., WWW 2013. Cassovary, SALSA, circle of trust.
2. **GraphJet Paper** — Sharma et al., VLDB 2016. Real-time, segmentação temporal, edge pools.
3. **SALSA** — Lempel & Moran, ACM TOIS 2001. Random walks em grafos bipartidos.
4. **Personalized PageRank** — Fogaras et al., Internet Mathematics 2005.
5. **PageRank** — Page et al., Stanford 1999.

