defmodule MeliGraph.ConfigHolder do
  @moduledoc """
  Processo simples que registra o Config no Registry, permitindo
  que qualquer processo localize a configuração da instância.
  """

  use GenServer

  def start_link(opts) do
    conf = Keyword.fetch!(opts, :conf)

    GenServer.start_link(__MODULE__, conf,
      name: {:via, Registry, {conf.registry, :conf, conf}}
    )
  end

  @impl true
  def init(conf) do
    {:ok, conf}
  end
end
