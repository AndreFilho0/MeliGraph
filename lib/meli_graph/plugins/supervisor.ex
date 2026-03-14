defmodule MeliGraph.Plugins.Supervisor do
  @moduledoc """
  Supervisor para plugins periódicos.

  Cada plugin configurado no `Config` é iniciado como filho deste supervisor.
  """

  use Supervisor

  alias MeliGraph.Config

  def start_link(opts) do
    conf = Keyword.fetch!(opts, :conf)
    Supervisor.start_link(__MODULE__, conf, name: MeliGraph.Registry.via(conf, :plugins_supervisor))
  end

  @impl true
  def init(%Config{plugins: plugins} = conf) do
    children =
      Enum.map(plugins, fn {module, plugin_opts} ->
        opts = Keyword.merge(plugin_opts, conf: conf)

        %{
          id: module,
          start: {module, :start_link, [opts]},
          type: :worker
        }
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
