# Estruturas de Dados

Decisões sobre cada estrutura de dados usada no MeliGraph, com justificativas e trade-offs.

## 1. ETS `:bag` — Listas de Adjacência

**Onde**: `MeliGraph.Graph.Segment` (tabelas `ltr` e `rtl`)

**Estrutura**: Cada aresta é uma tupla independente na tabela ETS.

```
Tabela ltr (left-to-right):
  {0, 1, :like}     ← vértice 0 → vértice 1, tipo :like
  {0, 2, :follow}   ← vértice 0 → vértice 2, tipo :follow
  {1, 3, :like}     ← vértice 1 → vértice 3, tipo :like

Tabela rtl (right-to-left):
  {1, 0, :like}     ← vértice 1 ← vértice 0, tipo :like
  {2, 0, :follow}   ← vértice 2 ← vértice 0, tipo :follow
  {3, 1, :like}     ← vértice 3 ← vértice 1, tipo :like
```

### Por que ETS?

| Alternativa | Problema |
|-------------|----------|
| `Map` no estado do GenServer | Toda leitura passa pelo GenServer — gargalo de concorrência |
| `:persistent_term` | Otimizado para leitura rara de escrita; cada update copia tudo |
| NIF (Rust/C) | Complexidade de manutenção; desnecessário para <10M arestas |
| Mnesia | Overhead de transação; não oferece vantagem para dados in-memory puros |

ETS com `read_concurrency: true` permite leitura paralela de qualquer processo sem lock. A escrita é serializada pelo Writer (single-writer), então não há race conditions.

### Por que `:bag` e não `:set`?

Com `:set`, a modelagem seria `{source, [{target, type}, ...]}` — uma lista dentro de uma tupla. O problema:

1. **Cópia na leitura**: ETS copia o valor inteiro para o heap do processo leitor. Um vértice com 10.000 vizinhos copia uma lista de 10.000 tuplas a cada lookup.
2. **Escrita atômica**: adicionar um vizinho exige ler a lista, appendar, e reescrever — operação O(n) e não-atômica sem lock.

Com `:bag`, cada aresta é uma entrada independente:
- Leitura: `ets.lookup(table, source)` retorna só as tuplas daquele vértice
- Escrita: `ets.insert(table, {source, target, type})` é O(1) e atômico
- Filtro: `ets.match(table, {source, :"$1", :like})` filtra no ETS, sem copiar tudo

### Por que duas tabelas (ltr + rtl)?

Grafos dirigidos e bipartidos precisam de consultas em ambas as direções:

- `ltr` (left-to-right): "quem o user:1 segue?" → `ets.lookup(ltr, user_1_id)`
- `rtl` (right-to-left): "quem segue o user:1?" → `ets.lookup(rtl, user_1_id)`

A alternativa seria uma única tabela com scan, mas ETS não tem índices secundários — scan é O(n) no total de arestas. Duas tabelas dão O(k) onde k é o grau do vértice.

**Trade-off**: dobra o uso de memória por segmento. Aceitável porque ETS armazena tuplas de inteiros compactos (poucos bytes por aresta).

### Configuração

```elixir
:ets.new(:ltr, [
  :bag,              # múltiplas entradas por chave
  :public,           # qualquer processo pode ler (multi-reader)
  read_concurrency: true  # otimiza leituras paralelas via read-locks
])
```

## 2. ETS `:set` — ID Mapping

**Onde**: `MeliGraph.Graph.IdMap` (tabelas `forward` e `reverse`)

**Estrutura**: Mapeamento bidirecional 1:1 entre IDs externos e internos.

```
Forward (externo → interno):
  {"user:123", 0}
  {"post:456", 1}
  {"user:789", 2}

Reverse (interno → externo):
  {0, "user:123"}
  {1, "post:456"}
  {2, "user:789"}
```

### Por que IDs internos inteiros?

IDs externos podem ser qualquer termo Erlang (strings, UUIDs, tuplas). Usar diretamente como chaves no grafo teria dois problemas:

1. **Memória**: strings são ~40 bytes mínimo no BEAM; inteiros small (<< 2^60) são imediatos e ocupam 0 bytes extra no heap
2. **Comparação**: comparar inteiros é O(1); comparar strings é O(n) no comprimento

Com 10M de arestas onde cada aresta referencia 2 vértices, a economia é significativa.

### Por que `:set` e não `:bag`?

O mapeamento é 1:1 — cada ID externo tem exatamente um ID interno. `:set` garante unicidade da chave e tem lookup O(1) amortizado por hash table.

### Por que duas tabelas?

- **Forward** (`external → internal`): usado na escrita (inserção de arestas) e início de consultas
- **Reverse** (`internal → external`): usado no retorno de resultados (converter scores de IDs internos para externos)

Sem a tabela reverse, seria necessário scanear a tabela forward para encontrar o ID externo dado um interno — O(n) no total de vértices. Do modo com foi feito ficou O (1)

### Tabelas `:named_table` e `:public`

```elixir
:ets.new(:"#{name}.IdMap.forward", [
  :set,
  :named_table,          # acessível por nome (sem referência)
  :public,               # leitura direta de qualquer processo
  read_concurrency: true
])
```

`:named_table` permite que o `IdMap.get_internal/2` e `IdMap.get_external/2` leiam diretamente da ETS sem passar pelo GenServer — essencial para performance dos algoritmos que fazem milhares de lookups.

## 3. `:atomics` — Counter de IDs

**Onde**: `MeliGraph.Graph.IdMap` (geração de IDs internos sequenciais)

**Estrutura**: Array atômico com um único elemento (o próximo ID).

```elixir
counter = :atomics.new(1, signed: false)
# Gerar próximo ID:
new_id = :atomics.add_get(counter, 1, 1) - 1
# => 0, 1, 2, 3, ...
```

### Por que `:atomics` e não um counter no GenServer?

| Aspecto | GenServer counter | `:atomics` |
|---------|-------------------|------------|
| Overhead | Mensagem + context switch por ID | Instrução atômica nativa (CAS) |
| Throughput | ~100K ops/s | ~10M ops/s |
| Complexidade | Nenhuma | Mínima |

Na prática, o IdMap já serializa `get_or_create` via GenServer (para garantir atomicidade do check-then-insert). O `:atomics` evita uma mensagem extra para incrementar o counter quando o GenServer decide criar um novo mapping.

## 4. ETS `:set` — Cache de Resultados

**Onde**: `MeliGraph.Store.ETS`

**Estrutura**: Cada entrada é uma tabela hash `{key, value, expires_at}`. 

```
{:recommend, "user:1", :content, :pagerank}  →  [{"post:a", 0.8}, ...]  expires: 1710432000
{:recommend, "user:2", :users, :salsa}       →  [{"user:5", 0.6}, ...]  expires: 1710433000
```

### Por que ETS e não `Agent` ou `GenServer`?

O cache é lido por múltiplos processos (cada request de recomendação). Com `Agent`/`GenServer`, toda leitura seria serializada. ETS `:public` com `read_concurrency: true` permite leituras paralelas sem lock.

### Por que TTL via `expires_at` e não Process timer?

Armazenar `expires_at` na própria entrada permite:

1. **Invalidação lazy**: na leitura, verifica se expirou. Se sim, deleta e retorna `:miss`
2. **Cleanup em batch**: o `CacheCleaner` usa `ets.select/2` com match spec para encontrar todas as entradas expiradas de uma vez
3. **Sem overhead de timers**: não cria um timer por entrada (que não escala para milhares de entradas)

```elixir
# Match spec: seleciona chaves onde expires_at <= now
match_spec = [{{:"$1", :_, :"$2"}, [{:"=<", :"$2", now}], [:"$1"]}]
expired_keys = :ets.select(table, match_spec)
```

## 5. `%Config{}` Struct — Configuração

**Onde**: `MeliGraph.Config`

**Estrutura**: Struct Elixir imutável com campos validados.

```elixir
%MeliGraph.Config{
  name: :my_graph,
  graph_type: :bipartite,
  registry: :"Elixir.my_graph.Registry",
  segment_max_edges: 1_000_000,
  segment_ttl: 86_400_000,
  result_ttl: 1_800_000,
  algorithms: [:pagerank, :salsa],
  testing: :disabled,
  plugins: [{MeliGraph.Plugins.Pruner, [interval: 300_000]}, ...]
}
```

### Por que struct e não `Application.get_env`?

| Aspecto | `Application.get_env` | Config struct |
|---------|----------------------|---------------|
| Múltiplas instâncias | Não suporta (global) | Cada instância tem seu struct |
| Validação | Manual, espalhada | Centralizada no `Config.new/1` |
| Testabilidade | Exige setup global | Passa como argumento |
| Imutabilidade | Mutável a qualquer momento | Imutável após criação |

## 6. `MapSet` — Conjuntos no SALSA

**Onde**: `MeliGraph.Algorithm.SALSA` (seed set, authority set)

**Estrutura**: Conjunto de IDs internos (inteiros).

```elixir
seed_set = MapSet.new([0, 1, 2, 5, 8])      # Circle of Trust
authority_set = MapSet.new([10, 11, 12, 15])  # Itens alcançados
```

### Por que `MapSet`?

O SALSA precisa de:
- Verificação de pertencimento: "este nó está no seed set?" → `MapSet.member?/2` é O(1)
- Iteração: "para cada hub no seed set..." → `Enum.reduce/3` sobre MapSet
- Exclusão: "retornar authorities que NÃO estão no seed set" → `MapSet.member?/2`

Alternativas:
- Lista: membership check é O(n) — inaceitável para seed sets de 500 nós
- Map: funciona, mas MapSet expressa melhor a semântica (conjunto sem valores)

## 7. `Map` — Pesos e Contagens

**Onde**: `MeliGraph.Algorithm.PageRank` (visit counts), `MeliGraph.Algorithm.SALSA` (hub/authority weights)

**Estrutura**: Map de ID → valor numérico.

```elixir
# PageRank: contagem de visitas
%{0 => 150, 1 => 89, 2 => 234, 5 => 12}

# SALSA: pesos das authorities
%{10 => 0.35, 11 => 0.28, 12 => 0.22, 15 => 0.15}
```

### Por que `Map` e não ETS?

Os pesos e contagens são:
- **Locais**: usados dentro de uma única chamada de função, não compartilhados entre processos
- **Efêmeros**: descartados após o cálculo
- **Pequenos**: tipicamente centenas a milhares de entradas

Maps do Erlang usam HAMT (Hash Array Mapped Trie) com complexidade O(log32 n) para get/put — eficiente para esses tamanhos. ETS adicionaria overhead de cópia entre heaps sem benefício.

## Resumo

| Estrutura | Módulo | Tipo | Motivo principal |
|-----------|--------|------|-----------------|
| ETS `:bag` | Segment (ltr/rtl) | Adjacência | Multi-reader sem lock, inserção O(1), sem cópia de listas |
| ETS `:set` | IdMap (forward/reverse) | ID mapping | Lookup O(1), leitura direta sem GenServer |
| `:atomics` | IdMap | Counter | Incremento atômico nativo, sem overhead de mensagem |
| ETS `:set` | Store.ETS | Cache | Leitura paralela, TTL via match spec |
| Struct | Config | Configuração | Imutável, validado, múltiplas instâncias |
| MapSet | SALSA | Conjuntos | Membership O(1) para seed/authority sets |
| Map | PageRank/SALSA | Pesos | Local, efêmero, sem necessidade de compartilhamento |
| Elixir Registry | Registry | Process lookup | Namespace isolado por instância, built-in no OTP |
