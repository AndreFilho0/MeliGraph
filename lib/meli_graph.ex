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

  alias MeliGraph.Ingestion.Writer
  alias MeliGraph.LightGCN.{EmbeddingStore, Trainer}
  alias MeliGraph.Query
  alias MeliGraph.Graph.{IdMap, SegmentManager}

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
    MeliGraph.Supervisor.start_link(opts)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :name),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Insere uma aresta no grafo.

  No modo `:sync`, a inserção é síncrona.
  No modo `:disabled`, a inserção é assíncrona (fire-and-forget).
  """
  @spec insert_edge(atom(), term(), term(), atom()) :: :ok
  def insert_edge(name, source, target, edge_type) do
    conf = get_conf(name)
    Writer.insert_edge(conf, source, target, edge_type)
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
    conf = get_conf(name)
    Query.recommend(conf, entity_id, type, opts)
  end

  @doc """
  Retorna os vizinhos de um vértice no grafo.

  ## Opções

    * `:type` - filtrar por tipo de aresta (opcional)
  """
  @spec neighbors(atom(), term(), :outgoing | :incoming, keyword()) :: [term()]
  def neighbors(name, entity_id, direction, opts \\ []) do
    conf = get_conf(name)

    case IdMap.get_internal(conf, entity_id) do
      nil ->
        []

      internal_id ->
        edge_type = Keyword.get(opts, :type)

        internal_neighbors =
          case {direction, edge_type} do
            {:outgoing, nil} ->
              SegmentManager.neighbors_out(conf, internal_id)
              |> Enum.map(fn {id, _type} -> id end)

            {:incoming, nil} ->
              SegmentManager.neighbors_in(conf, internal_id)
              |> Enum.map(fn {id, _type} -> id end)

            {:outgoing, type} ->
              SegmentManager.neighbors_out(conf, internal_id, type)

            {:incoming, type} ->
              SegmentManager.neighbors_in(conf, internal_id, type)
          end

        internal_neighbors
        |> Enum.uniq()
        |> Enum.map(&IdMap.get_external(conf, &1))
    end
  end

  @doc """
  Retorna o número total de arestas no grafo.
  """
  @spec edge_count(atom()) :: non_neg_integer()
  def edge_count(name) do
    conf = get_conf(name)
    SegmentManager.total_edge_count(conf)
  end

  @doc """
  Retorna o número total de vértices mapeados.
  """
  @spec vertex_count(atom()) :: non_neg_integer()
  def vertex_count(name) do
    conf = get_conf(name)
    IdMap.size(conf)
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
    conf = get_conf(name)
    user_prefix = Keyword.fetch!(opts, :user_prefix)
    Trainer.train(conf, user_prefix, opts)
  end

  @doc """
  Carrega embeddings pré-treinados na instância (em ETS com TTL `:infinity`).

  Substitui qualquer embedding anterior. Retorna `{:error, :invalid_binary}`
  se o binário não for um payload válido produzido por `train_embeddings/2`.
  """
  @spec load_embeddings(atom(), binary()) :: :ok | {:error, :invalid_binary}
  def load_embeddings(name, binary) do
    conf = get_conf(name)
    EmbeddingStore.load(conf, binary)
  end

  @doc """
  Retorna `true` se há embeddings LightGCN carregados na instância.

  Quando `false`, chamadas a `recommend/4` com `algorithm: :lightgcn`
  fazem fallback transparente para SALSA.
  """
  @spec embeddings_ready?(atom()) :: boolean()
  def embeddings_ready?(name) do
    conf = get_conf(name)
    EmbeddingStore.ready?(conf)
  end

  # --- Private ---

  defp get_conf(name) do
    registry = Module.concat(name, Registry)

    case Registry.lookup(registry, :conf) do
      [{_pid, conf}] ->
        conf

      [] ->
        raise ArgumentError,
              "MeliGraph instance #{inspect(name)} not found. Did you start it with MeliGraph.start_link(name: #{inspect(name)}, ...)?"
    end
  end
end
