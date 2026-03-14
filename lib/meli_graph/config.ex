defmodule MeliGraph.Config do
  @moduledoc """
  Configuração centralizada, validada uma vez no start_link.
  Passada para todos os processos da supervision tree via `conf:`.

  Inspirado no padrão do Oban: um struct imutável que carrega todas
  as configurações necessárias, eliminando `Application.get_env` espalhado
  e permitindo múltiplas instâncias com configurações diferentes.
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

  @doc """
  Cria e valida uma nova configuração a partir das opções fornecidas.

  ## Opções obrigatórias

    * `:name` - nome da instância (atom)
    * `:graph_type` - `:directed` ou `:bipartite`

  ## Opções opcionais

    * `:segment_max_edges` - máximo de arestas por segmento (padrão: 1_000_000)
    * `:segment_ttl` - TTL dos segmentos em ms (padrão: 24h)
    * `:result_ttl` - TTL dos resultados em cache em ms (padrão: 30min)
    * `:algorithms` - lista de algoritmos habilitados (padrão: [:pagerank, :salsa])
    * `:testing` - modo de testing: `:disabled` ou `:sync` (padrão: :disabled)
    * `:plugins` - lista de {módulo, opts} dos plugins (padrão: Pruner + CacheCleaner)
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    conf = struct!(__MODULE__, opts)
    validate!(conf)
    %{conf | registry: registry_name(conf.name)}
  end

  defp registry_name(name) do
    Module.concat(name, Registry)
  end

  defp validate!(%{segment_max_edges: n}) when not is_integer(n) or n < 1 do
    raise ArgumentError, "segment_max_edges must be a positive integer, got: #{inspect(n)}"
  end

  defp validate!(%{graph_type: type}) when type not in [:directed, :bipartite] do
    raise ArgumentError, "graph_type must be :directed or :bipartite, got: #{inspect(type)}"
  end

  defp validate!(%{testing: mode}) when mode not in [:disabled, :sync] do
    raise ArgumentError, "testing must be :disabled or :sync, got: #{inspect(mode)}"
  end

  defp validate!(%{segment_ttl: ttl}) when not is_integer(ttl) or ttl < 1 do
    raise ArgumentError, "segment_ttl must be a positive integer, got: #{inspect(ttl)}"
  end

  defp validate!(%{result_ttl: ttl}) when not is_integer(ttl) or ttl < 1 do
    raise ArgumentError, "result_ttl must be a positive integer, got: #{inspect(ttl)}"
  end

  defp validate!(conf), do: conf
end
