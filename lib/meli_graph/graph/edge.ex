defmodule MeliGraph.Graph.Edge do
  @moduledoc """
  Struct representando uma aresta no grafo.
  """

  @type t :: %__MODULE__{
          source: term(),
          target: term(),
          type: atom(),
          weight: float(),
          inserted_at: integer()
        }

  @enforce_keys [:source, :target, :type]
  defstruct [:source, :target, :type, :inserted_at, weight: 1.0]

  @doc """
  Cria uma nova aresta com timestamp atual e peso opcional (default `1.0`).
  """
  @spec new(term(), term(), atom(), float()) :: t()
  def new(source, target, type, weight \\ 1.0) when is_number(weight) do
    %__MODULE__{
      source: source,
      target: target,
      type: type,
      weight: weight * 1.0,
      inserted_at: System.monotonic_time(:millisecond)
    }
  end
end
