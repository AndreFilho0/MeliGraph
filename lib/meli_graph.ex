defmodule MeliGraph do
  @moduledoc """
  MeliGraph — Motor de Recomendação baseado em Grafos para Elixir.

  Biblioteca para recomendações baseadas em teoria dos grafos, inspirada
  nos sistemas WTF (Who to Follow) e GraphJet do Twitter, e nos padrões
  de engenharia do Oban.

  ## Uso

      # Iniciar uma instância
      MeliGraph.start_link(name: :my_graph, graph_type: :bipartite, testing: :sync)

      # Inserir arestas
      MeliGraph.insert_edge(:my_graph, "user:1", "post:a", :like)

      # Obter recomendações
      {:ok, recs} = MeliGraph.recommend(:my_graph, "user:1", :content)

  ## Múltiplas instâncias

  Cada instância tem seu próprio namespace via Registry, permitindo
  múltiplos grafos independentes no mesmo node:

      MeliGraph.start_link(name: :follows, graph_type: :directed)
      MeliGraph.start_link(name: :interactions, graph_type: :bipartite)
  """

  alias MeliGraph.Router

  @doc """
  Inicia uma instância do MeliGraph com a configuração fornecida.

  ## Opções

    * `:name` - nome da instância (obrigatório)
    * `:graph_type` - `:directed` ou `:bipartite` (obrigatório)
    * `:testing` - `:disabled` ou `:sync` (padrão: `:disabled`)
    * `:segment_max_edges` - máximo de arestas por segmento (padrão: 1_000_000)

  Veja `MeliGraph.Config` para todas as opções.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    conf = MeliGraph.Config.new(opts)

    if conf.distribution == :horde and MeliGraph.Distributed.distributed_context?() do
      # Modo distribuído: o Reconciler aloca a árvore no nó dono via Horde
      # (consistent hashing) no boot E re-dispara a alocação se o failover do
      # Horde perder a corrida e deixar o grafo órfão. Ver MeliGraph.Reconciler.
      MeliGraph.Reconciler.start_link(opts)
    else
      # :local OU :horde sem cluster (degrada): árvore local, caminho de hoje.
      MeliGraph.Supervisor.start_link(opts)
    end
  end

  @doc false
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    if Keyword.get(opts, :distribution, :local) == :horde and
         MeliGraph.Distributed.distributed_context?() do
      # Em :horde, a alocação é cluster-wide e idempotente — não há um pid de
      # supervisor local para a árvore do app vigiar. O Reconciler (1 por nó) faz
      # a alocação no boot e cobre a corrida de failover do Horde (rede de
      # segurança); é ele que o app supervisiona localmente.
      MeliGraph.Reconciler.child_spec(opts)
    else
      %{
        id: name,
        start: {__MODULE__, :start_link, [opts]},
        type: :supervisor
      }
    end
  end

  @doc """
  Insere uma aresta no grafo, com peso opcional (default `1.0`).

  No modo `:sync`, a inserção é síncrona.
  No modo `:disabled`, a inserção é assíncrona (fire-and-forget).

  O peso é usado pelo LightGCN como entrada na matriz de adjacência
  ponderada `Ã = D^(-1/2) · W · D^(-1/2)`. Quando múltiplas arestas
  user↔item existem (ex.: like + comentário), os pesos são somados.
  Os demais algoritmos (PageRank, SALSA, etc.) ignoram o peso na v0.2.
  """
  @spec insert_edge(atom(), term(), term(), atom(), float()) :: :ok
  def insert_edge(name, source, target, edge_type, weight \\ 1.0) do
    Router.route_write(name, :insert_edge, [source, target, edge_type, weight])
  end

  @doc """
  Retorna top-N recomendações para um vértice.

  ## Opções

    * `:algorithm` - `:pagerank` ou `:salsa` (padrão: `:pagerank`)
    * `:top_k` - número de resultados (padrão: depende do algoritmo)

  Opções adicionais são passadas diretamente para o algoritmo.
  """
  @spec recommend(atom(), term(), atom(), keyword()) ::
          {:ok, [{term(), float()}]} | {:error, term()}
  def recommend(name, entity_id, type, opts \\ []) do
    Router.route_read(name, :recommend, [entity_id, type, opts])
  end

  @doc """
  Retorna os vizinhos de um vértice no grafo.

  ## Opções

    * `:type` - filtrar por tipo de aresta (opcional)
  """
  @spec neighbors(atom(), term(), :outgoing | :incoming, keyword()) :: [term()]
  def neighbors(name, entity_id, direction, opts \\ []) do
    Router.route_read(name, :neighbors, [entity_id, direction, opts])
  end

  @doc """
  Retorna o número total de arestas no grafo.
  """
  @spec edge_count(atom()) :: non_neg_integer()
  def edge_count(name) do
    Router.route_read(name, :edge_count, [])
  end

  @doc """
  Retorna o número total de vértices mapeados.
  """
  @spec vertex_count(atom()) :: non_neg_integer()
  def vertex_count(name) do
    Router.route_read(name, :vertex_count, [])
  end

  @doc """
  Treina embeddings LightGCN com base no estado atual do grafo.

  Retorna um binário serializado com os embeddings treinados. A lib
  **não persiste nada** — o binário deve ser salvo pelo caller (Postgres,
  R2, S3...) e recarregado depois via `load_embeddings/2`.

  ## Opções

    * `:user_prefix` - prefixo dos vértices do lado "usuário" (obrigatório)
    * `:embedding_dim` - dimensão dos embeddings (padrão: 64)
    * `:layers` - número de camadas LGC (padrão: 3)
    * `:epochs` - épocas de treinamento (padrão: 1000)
    * `:batch_size` - tamanho do mini-batch BPR (padrão: 1024)
    * `:learning_rate` - taxa de aprendizado Adam (padrão: 0.001)
    * `:lambda` - regularização L2 (padrão: 1.0e-4)
  """
  @spec train_embeddings(atom(), keyword()) :: {:ok, binary()} | {:error, term()}
  def train_embeddings(name, opts \\ []) do
    # Valida o argumento obrigatório no nó chamador (falha cedo, não viaja).
    user_prefix = Keyword.fetch!(opts, :user_prefix)
    Router.route_read(name, :train_embeddings, [user_prefix, opts])
  end

  @doc """
  Carrega embeddings pré-treinados na instância (em ETS com TTL `:infinity`).

  Substitui qualquer embedding anterior. Retorna `{:error, :invalid_binary}`
  se o binário não for um payload válido produzido por `train_embeddings/2`.
  """
  @spec load_embeddings(atom(), binary()) :: :ok | {:error, :invalid_binary}
  def load_embeddings(name, binary) do
    Router.route_write(name, :load_embeddings, [binary])
  end

  @doc """
  Retorna `true` se há embeddings LightGCN carregados na instância.

  Quando `false`, chamadas a `recommend/4` com `algorithm: :lightgcn`
  fazem fallback transparente para SALSA.
  """
  @spec embeddings_ready?(atom()) :: boolean()
  def embeddings_ready?(name) do
    Router.route_read(name, :embeddings_ready?, [])
  end

  @doc """
  Retorna `true` quando a instância terminou de reconstruir o grafo via a MFA
  `on_ready` (ou imediatamente, se `on_ready` for `nil`).

  Útil para gatear leituras durante o boot frio ou logo após um failover, quando
  o grafo no nó dono ainda está sendo repovoado da fonte da verdade.
  """
  @spec ready?(atom()) :: boolean()
  def ready?(name) do
    Router.route_read(name, :ready?, [])
  end

  @doc """
  Retorna o nó que hospeda o grafo: `Node.self()` em `:local` ou no nó dono;
  o nó dono em `:horde` a partir de outro nó; `nil` se indisponível.

  Em modo distribuído, use para escolher onde rodar operações longas como
  `train_embeddings/2` (treine no dono).
  """
  @spec owner_node(atom()) :: node() | nil
  def owner_node(name) do
    case Router.resolve_route(name) do
      {:local, _conf} -> Node.self()
      {:remote, owner, _conf} -> owner
      {:error, _} -> nil
    end
  rescue
    ArgumentError -> nil
  end
end
