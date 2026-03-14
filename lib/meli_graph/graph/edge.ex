defmodule MeliGraph.Graph.Edge do
  @moduledoc """
  Struct representando uma aresta no grafo.
  """

  @type t :: %__MODULE__{
          source: term(),
          target: term(),
          type: atom(),
          inserted_at: integer()
        }

  @enforce_keys [:source, :target, :type]
  defstruct [:source, :target, :type, :inserted_at]

  @doc """
  Cria uma nova aresta com timestamp atual.
  """
  @spec new(term(), term(), atom()) :: t()
  def new(source, target, type) do
    %__MODULE__{
      source: source,
      target: target,
      type: type,
      inserted_at: System.monotonic_time(:millisecond)
    }
  end
end
