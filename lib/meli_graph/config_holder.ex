defmodule MeliGraph.ConfigHolder do
  @moduledoc """
  Processo simples que registra o Config no Registry, permitindo
  que qualquer processo localize a configuração da instância.
  """

  use GenServer

  def start_link(opts) do
    conf = Keyword.fetch!(opts, :conf)

    GenServer.start_link(__MODULE__, conf, name: {:via, Registry, {conf.registry, :conf, conf}})
  end

  @impl true
  def init(conf) do
    maybe_register_owner(conf)

    :telemetry.execute(
      [:meli_graph, :instance, :started],
      %{},
      %{name: conf.name, node: node(), distribution: conf.distribution}
    )

    {:ok, conf}
  end

  # No modo distribuído, além do registro local (via `:via` acima), publica a
  # instância no Horde.Registry para descoberta cluster-wide. Roda só no nó dono
  # (a árvore só existe lá) e só quando há contexto distribuído.
  defp maybe_register_owner(%{distribution: :horde} = conf) do
    if MeliGraph.Distributed.distributed_context?() do
      MeliGraph.Distributed.register_owner(conf)
    end

    :ok
  end

  defp maybe_register_owner(_conf), do: :ok
end
