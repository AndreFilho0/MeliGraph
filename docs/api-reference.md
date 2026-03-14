# API Reference

## Inicialização

### `MeliGraph.start_link(opts)`

Inicia uma instância do MeliGraph.

```elixir
{:ok, pid} = MeliGraph.start_link(
  name: :my_graph,
  graph_type: :bipartite,
  testing: :sync
)
```

#### Opções

| Opção | Tipo | Obrigatório | Padrão | Descrição |
|-------|------|-------------|--------|-----------|
| `name` | `atom()` | Sim | — | Nome da instância |
| `graph_type` | `:directed \| :bipartite` | Sim | — | Tipo do grafo |
| `segment_max_edges` | `pos_integer()` | Não | 1.000.000 | Máximo de arestas por segmento |
| `segment_ttl` | `pos_integer()` | Não | 24h (ms) | TTL dos segmentos |
| `result_ttl` | `pos_integer()` | Não | 30min (ms) | TTL do cache de resultados |
| `algorithms` | `[atom()]` | Não | `[:pagerank, :salsa]` | Algoritmos habilitados |
| `testing` | `:disabled \| :sync` | Não | `:disabled` | Modo de testing |
| `plugins` | `[{module, keyword}]` | Não | Pruner + CacheCleaner | Plugins ativos |

### `MeliGraph.child_spec(opts)`

Retorna um child spec para uso em supervision trees:

```elixir
children = [
  {MeliGraph, name: :follows, graph_type: :directed},
  {MeliGraph, name: :interactions, graph_type: :bipartite}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

## Inserção

### `MeliGraph.insert_edge(name, source, target, edge_type)`

Insere uma aresta no grafo.

```elixir
MeliGraph.insert_edge(:my_graph, "user:1", "post:a", :like)
MeliGraph.insert_edge(:my_graph, "user:1", "user:2", :follow)
```

- **Modo `:sync`**: síncrono, retorna `:ok` após inserção
- **Modo `:disabled`**: assíncrono (cast), retorna `:ok` imediatamente

IDs podem ser qualquer termo Erlang (strings, inteiros, tuplas, etc.).

## Consultas

### `MeliGraph.recommend(name, entity_id, type, opts \\ [])`

Retorna top-N recomendações para um vértice.

```elixir
{:ok, recs} = MeliGraph.recommend(:my_graph, "user:1", :content,
  algorithm: :pagerank,
  num_walks: 1000,
  top_k: 20
)
# => {:ok, [{"post:x", 0.15}, {"post:y", 0.12}, ...]}
```

#### Opções

| Opção | Tipo | Padrão | Descrição |
|-------|------|--------|-----------|
| `algorithm` | `:pagerank \| :salsa \| module()` | `:pagerank` | Algoritmo a usar |
| `top_k` | `pos_integer()` | depende do algoritmo | Número de resultados |

Opções adicionais são repassadas ao algoritmo (ver [Algoritmos](algorithms.md)).

#### Retorno

```elixir
{:ok, [{external_id, score}]}  # Lista ordenada por score decrescente
{:ok, []}                      # Vértice não encontrado ou sem vizinhos
{:error, reason}               # Erro na computação
```

### `MeliGraph.neighbors(name, entity_id, direction, opts \\ [])`

Retorna os vizinhos de um vértice.

```elixir
# Todos os vizinhos de saída
MeliGraph.neighbors(:my_graph, "user:1", :outgoing)
# => ["post:a", "post:b", "user:2"]

# Filtrado por tipo de aresta
MeliGraph.neighbors(:my_graph, "user:1", :outgoing, type: :like)
# => ["post:a", "post:b"]

# Vizinhos de entrada
MeliGraph.neighbors(:my_graph, "post:a", :incoming)
# => ["user:1", "user:2"]
```

#### Parâmetros

| Parâmetro | Tipo | Descrição |
|-----------|------|-----------|
| `direction` | `:outgoing \| :incoming` | Direção das arestas |
| `type` (opt) | `atom()` | Filtrar por tipo de aresta |

## Métricas

### `MeliGraph.edge_count(name)`

Retorna o número total de arestas no grafo.

```elixir
MeliGraph.edge_count(:my_graph)
# => 42
```

### `MeliGraph.vertex_count(name)`

Retorna o número total de vértices mapeados.

```elixir
MeliGraph.vertex_count(:my_graph)
# => 15
```

## Múltiplas Instâncias

Cada instância é completamente isolada via Registry:

```elixir
# Grafo social (quem segue quem)
MeliGraph.start_link(name: :follows, graph_type: :directed,
  segment_ttl: :timer.hours(168))

# Grafo de interações (usuário ↔ conteúdo)
MeliGraph.start_link(name: :interactions, graph_type: :bipartite,
  segment_ttl: :timer.hours(24))

# Operações são isoladas
MeliGraph.insert_edge(:follows, "u1", "u2", :follow)
MeliGraph.insert_edge(:interactions, "u1", "p1", :like)

MeliGraph.edge_count(:follows)       # => 1
MeliGraph.edge_count(:interactions)  # => 1
```

## Exemplo Completo

```elixir
# 1. Iniciar
{:ok, _} = MeliGraph.start_link(
  name: :recs,
  graph_type: :bipartite,
  testing: :sync
)

# 2. Alimentar o grafo
MeliGraph.insert_edge(:recs, "user:1", "post:a", :like)
MeliGraph.insert_edge(:recs, "user:1", "post:b", :like)
MeliGraph.insert_edge(:recs, "user:2", "post:a", :like)
MeliGraph.insert_edge(:recs, "user:2", "post:c", :like)
MeliGraph.insert_edge(:recs, "user:3", "post:b", :like)
MeliGraph.insert_edge(:recs, "user:3", "post:c", :like)
MeliGraph.insert_edge(:recs, "user:3", "post:d", :like)

# 3. Consultar
{:ok, recs} = MeliGraph.recommend(:recs, "user:1", :content,
  algorithm: :salsa, seed_size: 10, top_k: 5)

IO.inspect(recs, label: "Recomendações para user:1")

# 4. Explorar o grafo
neighbors = MeliGraph.neighbors(:recs, "user:1", :outgoing)
IO.inspect(neighbors, label: "Posts que user:1 curtiu")

# 5. Métricas
IO.puts("Arestas: #{MeliGraph.edge_count(:recs)}")
IO.puts("Vértices: #{MeliGraph.vertex_count(:recs)}")
```
