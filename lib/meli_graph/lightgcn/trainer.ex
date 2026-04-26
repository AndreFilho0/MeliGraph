defmodule MeliGraph.LightGCN.Trainer do
  @moduledoc """
  Loop de treinamento do LightGCN.

  Lê o estado atual do grafo via `MeliGraph.LightGCN.Matrix.build/2`,
  inicializa os embeddings de camada 0 com Xavier, treina via BPR loss
  + Adam usando `Nx.Defn` para autodiferenciação, e devolve um binary
  serializado pronto para ser persistido pela aplicação caller.

  Esta lib **não persiste nada**. O binary retornado deve ser salvo pelo
  caller (Postgres / R2 / S3) e recarregado depois via
  `MeliGraph.LightGCN.EmbeddingStore.load/2`.

  ## Hiperparâmetros

  | Opção | Default | Referência |
  |-------|---------|------------|
  | `:embedding_dim` | 64 | paper §4.1.2 |
  | `:layers` | 3 | paper §4.2 |
  | `:epochs` | 1000 | paper §4.1.2 |
  | `:batch_size` | 1024 | paper §4.1.2 |
  | `:learning_rate` | 0.001 | Adam default |
  | `:lambda` | 1.0e-4 | paper §4.1.2 |

  ## Negative sampling

  Usamos sampling uniforme (qualquer item aleatório como negativo).
  Em grafos esparsos isso pode gerar falsos negativos ocasionais — o
  paper aceita isso explicitamente como trade-off em troca de
  simplicidade. Estratégias mais sofisticadas (hard negative,
  adversarial) ficam para v0.3+.
  """

  import Nx.Defn

  require Logger

  alias MeliGraph.Config
  alias MeliGraph.LightGCN.Matrix

  @default_embedding_dim 64
  @default_layers 3
  @default_epochs 1000
  @default_batch_size 1024
  @default_learning_rate 0.001
  @default_lambda 1.0e-4

  @doc """
  Treina embeddings LightGCN no grafo apontado por `conf`.

  Retorna `{:ok, binary}` com o payload serializado:

      %{
        version: 1,
        embeddings: Nx.tensor() {node_count, embedding_dim},
        user_index: %{internal_id => row_index},
        item_index: %{internal_id => row_index},
        user_count: integer,
        item_count: integer,
        trained_at: unix_timestamp
      }

  Retorna `{:error, :empty_graph}` quando não há arestas user↔item
  suficientes para construir Ã.
  """
  @spec train(Config.t(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def train(%Config{} = conf, user_prefix, opts \\ []) when is_binary(user_prefix) do
    case Matrix.build(conf, user_prefix) do
      {:ok, matrix_data} -> do_train(matrix_data, opts)
      {:error, _} = err -> err
    end
  end

  # --- Private ---

  defp do_train(matrix_data, opts) do
    embedding_dim = Keyword.get(opts, :embedding_dim, @default_embedding_dim)
    layers = Keyword.get(opts, :layers, @default_layers)
    epochs = Keyword.get(opts, :epochs, @default_epochs)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    learning_rate = Keyword.get(opts, :learning_rate, @default_learning_rate)
    lambda = Keyword.get(opts, :lambda, @default_lambda)

    %{
      adj_norm: adj,
      positive_pairs: pairs,
      user_count: user_count,
      item_count: item_count,
      node_count: node_count
    } = matrix_data

    e0 = xavier_init(node_count, embedding_dim)
    adam_m = Nx.broadcast(0.0, {node_count, embedding_dim})
    adam_v = Nx.broadcast(0.0, {node_count, embedding_dim})

    pair_count = length(pairs)
    effective_batch = min(batch_size, pair_count)

    pair_users_t = pairs |> Enum.map(fn {u, _i} -> u end) |> Nx.tensor(type: :s64)
    pair_items_t = pairs |> Enum.map(fn {_u, i} -> i end) |> Nx.tensor(type: :s64)

    Logger.debug(
      "[LightGCN.Trainer] start nodes=#{node_count} pairs=#{pair_count} " <>
        "dim=#{embedding_dim} K=#{layers} epochs=#{epochs} batch=#{effective_batch}"
    )

    {final_e0, _adam_m, _adam_v} =
      Enum.reduce(1..epochs, {e0, adam_m, adam_v}, fn epoch, {e0_acc, m_acc, v_acc} ->
        batch_idx = sample_indices(pair_count, effective_batch)
        batch_users = Nx.take(pair_users_t, batch_idx)
        batch_pos = Nx.take(pair_items_t, batch_idx)
        batch_neg = sample_negatives(user_count, item_count, effective_batch)

        {loss, grad} =
          loss_and_grad(e0_acc, adj, batch_users, batch_pos, batch_neg, lambda, layers)

        {new_e0, new_m, new_v} =
          adam_step(e0_acc, m_acc, v_acc, grad, learning_rate, epoch)

        if rem(epoch, 100) == 0 or epoch == 1 or epoch == epochs do
          Logger.debug("[LightGCN.Trainer] epoch=#{epoch} loss=#{Nx.to_number(loss)}")
        end

        {new_e0, new_m, new_v}
      end)

    final_embeddings = propagate(final_e0, adj, layers)
    binary = encode_payload(final_embeddings, matrix_data)
    {:ok, binary}
  end

  # --- defn (autodiff path) ---

  defn loss_and_grad(e0, adj, batch_users, batch_pos, batch_neg, lambda, layers) do
    value_and_grad(e0, fn e0_var ->
      e_final = propagate(e0_var, adj, layers)

      e_u = Nx.take(e_final, batch_users)
      e_pos = Nx.take(e_final, batch_pos)
      e_neg = Nx.take(e_final, batch_neg)

      score_pos = Nx.sum(e_u * e_pos, axes: [1])
      score_neg = Nx.sum(e_u * e_neg, axes: [1])

      diff = score_pos - score_neg
      bpr = -Nx.mean(Nx.log(Nx.sigmoid(diff) + 1.0e-10))
      reg = lambda * Nx.mean(e0_var * e0_var)

      bpr + reg
    end)
  end

  # Propagação LGC + layer combination.
  # Computa: sum_{k=0}^{layers} Ã^k · E0  e  divide por (layers + 1).
  #
  # Em defn, variáveis externas referenciadas dentro de `while` precisam
  # ser passadas explicitamente na tupla — daí `adj` e `layers` aparecerem
  # na tupla mesmo sendo "constantes" da perspectiva do loop.
  defn propagate(e0, adj, layers) do
    {_e_curr, sum_layers, _i, _adj, _layers} =
      while {e_curr = e0, sum = e0, i = 0, adj, layers}, i < layers do
        e_next = Nx.dot(adj, e_curr)
        {e_next, sum + e_next, i + 1, adj, layers}
      end

    sum_layers / (layers + 1)
  end

  # Adam optimizer (manual).
  defn adam_step(e0, m, v, grad, lr, t) do
    beta1 = 0.9
    beta2 = 0.999
    epsilon = 1.0e-8

    m_new = beta1 * m + (1.0 - beta1) * grad
    v_new = beta2 * v + (1.0 - beta2) * grad * grad

    bias1 = 1.0 - Nx.pow(beta1, t)
    bias2 = 1.0 - Nx.pow(beta2, t)

    m_hat = m_new / bias1
    v_hat = v_new / bias2

    e0_new = e0 - lr * m_hat / (Nx.sqrt(v_hat) + epsilon)

    {e0_new, m_new, v_new}
  end

  # --- Elixir helpers ---

  # Xavier uniform: U(-a, a) onde a = sqrt(6 / (fan_in + fan_out)).
  defp xavier_init(rows, cols) do
    limit = :math.sqrt(6.0 / (rows + cols))
    data = for _ <- 1..(rows * cols), do: (:rand.uniform() * 2.0 - 1.0) * limit
    data |> Nx.tensor(type: :f32) |> Nx.reshape({rows, cols})
  end

  defp sample_indices(num_pairs, batch_size) do
    indices = for _ <- 1..batch_size, do: :rand.uniform(num_pairs) - 1
    Nx.tensor(indices, type: :s64)
  end

  # Sample negative items uniformly from [user_count, user_count + item_count).
  # Falsos negativos (item realmente interagido) são raros em grafos não-triviais
  # e tolerados pelo BPR — paper §3.3.
  defp sample_negatives(user_count, item_count, batch_size) do
    items =
      for _ <- 1..batch_size do
        user_count + :rand.uniform(item_count) - 1
      end

    Nx.tensor(items, type: :s64)
  end

  # Serializa payload usando :erlang.term_to_binary com tensor copiado para
  # BinaryBackend para garantir portabilidade entre ambientes (CPU/EXLA).
  defp encode_payload(embeddings, matrix_data) do
    embeddings_cpu = Nx.backend_copy(embeddings, Nx.BinaryBackend)

    payload = %{
      version: 1,
      embeddings: embeddings_cpu,
      user_index: matrix_data.user_index,
      item_index: matrix_data.item_index,
      user_count: matrix_data.user_count,
      item_count: matrix_data.item_count,
      trained_at: System.os_time(:second)
    }

    :erlang.term_to_binary(payload)
  end
end
