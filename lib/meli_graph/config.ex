defmodule MeliGraph.Config do
  @moduledoc """
  Configuração centralizada, validada uma vez no start_link.
  Passada para todos os processos da supervision tree via `conf:`.

  Inspirado no padrão do Oban: um struct imutável que carrega todas
  as configurações necessárias, eliminando `Application.get_env` espalhado
  e permitindo múltiplas instâncias com configurações diferentes.
  """

  @type on_ready :: nil | {module(), atom(), [term()]}

  @type t :: %__MODULE__{
          name: atom(),
          graph_type: :directed | :bipartite,
          segment_max_edges: pos_integer(),
          segment_ttl: pos_integer(),
          result_ttl: pos_integer(),
          algorithms: [atom()],
          testing: :disabled | :sync,
          plugins: [{module(), keyword()}],
          registry: atom(),
          distribution: :local | :horde,
          on_ready: on_ready(),
          cluster_call_timeout: pos_integer(),
          reconcile_interval: pos_integer(),
          reconcile_grace: non_neg_integer()
        }

  @enforce_keys [:name, :graph_type]
  defstruct [
    :name,
    :graph_type,
    :registry,
    :on_ready,
    segment_max_edges: 1_000_000,
    segment_ttl: :timer.hours(24),
    result_ttl: :timer.minutes(30),
    algorithms: [:pagerank, :salsa],
    testing: :disabled,
    plugins: [
      {MeliGraph.Plugins.Pruner, interval: :timer.minutes(5)},
      {MeliGraph.Plugins.CacheCleaner, interval: :timer.minutes(1)}
    ],
    distribution: :local,
    cluster_call_timeout: :timer.seconds(15),
    reconcile_interval: :timer.seconds(2),
    reconcile_grace: :timer.seconds(5)
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
    * `:distribution` - `:local` (padrão) ou `:horde` (modo distribuído opt-in)
    * `:on_ready` - MFA `{module, function, args}` chamada quando a instância sobe
      (e em cada realocação no modo `:horde`) para reconstruir o grafo; `nil` (padrão)
      marca a instância como pronta imediatamente
    * `:cluster_call_timeout` - timeout em ms das chamadas cross-node (padrão: 15s)
    * `:reconcile_interval` - intervalo em ms do reconciliador que vigia a presença
      do dono no modo `:horde` (padrão: 2s); só usado em `:horde`
    * `:reconcile_grace` - quanto tempo em ms o grafo pode ficar sem dono antes do
      reconciliador re-disparar a alocação (padrão: 5s). Deve ser maior que a
      recuperação automática do Horde (~1-2s) para evitar dupla-alocação
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

  defp validate!(%{distribution: d}) when d not in [:local, :horde] do
    raise ArgumentError, "distribution must be :local or :horde, got: #{inspect(d)}"
  end

  defp validate!(%{cluster_call_timeout: t}) when not is_integer(t) or t < 1 do
    raise ArgumentError,
          "cluster_call_timeout must be a positive integer, got: #{inspect(t)}"
  end

  defp validate!(%{reconcile_interval: t}) when not is_integer(t) or t < 1 do
    raise ArgumentError,
          "reconcile_interval must be a positive integer, got: #{inspect(t)}"
  end

  defp validate!(%{reconcile_grace: t}) when not is_integer(t) or t < 0 do
    raise ArgumentError,
          "reconcile_grace must be a non-negative integer, got: #{inspect(t)}"
  end

  defp validate!(%{on_ready: on_ready})
       when not (is_nil(on_ready) or (is_tuple(on_ready) and tuple_size(on_ready) == 3)) do
    raise ArgumentError,
          "on_ready must be nil or {module, function, args}, got: #{inspect(on_ready)}"
  end

  defp validate!(%{on_ready: {m, f, a}})
       when not (is_atom(m) and is_atom(f) and is_list(a)) do
    raise ArgumentError,
          "on_ready must be {module(), atom(), list()}, got: #{inspect({m, f, a})}"
  end

  defp validate!(conf), do: conf
end
