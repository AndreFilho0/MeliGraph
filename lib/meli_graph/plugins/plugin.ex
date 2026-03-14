defmodule MeliGraph.Plugin do
  @moduledoc """
  Behaviour para plugins periódicos do MeliGraph.

  Inspirado no padrão Oban: plugins são GenServers supervisionados que
  executam tarefas periódicas (pruning, cache cleanup, pré-computação).
  """

  @callback start_link(keyword()) :: GenServer.on_start()
  @callback validate(keyword()) :: :ok | {:error, String.t()}
end
