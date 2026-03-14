defmodule MeliGraph.Store do
  @moduledoc """
  Behaviour para armazenamento de resultados de recomendação.

  Inspirado no padrão Oban Engine: permite trocar a implementação
  de cache sem alterar o restante do sistema.
  """

  @callback get(conf :: MeliGraph.Config.t(), key :: term()) ::
              {:ok, term()} | :miss

  @callback put(conf :: MeliGraph.Config.t(), key :: term(), value :: term(), ttl :: pos_integer()) ::
              :ok

  @callback delete(conf :: MeliGraph.Config.t(), key :: term()) :: :ok

  @callback clear(conf :: MeliGraph.Config.t()) :: :ok
end
