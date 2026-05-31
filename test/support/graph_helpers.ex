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

  @doc """
  Alvo de MFA `on_ready`: insere um conjunto fixo de 3 arestas na instância.
  Usado para exercitar o rebuild do Bootstrapper em testes.
  """
  def seed_edges(name) do
    MeliGraph.insert_edge(name, "user:1", "post:a", :like)
    MeliGraph.insert_edge(name, "user:1", "post:b", :like)
    MeliGraph.insert_edge(name, "user:2", "post:a", :like)
    :ok
  end

  @doc """
  Espera (com polling) até `fun.()` retornar `true` ou estourar o timeout (ms).
  """
  def wait_until(fun, timeout \\ 1_000)
  def wait_until(_fun, timeout) when timeout <= 0, do: false

  def wait_until(fun, timeout) do
    if fun.() do
      true
    else
      Process.sleep(10)
      wait_until(fun, timeout - 10)
    end
  end
end
