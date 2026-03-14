# Testing

## Modo `:sync`

MeliGraph inclui um modo de testing que torna todas as operações síncronas e determinísticas, seguindo o padrão do Oban.

```elixir
MeliGraph.start_link(name: :test, graph_type: :bipartite, testing: :sync)
```

### O que muda no modo `:sync`

| Componente | `:disabled` (produção) | `:sync` (teste) |
|-----------|----------------------|-----------------|
| Writer | `GenServer.cast` (async) | `GenServer.call` (sync) |
| Query | Cache-first → compute se miss | Computa inline, sem cache |
| Plugins | Ativos (Pruner, CacheCleaner) | Não iniciados |

### Benefícios

- **Determinístico**: inserção completa antes do assert
- **Rápido**: sem processos background, sem timers
- **Isolado**: sem estado compartilhado entre testes

## Escrevendo Testes

### Setup com instância única por teste

```elixir
defmodule MyApp.RecommendationTest do
  use ExUnit.Case, async: false

  setup do
    name = :"test_#{System.unique_integer([:positive, :monotonic])}"

    {:ok, _} = MeliGraph.start_link(
      name: name,
      graph_type: :bipartite,
      testing: :sync,
      segment_max_edges: 100
    )

    %{name: name}
  end

  test "recommends posts based on interactions", %{name: name} do
    MeliGraph.insert_edge(name, "user:1", "post:a", :like)
    MeliGraph.insert_edge(name, "user:2", "post:a", :like)
    MeliGraph.insert_edge(name, "user:2", "post:b", :like)

    {:ok, recs} = MeliGraph.recommend(name, "user:1", :content,
      algorithm: :salsa, seed_size: 5, top_k: 5)

    assert is_list(recs)
  end
end
```

### Usando o TestHelpers do MeliGraph

O projeto inclui helpers em `test/support/graph_helpers.ex`:

```elixir
import MeliGraph.TestHelpers

# Gera nome único
name = unique_name()

# Inicia instância com defaults para teste
name = start_test_instance(graph_type: :directed)
```

### Testando algoritmos isoladamente

```elixir
test "PageRank returns ranked results" do
  name = start_test_instance(graph_type: :directed)
  conf = get_conf(name)

  # Montar grafo
  MeliGraph.insert_edge(name, "A", "B", :follow)
  MeliGraph.insert_edge(name, "B", "C", :follow)
  MeliGraph.insert_edge(name, "C", "A", :follow)

  # Chamar algoritmo diretamente
  entity_id = MeliGraph.Graph.IdMap.get_internal(conf, "A")

  {:ok, results} = MeliGraph.Algorithm.PageRank.compute(
    conf, entity_id, :users,
    num_walks: 500, top_k: 5
  )

  assert length(results) > 0

  # Verificar que scores são normalizados
  total = Enum.reduce(results, 0.0, fn {_, s}, acc -> acc + s end)
  assert_in_delta total, 1.0, 0.01
end
```

### Testando com telemetry

```elixir
test "emits telemetry on insert" do
  name = start_test_instance()
  test_pid = self()
  ref = make_ref()

  :telemetry.attach(
    "test-#{inspect(ref)}",
    [:meli_graph, :ingestion, :insert_edge, :stop],
    fn _event, measurements, _meta, _config ->
      send(test_pid, {:telemetry, measurements})
    end,
    nil
  )

  MeliGraph.insert_edge(name, "u1", "p1", :like)

  assert_receive {:telemetry, %{duration: duration}}
  assert is_integer(duration)

  :telemetry.detach("test-#{inspect(ref)}")
end
```

## async: false

Os testes do MeliGraph usam `async: false` porque:

1. **ETS tables nomeadas**: tabelas com nomes derivados do nome da instância podem colidir se dois testes usam o mesmo nome
2. **Registry global**: o Elixir Registry é global ao node

O uso de `unique_name()` mitiga colisões, mas `async: false` é mais seguro para testes que manipulam estado global.

## Cobertura de Testes (v0.1)

| Módulo | Testes | Cobertura |
|--------|--------|-----------|
| Config | 9 | Validação de todos os campos |
| Registry | 3 | via/2, whereis/2 |
| Telemetry | 1 | span emite start/stop |
| Graph.Segment | 11 | CRUD, filtros, capacidade |
| Graph.IdMap | 7 | Mapeamento bidirecional |
| Graph.SegmentManager | 7 | Inserção, rotação, pruning |
| Ingestion.Writer | 3 | Sync insert, tipos de aresta |
| Store.ETS | 6 | CRUD, TTL, cleanup |
| Algorithm.PageRank | 4 | Ranking, normalização, isolados |
| Algorithm.SALSA | 3 | Recomendação, formato, empty |
| Query | 2 | Cache, entidade desconhecida |
| Plugins.Pruner | 3 | Validação |
| Plugins.CacheCleaner | 2 | Validação |
| MeliGraph (integração) | 14 | API pública end-to-end |
| **Total** | **75** | |
