defmodule MeliGraph.TestHelpers do
  @moduledoc """
  Helpers compartilhados entre os testes.
  """

  @doc """
  Gera um nome único para instâncias de teste, evitando colisões de ETS/Registry.
  """
  def unique_name do
    :"test_#{System.unique_integer([:positive, :monotonic])}"
  end

  @doc """
  Inicia uma instância MeliGraph para teste com configuração padrão.
  Retorna o nome da instância.
  """
  def start_test_instance(opts \\ []) do
    name = Keyword.get_lazy(opts, :name, &unique_name/0)

    default_opts = [
      name: name,
      graph_type: :bipartite,
      testing: :sync,
      segment_max_edges: 100
    ]

    merged = Keyword.merge(default_opts, opts)
    {:ok, _pid} = MeliGraph.start_link(merged)
    name
  end
end
