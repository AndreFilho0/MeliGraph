defmodule MeliGraph.LightGCN.MatrixTest do
  use ExUnit.Case, async: false

  import MeliGraph.TestHelpers

  alias MeliGraph.LightGCN.Matrix

  setup do
    name = start_test_instance()
    conf = get_conf(name)
    %{name: name, conf: conf}
  end

  describe "build/2 — casos de erro" do
    test "grafo vazio retorna :empty_graph", %{conf: conf} do
      assert {:error, :empty_graph} = Matrix.build(conf, "profile:")
    end

    test "grafo só com usuários retorna :empty_graph", %{name: name, conf: conf} do
      MeliGraph.insert_edge(name, "profile:1", "profile:2", :follow)

      assert {:error, :empty_graph} = Matrix.build(conf, "profile:")
    end

    test "grafo só com itens retorna :empty_graph", %{name: name, conf: conf} do
      MeliGraph.insert_edge(name, "post:1", "post:2", :related)

      assert {:error, :empty_graph} = Matrix.build(conf, "profile:")
    end
  end

  describe "build/2 — particionamento e shape" do
    test "separa users e items pelo prefixo", %{name: name, conf: conf} do
      MeliGraph.insert_edge(name, "profile:1", "post:a", :curtiu)
      MeliGraph.insert_edge(name, "profile:2", "post:b", :curtiu)

      assert {:ok, result} = Matrix.build(conf, "profile:")

      assert result.user_count == 2
      assert result.item_count == 2
      assert result.node_count == 4

      assert Nx.shape(result.adj_norm) == {4, 4}
    end

    test "users ocupam [0, M) e items ocupam [M, M+N)", %{name: name, conf: conf} do
      MeliGraph.insert_edge(name, "profile:1", "post:a", :curtiu)
      MeliGraph.insert_edge(name, "profile:2", "post:b", :curtiu)

      {:ok, result} = Matrix.build(conf, "profile:")

      user_rows = Map.values(result.user_index)
      item_rows = Map.values(result.item_index)

      assert Enum.sort(user_rows) == [0, 1]
      assert Enum.sort(item_rows) == [2, 3]
    end

    test "ignora arestas user→user e item→item", %{name: name, conf: conf} do
      MeliGraph.insert_edge(name, "profile:1", "post:a", :curtiu)
      MeliGraph.insert_edge(name, "profile:1", "profile:2", :follow)
      MeliGraph.insert_edge(name, "post:a", "post:b", :related)

      {:ok, result} = Matrix.build(conf, "profile:")

      # Apenas a aresta user→item é considerada — verificamos pela soma total
      # (deve ser 2: uma entrada para R[u,i] e uma para R^T[i,u])
      total = result.adj_norm |> Nx.greater(0.0) |> Nx.sum() |> Nx.to_number()
      assert total == 2
    end
  end

  describe "build/2 — simetria e normalização" do
    test "matriz é simétrica (A = A^T)", %{name: name, conf: conf} do
      MeliGraph.insert_edge(name, "profile:1", "post:a", :curtiu)
      MeliGraph.insert_edge(name, "profile:1", "post:b", :curtiu)
      MeliGraph.insert_edge(name, "profile:2", "post:a", :curtiu)

      {:ok, result} = Matrix.build(conf, "profile:")

      transposed = Nx.transpose(result.adj_norm)
      diff = Nx.subtract(result.adj_norm, transposed) |> Nx.abs() |> Nx.sum() |> Nx.to_number()

      assert_in_delta diff, 0.0, 1.0e-10
    end

    test "valor normalizado segue 1/√(deg_u · deg_i)", %{name: name, conf: conf} do
      # 2 users, 2 items
      # u1 ↔ i1, u1 ↔ i2, u2 ↔ i1
      # graus em A: u1=2, u2=1, i1=2, i2=1
      # Ã[u1, i1] = 1 / (√2 · √2) = 0.5
      # Ã[u1, i2] = 1 / (√2 · √1) = 1/√2 ≈ 0.7071
      # Ã[u2, i1] = 1 / (√1 · √2) = 1/√2 ≈ 0.7071
      MeliGraph.insert_edge(name, "profile:1", "post:a", :curtiu)
      MeliGraph.insert_edge(name, "profile:1", "post:b", :curtiu)
      MeliGraph.insert_edge(name, "profile:2", "post:a", :curtiu)

      {:ok, result} = Matrix.build(conf, "profile:")

      # Localiza índices dos nós específicos
      u1 = Map.fetch!(result.user_index, internal_id(conf, "profile:1"))
      u2 = Map.fetch!(result.user_index, internal_id(conf, "profile:2"))
      i_a = Map.fetch!(result.item_index, internal_id(conf, "post:a"))
      i_b = Map.fetch!(result.item_index, internal_id(conf, "post:b"))

      val_u1_a = adj_at(result.adj_norm, u1, i_a)
      val_u1_b = adj_at(result.adj_norm, u1, i_b)
      val_u2_a = adj_at(result.adj_norm, u2, i_a)

      assert_in_delta val_u1_a, 0.5, 1.0e-6
      assert_in_delta val_u1_b, 1.0 / :math.sqrt(2.0), 1.0e-6
      assert_in_delta val_u2_a, 1.0 / :math.sqrt(2.0), 1.0e-6
    end

    test "diagonal é zero (sem self-connection)", %{name: name, conf: conf} do
      MeliGraph.insert_edge(name, "profile:1", "post:a", :curtiu)
      MeliGraph.insert_edge(name, "profile:2", "post:b", :curtiu)

      {:ok, result} = Matrix.build(conf, "profile:")

      diag_sum = result.adj_norm |> Nx.take_diagonal() |> Nx.sum() |> Nx.to_number()
      assert diag_sum == 0.0
    end
  end

  describe "build/2 — robustez" do
    test "inserção bidirecional não duplica entries", %{name: name, conf: conf} do
      # Padrão Melivra: insere ambos os sentidos
      MeliGraph.insert_edge(name, "profile:1", "post:a", :curtiu)
      MeliGraph.insert_edge(name, "post:a", "profile:1", :curtiu)

      {:ok, result} = Matrix.build(conf, "profile:")

      # Só duas células não-zero (R[u,i] e R^T[i,u]) — não 4
      total_nonzero = result.adj_norm |> Nx.greater(0.0) |> Nx.sum() |> Nx.to_number()
      assert total_nonzero == 2
    end

    test "user_prefix vazio pega tudo como user (caso degenerado → empty_graph)", %{
      name: name,
      conf: conf
    } do
      MeliGraph.insert_edge(name, "profile:1", "post:a", :curtiu)
      assert {:error, :empty_graph} = Matrix.build(conf, "")
    end
  end

  # --- helpers ---

  defp get_conf(name) do
    registry = Module.concat(name, Registry)
    [{_pid, conf}] = Registry.lookup(registry, :conf)
    conf
  end

  defp internal_id(conf, external_id) do
    MeliGraph.Graph.IdMap.get_internal(conf, external_id)
  end

  defp adj_at(tensor, row, col) do
    tensor
    |> Nx.slice([row, col], [1, 1])
    |> Nx.reshape({})
    |> Nx.to_number()
  end
end
