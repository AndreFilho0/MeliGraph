defmodule MeliGraph.Distributed do
  @moduledoc """
  Supervisor de cluster da lib — base do modo distribuído **opt-in** (v0.3).

  O app consumidor adiciona `MeliGraph.Distributed` **uma única vez** na sua
  árvore de supervisão (junto a outros componentes Horde, se houver). Ele sobe:

    * `MeliGraph.HordeRegistry` (`Horde.Registry`) — descoberta cluster-wide
      `{name → {pid, %Config{}}}`. O `%Config{}` viaja como metadata.
    * `MeliGraph.HordeSupervisor` (`Horde.DynamicSupervisor`) — elege o nó dono
      de cada grafo via `Horde.UniformDistribution` (hash do `name`) e reinicia
      a árvore no failover.

  Tudo aqui depende de `:horde`/`:libring`, que são **deps opcionais**. Num app
  single-node que não as inclui, este módulo nunca é adicionado à árvore, e o
  gate `distributed_context?/0` faz o resto do código degradar para `:local`.

  Os nomes `MeliGraph.HordeRegistry`/`MeliGraph.HordeSupervisor` são fixos
  (mesmo padrão de `TrucoRegistry`/`GameSupervisor`); override multi-tenant
  fica para uma versão futura.
  """

  # As deps Horde são opcionais; nenhuma referência a Horde.* existe em
  # compile-time (sem alias/use/@behaviour) — só chamadas em corpo de função.
  # Este pragma suprime o warning de "função/módulo indefinido" quando a lib
  # é compilada num projeto que não inclui :horde.
  @compile {:no_warn_undefined,
            [Horde.Registry, Horde.DynamicSupervisor, Horde.UniformDistribution, Horde.Cluster]}

  use Supervisor

  alias MeliGraph.Config

  @registry MeliGraph.HordeRegistry
  @supervisor MeliGraph.HordeSupervisor

  @doc "Nome fixo do `Horde.Registry` de descoberta."
  @spec registry_name() :: module()
  def registry_name, do: @registry

  @doc "Nome fixo do `Horde.DynamicSupervisor` que hospeda os grafos."
  @spec supervisor_name() :: module()
  def supervisor_name, do: @supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Horde.Registry, name: @registry, keys: :unique, members: :auto},
      {Horde.DynamicSupervisor,
       name: @supervisor,
       strategy: :one_for_one,
       members: :auto,
       distribution_strategy: Horde.UniformDistribution}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  `true` se as deps Horde estão compiladas/carregáveis neste runtime.
  """
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Horde.Registry)

  @doc """
  Gate de ativação do modo distribuído: Horde disponível **e** nó vivo
  (`Node.alive?()`). Sob `ExUnit` normal (sem `:net_kernel`) é `false`, então
  uma instância `distribution: :horde` degrada para a árvore local de hoje.
  """
  @spec distributed_context?() :: boolean()
  def distributed_context?, do: available?() and Node.alive?()

  @doc """
  Garante que a árvore do grafo está iniciada **em algum nó** do cluster.

  Chamado por todos os nós no boot; o `Horde.UniformDistribution` elege um
  único dono por `name`. Os demais recebem `{:error, {:already_started, _}}`,
  tratado como sucesso (convergência).

  O child id é **estável** (`{MeliGraph.Supervisor, name}`) e **não inclui o
  conf** — caso contrário nós com `on_ready`/timeout diferentes gerariam ids
  distintos e o Horde subiria duas árvores para o mesmo grafo. Contrato: todos
  os nós chamam `start_link` com opts idênticos por `name`.
  """
  @spec ensure_started(Config.t()) :: {:ok, pid() | :ignore} | {:error, term()}
  def ensure_started(%Config{} = conf) do
    child = %{
      id: {MeliGraph.Supervisor, conf.name},
      start: {MeliGraph.Supervisor, :start_link, [conf_to_opts(conf)]},
      type: :supervisor,
      restart: :transient
    }

    case Horde.DynamicSupervisor.start_child(@supervisor, child) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      :ignore -> {:ok, :ignore}
      {:error, _} = err -> err
    end
  end

  @doc """
  Registra o **processo chamador** como dono de `conf.name` no `Horde.Registry`,
  com o `%Config{}` como metadata.

  Chamado pelo `ConfigHolder` no seu `init/1` (no nó dono). Ligar a entrada ao
  ciclo de vida do ConfigHolder garante que, no failover, quando a árvore cai, o
  delta_crdt dropa a entrada stale e o novo dono re-registra. Tolera
  `{:error, {:already_registered, _}}` (reentrância benigna).
  """
  @spec register_owner(Config.t()) :: :ok
  def register_owner(%Config{} = conf) do
    case Horde.Registry.register(@registry, conf.name, conf) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> :ok
    end
  end

  @doc """
  Descobre o nó dono de um grafo via `Horde.Registry`.

  Retorna `{:ok, pid, conf}` (com `node(pid)` = dono) ou `:error` se a entrada
  ainda não propagou (a janela de consistência é tratada com retry no Router).
  """
  @spec lookup_owner(atom()) :: {:ok, pid(), Config.t()} | :error
  def lookup_owner(name) do
    case Horde.Registry.lookup(@registry, name) do
      [{pid, %Config{} = conf}] -> {:ok, pid, conf}
      _ -> :error
    end
  end

  # Reconstrói as opts serializáveis a partir do conf para o child spec do
  # Horde (que pode ser reiniciado em outro nó). `registry` é derivado em
  # `Config.new/1`, então é descartado aqui.
  #
  # `reconcile_interval`/`reconcile_grace` também são descartados de propósito:
  # eles só são usados pelo `MeliGraph.Reconciler` (1 por nó, que lê a config
  # LOCAL do app), nunca pela árvore do grafo. Mantê-los fora daqui é importante
  # para o consistent hashing — o `Horde.UniformDistribution.choose_node` decide
  # o nó dono hasheando o child spec INTEIRO menos o `:id` (logo, incluindo estas
  # opts). Deixá-los de fora garante que a escolha do dono não dependa desses
  # parâmetros e não mude se alguém ajustar o intervalo/grace.
  defp conf_to_opts(%Config{} = conf) do
    conf
    |> Map.from_struct()
    |> Map.drop([:registry, :reconcile_interval, :reconcile_grace])
    |> Map.to_list()
  end
end
