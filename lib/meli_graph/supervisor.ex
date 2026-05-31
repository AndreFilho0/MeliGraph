defmodule MeliGraph.Supervisor do
  @moduledoc """
  Supervision tree principal do MeliGraph.

  Inicia todos os componentes na ordem correta:
  1. Registry (lookup de processos)
  2. IdMap (mapeamento de IDs)
  3. SegmentManager (storage do grafo)
  4. Writer (ingestão)
  5. Store.ETS (cache de resultados)
  6. Plugins.Supervisor (tarefas periódicas) — skipped no modo :sync
  7. Bootstrapper (rebuild via on_ready) — sempre o último filho
  """

  use Supervisor

  alias MeliGraph.Config

  def start_link(opts) do
    conf = Config.new(opts)
    Supervisor.start_link(__MODULE__, conf, name: supervisor_name(conf))
  end

  @impl true
  def init(%Config{} = conf) do
    children =
      [
        {Registry, keys: :unique, name: conf.registry},
        {MeliGraph.ConfigHolder, conf: conf},
        {MeliGraph.Graph.IdMap, conf: conf},
        {MeliGraph.Graph.SegmentManager, conf: conf},
        {MeliGraph.Ingestion.Writer, conf: conf},
        {MeliGraph.Store.ETS, conf: conf}
      ]
      |> maybe_add_plugins(conf)
      |> Kernel.++([{MeliGraph.Bootstrapper, conf: conf}])

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Retorna o Config da instância dado o nome.
  """
  @spec get_conf(atom()) :: Config.t()
  def get_conf(name) do
    [{_pid, conf}] = Registry.lookup(registry_name(name), :conf)
    conf
  end

  @doc """
  Nome registrado (local, por nó) do processo raiz da árvore da instância `name`.

  Fixo e determinístico (`Module.concat(name, Supervisor)`): qualquer nó sabe, sem
  ambiguidade, se hospeda uma árvore local viva via
  `Process.whereis(local_name(name))`. É o que o `MeliGraph.Reconciler` usa para
  detectar e reapar duplicatas no modo `:horde`.
  """
  @spec local_name(atom()) :: module()
  def local_name(name), do: Module.concat(name, Supervisor)

  defp maybe_add_plugins(children, %Config{testing: :sync}), do: children

  defp maybe_add_plugins(children, conf) do
    children ++ [{MeliGraph.Plugins.Supervisor, conf: conf}]
  end

  defp supervisor_name(%Config{name: name}), do: local_name(name)

  defp registry_name(name) do
    Module.concat(name, Registry)
  end
end
