# Algoritmos

## Algorithm Behaviour

Todos os algoritmos implementam o behaviour `MeliGraph.Algorithm`:

```elixir
@callback compute(
  conf :: Config.t(),
  entity_id :: non_neg_integer(),
  type :: atom(),
  opts :: keyword()
) :: {:ok, [{term(), float()}]} | {:error, term()}
```

O retorno é uma lista de `{external_id, score}` ordenada por score decrescente. Novos algoritmos podem ser adicionados implementando este behaviour e passando o módulo na opção `:algorithm`.

## PageRank Personalizado (Monte Carlo)

Baseado no paper WTF (Gupta et al., WWW 2013), seção 5.1.

### Conceito

O PageRank Personalizado computa a importância relativa de cada nó **do ponto de vista de um nó semente**. Diferente do PageRank global, que mede importância absoluta, o personalizado responde: "quais nós são mais relevantes para este usuário específico?"

### Algoritmo

```
Para cada um dos N random walks:
  1. Começar no nó semente
  2. Em cada passo:
     a. Com probabilidade α (reset_prob), voltar ao nó semente
     b. Caso contrário, seguir uma aresta aleatória de saída
     c. Se o nó não tem vizinhos, voltar ao nó semente
  3. Registrar cada nó visitado
  4. Repetir por walk_length passos

Resultado: contar visitas por nó → normalizar → top-K
```

### Parâmetros

| Parâmetro | Padrão | Descrição |
|-----------|--------|-----------|
| `num_walks` | 1.000 | Número de random walks. Mais walks = resultado mais estável |
| `walk_length` | 10 | Passos por walk. Mais passos = alcança nós mais distantes |
| `reset_prob` | 0.15 | Probabilidade de teleport para o nó semente. Maior = mais personalizado |
| `top_k` | 100 | Número de resultados retornados |

### Complexidade

- **Tempo**: O(num_walks × walk_length)
- **Memória**: O(nós visitados) — não materializa o grafo inteiro

### Exemplo: Circle of Trust

Para um grafo social com 10M de arestas, o PageRank personalizado com 1000 walks de comprimento 10 computa o "Circle of Trust" (os ~500 nós mais próximos) em tempo sublinear, sem precisar carregar o grafo inteiro na computação.

## SALSA (Stochastic Approach for Link-Structure Analysis)

Baseado nos papers WTF (seção 5.2) e GraphJet (seção 5.1/5.2).

### Conceito

SALSA opera sobre grafos bipartidos (hubs ↔ authorities). No contexto de recomendação:
- **Hubs** = usuários no seed set (Circle of Trust)
- **Authorities** = itens que os hubs interagiram

O algoritmo distribui pesos iterativamente entre hubs e authorities, amplificando itens que são populares entre os hubs do seed set.

### Algoritmo (Subgraph SALSA)

```
1. Computar Circle of Trust via PageRank (seed set)
2. Para cada hub no seed set:
   - Coletar todos os vizinhos de saída (authorities)
3. Distribuir pesos uniformes nos hubs (soma = 1.0)
4. Para cada iteração:
   a. L→R: cada hub distribui seu peso igualmente entre suas authorities
   b. R→L: cada authority distribui seu peso igualmente entre seus hubs
5. Resultado: authorities rankeadas pelo peso final (excluindo seed set)
```

### Parâmetros

| Parâmetro | Padrão | Descrição |
|-----------|--------|-----------|
| `seed_size` | 100 | Tamanho do Circle of Trust (PageRank) |
| `iterations` | 5 | Iterações de distribuição de peso |
| `top_k` | 20 | Número de resultados retornados |

### Fluxo de Dados

```
Usuário U
    │
    ▼
PageRank(U, top_k=seed_size)
    │
    ▼
Seed Set: {U1, U2, ..., Un}     ← Circle of Trust
    │
    ▼
Subgrafo bipartido:
    U1 ── item_a, item_b
    U2 ── item_a, item_c        ← authorities
    U3 ── item_b, item_d
    │
    ▼
SALSA iterations (L→R, R→L)
    │
    ▼
Rankings: item_c: 0.35, item_d: 0.28, ...
```

### Quando usar cada algoritmo

| Cenário | Algoritmo | Por quê |
|---------|-----------|---------|
| "Who to Follow" | PageRank | Encontra nós influentes na vizinhança do usuário |
| "Posts para você" | SALSA | Explora o grafo bipartido user↔content via Circle of Trust |
| "Itens similares" | PageRank (no item) | Vizinhança do item revela itens co-consumidos |

## Extensibilidade

Para adicionar um novo algoritmo:

```elixir
defmodule MyApp.Algorithm.Custom do
  @behaviour MeliGraph.Algorithm

  @impl true
  def compute(conf, entity_id, type, opts) do
    # Sua implementação aqui
    {:ok, [{external_id, score}]}
  end
end

# Uso
MeliGraph.recommend(:my_graph, "user:1", :content,
  algorithm: MyApp.Algorithm.Custom)
```

## Referências

1. **WTF Paper** — Gupta et al., "WTF: The Who to Follow Service at Twitter", WWW 2013
2. **GraphJet Paper** — Sharma et al., "GraphJet: Real-Time Content Recommendations at Twitter", VLDB 2016
3. **SALSA** — Lempel & Moran, "SALSA: The Stochastic Approach for Link-Structure Analysis", ACM TOIS 2001
4. **Personalized PageRank** — Fogaras et al., "Towards Scaling Fully Personalized PageRank", Internet Mathematics 2005
5. **PageRank** — Page et al., "The PageRank Citation Ranking", Stanford 1999
