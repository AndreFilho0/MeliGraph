# LightGCN — Plano de Implementação v0.2

Referência técnica para a implementação do LightGCN no MeliGraph.

Baseado no paper: *He et al., "LightGCN: Simplifying and Powering Graph Convolution Network for Recommendation", SIGIR 2020*.

---

## 1. O que é o LightGCN e por que encaixa no MeliGraph

O LightGCN é um modelo de filtragem colaborativa que aprende embeddings de usuários e itens propagando-os **linearmente** pelo grafo bipartido user↔item. Ele remove tudo que o paper mostra ser desnecessário para recomendação — transformação de features, ativação não-linear, self-connection — e mantém apenas a **agregação de vizinhos normalizada** + **soma ponderada de camadas**.

O MeliGraph já opera sobre grafos bipartidos com SALSA e PageRank (algoritmos baseados em estrutura). O LightGCN adiciona uma camada de **embeddings aprendidos** que captura similaridade latente — o passo natural para ir de "recomendação baseada em grafo" para "recomendação baseada em representação vetorial".

**Fórmula central (Light Graph Convolution):**

```
e_u^(k+1) = Σ_{i ∈ N_u}  (1 / √|N_u| · √|N_i|) · e_i^(k)
e_i^(k+1) = Σ_{u ∈ N_i}  (1 / √|N_i| · √|N_u|) · e_u^(k)
```

**Embedding final (Layer Combination):**

```
e_u = (1/K+1) · Σ_{k=0}^{K} e_u^(k)
```

**Predição:**

```
score(u, i) = e_u^T · e_i
```

**Em forma matricial:**

```
Ã = D^(-1/2) · A · D^(-1/2)     (normalização simétrica)

E^(k+1) = Ã · E^(k)

E_final = (1/K+1) · Σ_{k=0}^{K} Ã^k · E^(0)
```

---

## 2. Princípios do Paper que Guiam a Implementação

| Decisão | Valor do paper | Por que |
|---------|---------------|---------|
| Embedding dim | 64 | Padrão em todos os experimentos |
| Camadas (K) | 3 | Melhor trade-off; 4 camadas ainda melhora mas os retornos diminuem |
| α_k | 1/(K+1) uniforme | Aprender α não traz melhora significativa |
| Normalização | sqrt simétrica em ambos os lados | Remover qualquer lado degrada muito |
| Self-connection | **Não tem** | A layer combination já subsume esse efeito |
| Feature transformation | **Não tem** | Impõe efeito negativo no CF (IDs sem semântica) |
| Ativação não-linear | **Não tem** | Adicionar piora a convergência |
| Dropout | **Não tem** | L2 nos embeddings é suficiente |
| Regularização L2 λ | 1e-4 | Ótimo na maioria dos datasets |
| Épocas | ~1000 | Suficiente para convergir |
| Batch size | 1024 | Padrão Adam |
| Inicialização | Xavier | Distribuição uniforme escalada |
| Otimizador | Adam | lr=0.001 |

**O modelo é tão simples quanto Matrix Factorization** em número de parâmetros: os únicos parâmetros treináveis são `E^(0)`, o embedding da camada 0. Tudo mais é derivado via propagação.

---

## 3. Separação de Responsabilidades: Lib vs Aplicação

A lib **não conhece** Postgres, R2, S3 ou qualquer mecanismo de persistência. Ela apenas produz e consome `binary`.

```
┌─────────────────────────────────────────────────────────────────┐
│                     MeliGraph (lib)                             │
│                                                                 │
│  train_embeddings(name, opts) → {:ok, binary}                   │
│    • lê adjacência via SegmentManager (interno)                  │
│    • treina LightGCN com Nx.Defn                                │
│    • retorna embeddings serializados — não salva nada            │
│                                                                 │
│  load_embeddings(name, binary) → :ok                            │
│    • desserializa + Store.ETS com TTL :infinity                  │
│    • substitui embeddings anteriores se houver                  │
│                                                                 │
│  embeddings_ready?(name) → boolean                              │
│    • health check para o caller e fallback logic                │
│                                                                 │
│  recommend(..., algorithm: :lightgcn)                           │
│    • dot product com embeddings em ETS → top-K                  │
│    • fallback automático para SALSA se não houver embeddings     │
└─────────────────────────────────────────────────────────────────┘
              ↑ binary                    ↑ binary
              │ (treinado)                │ (carregado do DB)
┌─────────────────────────────────────────────────────────────────┐
│                     App (ex: Melivra)                           │
│                                                                 │
│  TrainEmbeddingsWorker (Oban job):                              │
│    {:ok, data} = MeliGraph.train_embeddings(:professor_graph)   │
│    Repo.insert(%GraphEmbedding{data: data})   ← app persiste    │
│    MeliGraph.load_embeddings(:professor_graph, data)            │
│                                                                 │
│  BootLoader (extensão do existente):                            │
│    embedding = Repo.one(GraphEmbedding, ...)  ← app lê do DB   │
│    if embedding, do:                                            │
│      MeliGraph.load_embeddings(:professor_graph, embedding.data)│
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. Grafos Suportados pelo LightGCN

O LightGCN foi projetado para **grafos bipartidos**. A propagação pressupõe dois lados distintos — usuários e itens.

| Grafo | Tipo | LightGCN | Algoritmos alternativos |
|-------|------|----------|------------------------|
| `profile ↔ professor` | `:bipartite` | ✅ | SALSA, SimilarItems, GlobalRank |
| `profile ↔ post` | `:bipartite` | ✅ | SALSA, SimilarItems, GlobalRank |
| `profile ↔ ad` | `:bipartite` | ✅ | SALSA, GlobalRank |
| `profile ↔ group` | `:bipartite` | ✅ | SALSA, GlobalRank |
| `profile → profile` | `:directed` | ❌ | PageRank, SALSA (WTF-style) |

**Para grafos direcionados (follow graph)**, o LightGCN não se encaixa bem porque o grafo é homogêneo — não há dois lados distintos. PageRank e SALSA foram projetados exatamente para isso.

### Como o trainer identifica os dois lados

O `IdMap` armazena todos os vértices como inteiros sem distinção de tipo. O trainer precisa saber qual prefixo identifica o lado "usuário":

```elixir
MeliGraph.train_embeddings(:professor_graph,
  user_prefix: "profile:",   # "profile:*" = left side (users)
                             # todo o resto = right side (items)
  epochs: 500,
  layers: 3
)
```

Com `all_ids/1` do `IdMap`:
```
[{0, "profile:1"}, {1, "professor:7"}, {2, "post:3"}, ...]
       ↑ user side                ↑ item side
```

### Grafo unificado vs separado

**Opção A — Separado (recomendado para v0.2):**
```
:professor_graph  (profile ↔ professor)  → treina embeddings separados
:content_graph    (profile ↔ post)       → treina embeddings separados
```
Mais simples de validar, tunar e depurar.

**Opção B — Unificado (v0.3+):**
```
:content_graph  (profile ↔ professor + post + ad + group)
```
Mais dados = embeddings potencialmente melhores. Comportamento cross-domain.

---

## 5. Arquitetura de Arquivos

```
lib/meli_graph/
├── lightgcn/                              ← novo namespace
│   ├── matrix.ex                          ← constrói Ã a partir do SegmentManager
│   ├── trainer.ex                         ← loop de treino (Nx.Defn + BPR + Adam)
│   └── embedding_store.ex                 ← gerencia ciclo de vida no ETS
├── algorithm/
│   └── lightgcn.ex                        ← Algorithm behaviour (inferência)  [novo]
├── store/
│   └── ets.ex                             ← add suporte a TTL :infinity       [MUDA]
└── query/
    └── query.ex                           ← add :lightgcn + fallback SALSA    [MUDA]

lib/meli_graph.ex                          ← add train_embeddings/2, load_embeddings/2, embeddings_ready?/1  [MUDA]
```

**3 arquivos novos, 3 arquivos que mudam.**

---

## 6. Fases de Implementação

### Fase 1 — Store.ETS com TTL `:infinity`

**Arquivo:** `lib/meli_graph/store/ets.ex`

**Por que primeiro:** pré-requisito de todas as outras fases. Sem isso, os embeddings expiram no ETS e a Fase 4 não funciona.

**Problema atual:**
```elixir
# ets.ex linha 31 — falha se expires_at = :infinity (atom > integer = erro)
[{^key, value, expires_at}] when expires_at > now ->

# ets.ex clean_expired — match_spec com comparação numérica falha em :infinity
match_spec = [{{:"$1", :_, :"$2"}, [{:"=<", :"$2", now}], [:"$1"]}]
```

**Mudanças:**

```elixir
# put/4 — nova cláusula para :infinity
def put(conf, key, value, :infinity) do
  :ets.insert(table_name(conf), {key, value, :infinity})
  :ok
end

# get/2 — reconhecer :infinity como "nunca expira"
case :ets.lookup(table, key) do
  [{^key, value, :infinity}]                         -> {:ok, value}
  [{^key, value, expires_at}] when expires_at > now  -> {:ok, value}
  [{^key, _value, _expired}]                         ->
    :ets.delete(table, key)
    :miss
  []                                                  -> :miss
end

# clean_expired/1 — pular entradas :infinity no match_spec
match_spec = [
  {{:"$1", :_, :"$2"},
   [{:is_integer, :"$2"}, {:"=<", :"$2", now}],
   [:"$1"]}
]
```

**Testes:** verificar que `put/4` com `:infinity` nunca expira, que `clean_expired` não remove entradas `:infinity`, que TTL numérico continua funcionando normalmente.

---

### Fase 2 — Extração da Matriz de Adjacência

**Arquivo:** `lib/meli_graph/lightgcn/matrix.ex`

**Responsabilidade única:** ler todos os segmentos e produzir `Ã = D^(-1/2) · A · D^(-1/2)` como tensor Nx.

**Entradas:** `conf`, `user_prefix` (string)
**Saídas:** `{adj_norm, user_ids, item_ids, node_count}`

```
Ã ∈ R^{(M+N) × (M+N)}   onde M = |users|, N = |items|
```

**Lógica interna:**

```
1. IdMap.all_ids(conf)
   → [{internal_id, "profile:1"}, {internal_id, "professor:7"}, ...]

2. Separar por user_prefix:
   user_ids = [{int_id, ext_id} | começa com "profile:"]
   item_ids = [{int_id, ext_id} | não começa com "profile:"]

3. Reindexar para índices contíguos 0..M-1 (users) e 0..N-1 (items)
   (os internal_ids do IdMap podem ter gaps se houve pruning)

4. SegmentManager.all_segments(conf)
   Para cada segmento, ler todas as arestas ltr:
     :ets.tab2list(segment.ltr)
     → [{source_int, target_int, edge_type}, ...]

5. Filtrar só arestas user→item (source ∈ user_ids, target ∈ item_ids)

6. Montar matriz A em COO (lista de {row, col, val}):
   A = [  0    R  ]
       [ R^T   0  ]
   
   Para cada aresta (u, i):
     row u_idx,         col M + i_idx  → val 1.0   (user→item)
     row M + i_idx,     col u_idx      → val 1.0   (item→user)

7. Calcular graus: degree[node] = Σ_j A[node, j]

8. Normalização simétrica:
   Ã[u, i] = A[u, i] / (√degree[u] · √degree[i])
   (via D^(-1/2) · A · D^(-1/2))

9. Converter para Nx.tensor denso
   (para grafos pequenos/médios; sparse para v0.3+)
```

**Função pública:**
```elixir
@spec build(Config.t(), String.t()) ::
  {:ok, %{
    adj_norm: Nx.Tensor.t(),       # shape: {node_count, node_count}
    user_index: %{int() => int()}, # internal_id → row_index
    item_index: %{int() => int()}, # internal_id → row_index (offset M)
    user_count: non_neg_integer(),
    item_count: non_neg_integer(),
    node_count: non_neg_integer()
  }} | {:error, :empty_graph}
```

**Testes:** grafo com 3 users, 4 items, 5 arestas — verificar shape de `adj_norm`, verificar que valores são ≤ 1.0, verificar simetria (`Ã == Ã^T`).

---

### Fase 3 — Loop de Treinamento

**Arquivo:** `lib/meli_graph/lightgcn/trainer.ex`

**Responsabilidade:** receber a matriz normalizada, treinar LightGCN com BPR loss + Adam, retornar embeddings serializados.

**Hiperparâmetros com defaults:**

| Parâmetro | Default | Referência |
|-----------|---------|------------|
| `embedding_dim` | 64 | paper §4.1.2 |
| `layers` | 3 | paper §4.2 |
| `epochs` | 1000 | paper §4.1.2 |
| `batch_size` | 1024 | paper §4.1.2 |
| `learning_rate` | 0.001 | Adam default |
| `lambda` | 1.0e-4 | paper §4.1.2 |

**Fluxo interno de `train/3`:**

```
Entrada: conf, matrix_data (de matrix.ex), opts

1. Inicialização
   node_count = matrix_data.node_count
   embedding_dim = opts[:embedding_dim] || 64
   
   # Xavier uniform: U(-a, a) onde a = sqrt(6 / (fan_in + fan_out))
   E0 = Nx.random_uniform({node_count, embedding_dim},
          min: -xavier_limit, max: xavier_limit)
   
   # Estado Adam
   adam_m = Nx.broadcast(0.0, {node_count, embedding_dim})
   adam_v = Nx.broadcast(0.0, {node_count, embedding_dim})
   adam_t = 0   # step counter

2. Pré-computar poderes de Ã para as K camadas
   # Evita recalcular Ã^k a cada época
   adj_powers = [adj_norm, adj^2, adj^3]   # K=3 camadas

3. Loop de treinamento (1..epochs)
   Para cada época:
     a. Sortear mini-batch de pares (user_idx, pos_item_idx, neg_item_idx)
        neg_item_idx = item não interagido pelo user (random sampling)
     
     b. Forward pass (via Nx.Defn):
        E_layers = propagate(E0, adj_norm, layers)
        # E_layers = {E0, E1, E2, E3}  para K=3
        
        E_final = layer_combination(E_layers)
        # E_final = (E0 + E1 + E2 + E3) / 4
        
        e_u   = E_final[user_idx]    # embedding do user no batch
        e_pos = E_final[pos_item_idx]  # embedding do item positivo
        e_neg = E_final[neg_item_idx]  # embedding do item negativo
        
        score_pos = sum(e_u * e_pos, axis: 1)   # dot product
        score_neg = sum(e_u * e_neg, axis: 1)
     
     c. BPR Loss + L2:
        bpr = -mean(log_sigmoid(score_pos - score_neg))
        l2  = lambda * mean(E0 * E0)   # só sobre E0 (parâmetros treináveis)
        loss = bpr + l2
     
     d. Gradiente de loss em relação a E0:
        {loss, grad_E0} = Nx.Defn.value_and_grad(loss_fn, E0)
     
     e. Atualizar E0 com Adam:
        adam_t = adam_t + 1
        adam_m = beta1 * adam_m + (1 - beta1) * grad_E0
        adam_v = beta2 * adam_v + (1 - beta2) * (grad_E0 * grad_E0)
        m_hat  = adam_m / (1 - beta1^adam_t)
        v_hat  = adam_v / (1 - beta2^adam_t)
        E0 = E0 - lr * m_hat / (sqrt(v_hat) + epsilon)

4. Computar E_final com E0 treinado

5. Montar payload para serialização:
   payload = {
     embeddings: E_final,         # Nx.tensor — usado na inferência
     user_index: matrix_data.user_index,  # internal_id → row
     item_index: matrix_data.item_index,
     user_count: matrix_data.user_count,
     item_count: matrix_data.item_count,
     trained_at: System.os_time(:second)
   }
   
   {:ok, Nx.serialize(payload)}
```

**Por que `Nx.Defn` e não Axon:**
O LightGCN não tem camadas com parâmetros próprios — os únicos parâmetros são `E^(0)`. O grafo computacional é fixo (multiplicações matriciais). `Nx.Defn.value_and_grad` compila a função de loss via XLA/EXLA e retorna gradientes automaticamente, sem necessidade de definir um modelo Axon.

**Função pública:**
```elixir
@spec train(Config.t(), String.t(), keyword()) ::
  {:ok, binary()} | {:error, term()}
def train(conf, user_prefix, opts \\ [])
```

**Testes:**
- Grafo pequeno (5 users, 10 items) — loss deve diminuir ao longo das épocas
- Verificar shape de `E_final`: `{node_count, embedding_dim}`
- Serialização/deserialização roundtrip sem perda de dados
- `{:error, :empty_graph}` quando grafo está vazio

---

### Fase 4 — EmbeddingStore

**Arquivo:** `lib/meli_graph/lightgcn/embedding_store.ex`

**Responsabilidade:** gerenciar o ciclo de vida dos embeddings no ETS — carregar, recuperar, verificar disponibilidade.

**Chave ETS usada:** `:lightgcn_embeddings` (namespace isolado por instância via `Store.ETS`)

**Funções:**

```elixir
# Deserializa binary e salva no ETS com TTL :infinity
# Substitui qualquer embedding anterior silenciosamente
@spec load(Config.t(), binary()) :: :ok | {:error, term()}
def load(conf, binary)

# Retorna o payload completo (embeddings + índices)
@spec get(Config.t()) ::
  {:ok, %{
    embeddings: Nx.Tensor.t(),
    user_index: map(),
    item_index: map(),
    user_count: non_neg_integer(),
    item_count: non_neg_integer()
  }} | :miss
def get(conf)

# Verifica se embeddings estão carregados
@spec ready?(Config.t()) :: boolean()
def ready?(conf)
```

**Implementação de `load/2`:**
```elixir
def load(conf, binary) do
  case Nx.deserialize(binary) do
    payload when is_map(payload) ->
      Store.ETS.put(conf, :lightgcn_embeddings, payload, :infinity)
    _ ->
      {:error, :invalid_binary}
  end
end
```

**Testes:** load + get roundtrip, ready? retorna false quando não carregado, load substitui embeddings anteriores corretamente.

---

### Fase 5 — Algoritmo de Inferência

**Arquivo:** `lib/meli_graph/algorithm/lightgcn.ex`

**Responsabilidade:** implementar o `Algorithm` behaviour para LightGCN. A inferência é apenas um produto interno — sem propagação em tempo real.

```elixir
defmodule MeliGraph.Algorithm.LightGCN do
  @behaviour MeliGraph.Algorithm

  @impl true
  def compute(%Config{} = conf, entity_id, _type, opts) do
    top_k = Keyword.get(opts, :top_k, 20)

    case EmbeddingStore.get(conf) do
      :miss ->
        {:error, :embeddings_not_ready}

      {:ok, %{embeddings: e_all, user_index: u_idx, item_index: i_idx}} ->
        case Map.get(u_idx, entity_id) do
          nil ->
            {:ok, []}  # usuário não visto no treino

          row_idx ->
            # Embedding do usuário: shape {1, embedding_dim}
            e_u = Nx.slice(e_all, [row_idx, 0], [1, :auto])

            # Embeddings de todos os itens: shape {item_count, embedding_dim}
            item_rows = Map.values(i_idx)
            e_items = Nx.take(e_all, Nx.tensor(item_rows))

            # Scores: dot product → shape {item_count}
            scores = Nx.dot(e_u, [1], e_items, [1]) |> Nx.flatten()

            # Top-K por score
            top_k_result =
              scores
              |> Nx.to_flat_list()
              |> Enum.zip(Map.keys(i_idx))
              |> Enum.sort_by(fn {score, _} -> score end, :desc)
              |> Enum.take(top_k)
              |> Enum.map(fn {score, internal_id} ->
                {IdMap.get_external(conf, internal_id), score}
              end)

            {:ok, top_k_result}
        end
    end
  end
end
```

**Testes:**
- `{:error, :embeddings_not_ready}` quando EmbeddingStore está vazio
- `{:ok, []}` para usuário não visto no treino
- Top-K retornado com scores em ordem decrescente
- Usuário com mais interações deve ter scores mais altos para itens co-interagidos

---

### Fase 6 — Query Layer + API Pública

#### 6a. `lib/meli_graph/query/query.ex`

**Mudança 1 — registrar o algoritmo:**
```elixir
defp resolve_algorithm(:lightgcn), do: MeliGraph.Algorithm.LightGCN
```

**Mudança 2 — fallback para SALSA quando embeddings não estão prontos:**
```elixir
defp compute_inline(conf, external_id, type, opts) do
  algorithm = resolve_algorithm(Keyword.get(opts, :algorithm, :pagerank))

  result =
    if global_algorithm?(algorithm) do
      algorithm.compute(conf, 0, type, opts)
    else
      case IdMap.get_internal(conf, external_id) do
        nil         -> {:ok, []}
        internal_id -> algorithm.compute(conf, internal_id, type, opts)
      end
    end

  case result do
    {:error, :embeddings_not_ready} ->
      # Fallback transparente para SALSA
      fallback_opts = Keyword.put(opts, :algorithm, :salsa)
      compute_inline(conf, external_id, type, fallback_opts)
    other ->
      other
  end
end
```

#### 6b. `lib/meli_graph.ex`

```elixir
@doc """
Treina embeddings LightGCN com base no estado atual do grafo.

Retorna um binário serializado com os embeddings treinados.
O binário deve ser persistido pelo caller (ex: Oban worker → Postgres/R2)
e carregado de volta via `load_embeddings/2`.

## Opções

  * `:user_prefix` - prefixo dos vértices do lado "usuário" (obrigatório para :bipartite)
  * `:layers` - número de camadas LGC (padrão: 3)
  * `:epochs` - épocas de treinamento (padrão: 1000)
  * `:embedding_dim` - dimensão dos embeddings (padrão: 64)
  * `:lambda` - regularização L2 (padrão: 1.0e-4)
  * `:learning_rate` - taxa de aprendizado Adam (padrão: 0.001)
  * `:batch_size` - tamanho do mini-batch BPR (padrão: 1024)
"""
@spec train_embeddings(atom(), keyword()) :: {:ok, binary()} | {:error, term()}
def train_embeddings(name, opts \\ []) do
  conf        = get_conf(name)
  user_prefix = Keyword.fetch!(opts, :user_prefix)
  MeliGraph.LightGCN.Trainer.train(conf, user_prefix, opts)
end

@doc """
Carrega embeddings pré-treinados no grafo (via ETS com TTL :infinity).

O binário deve ter sido gerado por `train_embeddings/2` e persistido
externamente pelo caller. Substitui embeddings anteriores se houver.
"""
@spec load_embeddings(atom(), binary()) :: :ok | {:error, term()}
def load_embeddings(name, binary) do
  conf = get_conf(name)
  MeliGraph.LightGCN.EmbeddingStore.load(conf, binary)
end

@doc """
Retorna true se embeddings LightGCN estão carregados e prontos para inferência.
"""
@spec embeddings_ready?(atom()) :: boolean()
def embeddings_ready?(name) do
  conf = get_conf(name)
  MeliGraph.LightGCN.EmbeddingStore.ready?(conf)
end
```

---

## 7. Contrato Completo para a Aplicação

### Schema Postgres sugerido (app decide o nome/estrutura)

```sql
CREATE TABLE graph_embeddings (
  id          bigserial PRIMARY KEY,
  graph_name  text NOT NULL,
  data        bytea NOT NULL,
  node_count  integer,
  trained_at  timestamptz DEFAULT now()
);

CREATE INDEX ON graph_embeddings (graph_name, trained_at DESC);
```

### BootLoader (extensão do existente)

```elixir
def load do
  load_edges()           # já existe
  load_lightgcn_embeddings()   # novo
end

defp load_lightgcn_embeddings do
  case Repo.one(
    from e in GraphEmbedding,
    where: e.graph_name == "professor_graph",
    order_by: [desc: e.trained_at],
    limit: 1
  ) do
    nil ->
      Logger.warning("[BootLoader] Embeddings LightGCN não encontrados — SALSA será usado como fallback")

    %{data: binary} ->
      :ok = MeliGraph.load_embeddings(:professor_graph, binary)
      Logger.info("[BootLoader] Embeddings LightGCN carregados com sucesso")
  end
end
```

### TrainEmbeddingsWorker (Oban job — app cria)

```elixir
defmodule Melivra.Graph.Workers.TrainEmbeddingsWorker do
  use Oban.Worker, queue: :graph, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"graph_name" => name, "user_prefix" => prefix}}) do
    name_atom = String.to_existing_atom(name)

    with {:ok, binary} <- MeliGraph.train_embeddings(name_atom,
                            user_prefix: prefix,
                            epochs: 500,
                            layers: 3),
         {:ok, _} <- Repo.insert(%GraphEmbedding{
                       graph_name: name,
                       data: binary,
                       node_count: MeliGraph.vertex_count(name_atom)
                     }),
         :ok <- MeliGraph.load_embeddings(name_atom, binary) do
      Logger.info("[TrainEmbeddingsWorker] #{name} treinado e carregado com sucesso")
      :ok
    end
  end
end

# Disparar o treinamento (ex: após BootLoader, ou via cron Oban)
%{"graph_name" => "professor_graph", "user_prefix" => "profile:"}
|> Melivra.Graph.Workers.TrainEmbeddingsWorker.new()
|> Oban.insert()
```

### Uso na camada de recomendação (sem mudança de API)

```elixir
# LightGCN (usa embeddings se disponíveis, fallback para SALSA automaticamente)
{:ok, recs} = MeliGraph.recommend(:professor_graph, "profile:42", :content,
  algorithm: :lightgcn,
  top_k: 16
)

# Verificar disponibilidade
if MeliGraph.embeddings_ready?(:professor_graph) do
  # LightGCN disponível
else
  # Usando SALSA como fallback
end
```

---

## 8. Ordem de Execução e Dependências entre Fases

```
Fase 1 (store/ets.ex)
  ↓ desbloqueia
Fase 4 (embedding_store.ex) ←── também depende de Fase 2+3 para ter dados

Fase 2 (matrix.ex)
  ↓ depende de
Fase 3 (trainer.ex)          ← Fase 3 chama Fase 2 internamente

Fase 3 + Fase 4
  ↓ desbloqueia
Fase 5 (algorithm/lightgcn.ex)
  ↓ desbloqueia
Fase 6 (query.ex + meli_graph.ex)
```

**Sequência recomendada de implementação:**
1. Fase 1 — Store.ETS `:infinity`
2. Fase 2 — Matrix builder
3. Fase 3 — Trainer
4. Fase 4 — EmbeddingStore
5. Fase 5 — Algorithm
6. Fase 6 — Query + API pública

Cada fase pode ser testada isoladamente antes de avançar.

---

## 9. Dependências Nx

O Nx já está declarado como `optional: true` no `mix.exs`:

```elixir
{:nx, "~> 0.9", optional: true}
```

Para compilação JIT dos `defn` (recomendado para performance no treino):
```elixir
{:exla, "~> 0.9", optional: true}   # backend XLA — aceleração CPU/GPU
```

A lib continua funcional sem EXLA (usa o backend padrão Nx.BinaryBackend), mas o treinamento será mais lento sem JIT.

---

## 10. Checklist v0.2

### Store
- [x] `Store.ETS.put/4` aceita TTL `:infinity`
- [x] `Store.ETS.get/2` reconhece entradas `:infinity` como válidas
- [x] `Store.ETS.clean_expired/1` pula entradas `:infinity`

### LightGCN — Módulos novos
- [x] `MeliGraph.LightGCN.Matrix.build/2` — constrói Ã a partir do SegmentManager
- [x] `MeliGraph.LightGCN.Trainer.train/3` — loop BPR + Adam via Nx.Defn
- [x] `MeliGraph.LightGCN.EmbeddingStore.load/2` — deserializa + ETS
- [x] `MeliGraph.LightGCN.EmbeddingStore.get/1` — recupera embeddings
- [x] `MeliGraph.LightGCN.EmbeddingStore.ready?/1` — health check
- [x] `MeliGraph.Algorithm.LightGCN.compute/4` — inferência via dot product

### Integração
- [x] `Query.resolve_algorithm(:lightgcn)` adicionado
- [x] Fallback para SALSA quando `:embeddings_not_ready`
- [x] `MeliGraph.train_embeddings/2` na API pública
- [x] `MeliGraph.load_embeddings/2` na API pública
- [x] `MeliGraph.embeddings_ready?/1` na API pública

### Testes
- [x] `store/ets_test.exs` — casos TTL `:infinity`
- [x] `lightgcn/matrix_test.exs` — shape, simetria, normalização
- [x] `lightgcn/trainer_test.exs` — loss diminui, roundtrip serialização
- [x] `lightgcn/embedding_store_test.exs` — load/get/ready
- [x] `algorithm/lightgcn_test.exs` — inferência, fallback, usuário não visto
- [x] `query/lightgcn_integration_test.exs` — fallback automático, API pública
- [ ] `integration/professors_graph_test.exs` — treinar + recomendar com dataset real

---

## 11. Roadmap Pós v0.2

### v0.3 — Produção

- **Retreinamento incremental**: ao invés de treinar do zero, partir dos embeddings anteriores como `E^(0)` inicial (warm start). Reduz épocas necessárias de ~1000 para ~100-200 após o primeiro treinamento completo.
- **Estratégia de cold start documentada**: usuários e itens novos (sem embeddings) → fallback hierárquico: LightGCN → SALSA → GlobalRank.
- **Sparse matrix support**: para grafos acima de ~50k nós, substituir o tensor denso por representação COO/CSR usando `Nx.to_batched` ou biblioteca externa.
- **Testes de integração completos**: `professors_graph_test.exs` com métricas recall@K e NDCG@K computadas sobre holdout set dos dados reais.
- **Grafo unificado opcional**: `profile ↔ (professor + post + ad + group)` com `user_prefix: "profile:"`.

---

## Referências

1. He et al., **"LightGCN: Simplifying and Powering Graph Convolution Network for Recommendation"**, SIGIR 2020. https://doi.org/10.1145/3397271.3401063
2. PyTorch Geometric LightGCN: https://pytorch-geometric.readthedocs.io/en/latest/generated/torch_geometric.nn.models.LightGCN.html
3. Kingma & Ba, **"Adam: A Method for Stochastic Optimization"**, ICLR 2015
4. Rendle et al., **"BPR: Bayesian Personalized Ranking from Implicit Feedback"**, UAI 2009
