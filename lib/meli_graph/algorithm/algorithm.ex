defmodule MeliGraph.Algorithm do
  @moduledoc """
  Behaviour genérico para algoritmos de recomendação.

  Inspirado no padrão Oban Engine: cada algoritmo implementa `compute/4`
  e pode ser trocado ou estendido sem alterar o restante do sistema.
  """

  alias MeliGraph.Config

  @type result :: {:ok, [{term(), float()}]} | {:error, term()}

  @doc """
  Executa o algoritmo de recomendação.

  ## Parâmetros

    * `conf` - configuração da instância
    * `entity_id` - ID interno do vértice semente
    * `type` - tipo de recomendação (`:content`, `:users`, `:items`)
    * `opts` - opções específicas do algoritmo

  ## Retorno

  `{:ok, [{external_id, score}]}` ordenado por score decrescente,
  ou `{:error, reason}`.
  """
  @callback compute(conf :: Config.t(), entity_id :: non_neg_integer(), type :: atom(), opts :: keyword()) ::
              result()
end
