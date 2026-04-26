# Avaliação do LightGCN no dataset Gowalla (formato do paper:
# He et al., SIGIR 2020).
#
# Formato esperado dos arquivos:
#   user_id item_id_1 item_id_2 ...
# Cada linha lista o usuário e todos os itens com que ele interagiu.
#
# Uso:
#
#   mix run bench/lightgcn_gowalla_eval.exs                       # defaults
#   mix run bench/lightgcn_gowalla_eval.exs -- --users 300 --epochs 250
#
# IMPORTANTE — Subamostragem
#
# A Matrix atual materializa Ã como tensor denso. Gowalla cheio tem ~70k
# nós (29858 users + 40981 items) → 70k² × 4 bytes ≈ 19 GB. Não cabe.
# Por isso o script subamostra N users com seed fixa e roda apenas o
# subgrafo deles. Os números absolutos do paper (recall=0.1830 em
# Gowalla cheio) exigem matriz sparse, planejada para v0.3.
#
# A pergunta que este script responde é:
#   "O algoritmo aprende sinal real (recall >> random) e a ponta-a-ponta
#    está correta?"

defmodule LightGCNEval do
  @moduledoc false

  def run(opts) do
    train_path = Keyword.get(opts, :train, Path.expand("~/Downloads/train.txt"))
    test_path = Keyword.get(opts, :test, Path.expand("~/Downloads/test.txt"))
    # Defaults conservadores pra rodar em minutos no Nx.BinaryBackend
    # (sem EXLA). Suba na linha de comando se tiver paciência:
    #   --users 200 --epochs 200 --dim 64
    n_users = Keyword.get(opts, :users, 30)
    epochs = Keyword.get(opts, :epochs, 30)
    embedding_dim = Keyword.get(opts, :dim, 16)
    layers = Keyword.get(opts, :layers, 3)
    learning_rate = Keyword.get(opts, :lr, 0.05)
    lambda = Keyword.get(opts, :lambda, 1.0e-4)
    batch_size = Keyword.get(opts, :batch, 256)
    seed = Keyword.get(opts, :seed, 42)
    k = Keyword.get(opts, :k, 20)

    log("dataset: lendo #{train_path}")
    train = parse(train_path)
    log("dataset: lendo #{test_path}")
    test = parse(test_path)

    full_users = map_size(train)
    full_train_edges = train |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    full_test_edges = test |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    log("dataset cheio: users=#{full_users} train_edges=#{full_train_edges} test_edges=#{full_test_edges}")

    :rand.seed(:exsss, {seed, seed, seed})

    sampled_users =
      train
      |> Map.keys()
      |> Enum.shuffle()
      |> Enum.take(n_users)
      |> MapSet.new()

    train_sub = Map.take(train, MapSet.to_list(sampled_users))
    test_sub = Map.take(test, MapSet.to_list(sampled_users))

    sub_train_edges = train_sub |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    sub_items =
      train_sub |> Map.values() |> List.flatten() |> Enum.uniq() |> length()

    test_sub =
      test_sub
      |> Enum.map(fn {u, items} ->
        # Manter só items que NÃO estão no train do mesmo user
        train_items = Map.get(train_sub, u, []) |> MapSet.new()
        {u, Enum.reject(items, &MapSet.member?(train_items, &1))}
      end)
      |> Enum.reject(fn {_u, items} -> items == [] end)
      |> Map.new()

    sub_test_edges = test_sub |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

    log(
      "subgrafo (seed=#{seed}): users=#{n_users} items=#{sub_items} " <>
        "train_edges=#{sub_train_edges} test_edges=#{sub_test_edges} " <>
        "users_com_test=#{map_size(test_sub)}"
    )

    name = :gowalla_eval

    # Garantir instância limpa caso o script já tenha rodado
    case Process.whereis(Module.concat(name, Supervisor)) do
      nil -> :ok
      pid -> Process.exit(pid, :shutdown); Process.sleep(50)
    end

    {:ok, _} =
      MeliGraph.start_link(
        name: name,
        graph_type: :bipartite,
        testing: :sync,
        segment_max_edges: 1_000_000
      )

    log("inserindo #{sub_train_edges} arestas de train no grafo...")
    {ingest_us, _} =
      :timer.tc(fn ->
        Enum.each(train_sub, fn {user, items} ->
          ext_user = "user:#{user}"

          Enum.each(items, fn item ->
            MeliGraph.insert_edge(name, ext_user, "item:#{item}", :interacted)
          end)
        end)
      end)

    log("ingestão concluída em #{Float.round(ingest_us / 1_000_000, 2)}s")

    log(
      "treinando: dim=#{embedding_dim} K=#{layers} epochs=#{epochs} " <>
        "batch=#{batch_size} lr=#{learning_rate} λ=#{lambda}"
    )

    {train_us, {:ok, binary}} =
      :timer.tc(fn ->
        MeliGraph.train_embeddings(name,
          user_prefix: "user:",
          embedding_dim: embedding_dim,
          layers: layers,
          epochs: epochs,
          batch_size: batch_size,
          learning_rate: learning_rate,
          lambda: lambda
        )
      end)

    log("treino concluído em #{Float.round(train_us / 1_000_000, 2)}s")

    :ok = MeliGraph.load_embeddings(name, binary)
    true = MeliGraph.embeddings_ready?(name)

    log("avaliando top-#{k} em #{map_size(test_sub)} users...")

    {eval_us, {recall, ndcg, precision, n}} =
      :timer.tc(fn -> evaluate(name, train_sub, test_sub, k) end)

    log("avaliação concluída em #{Float.round(eval_us / 1_000_000, 2)}s sobre n=#{n} users")

    # Baseline: recall esperado de um ranqueador aleatório uniforme.
    # Para cada user: hit_prob_per_slot ≈ |test_u| / |candidates_u|, então
    # E[hits@k] = k · hit_prob; recall = E[hits@k] / |test_u|.
    # Simplifica para k / |candidates_u|, somado e médio sobre users.
    n_items_sub = sub_items

    random_recall =
      test_sub
      |> Enum.map(fn {u, _items} ->
        train_size = Map.get(train_sub, u, []) |> length()
        candidates = max(n_items_sub - train_size, 1)
        min(k / candidates, 1.0)
      end)
      |> avg()

    IO.puts("")
    IO.puts("==========================================")
    IO.puts("  resultado — LightGCN no Gowalla (subgrafo)")
    IO.puts("==========================================")
    IO.puts("  users avaliados        : #{n}")
    IO.puts("  recall@#{k}             : #{fmt(recall)}")
    IO.puts("  ndcg@#{k}               : #{fmt(ndcg)}")
    IO.puts("  precision@#{k}          : #{fmt(precision)}")
    IO.puts("  random recall@#{k}      : #{fmt(random_recall)}")
    IO.puts("  uplift vs random       : #{fmt(safe_div(recall, random_recall))}x")
    IO.puts("==========================================")
    IO.puts("")
  end

  # --- Pipeline ---

  defp parse(path) do
    path
    |> File.stream!()
    |> Stream.map(&parse_line/1)
    |> Stream.reject(&is_nil/1)
    |> Enum.into(%{})
  end

  defp parse_line(line) do
    case String.trim(line) |> String.split(" ", trim: true) do
      [u | items] when items != [] ->
        {String.to_integer(u), Enum.map(items, &String.to_integer/1)}

      _ ->
        nil
    end
  end

  defp evaluate(name, train_sub, test_sub, k) do
    {sum_recall, sum_ndcg, sum_precision, count} =
      Enum.reduce(test_sub, {0.0, 0.0, 0.0, 0}, fn {user, test_items},
                                                   {sr, sn, sp, cnt} ->
        train_items = Map.get(train_sub, user, [])
        train_set = MapSet.new(train_items)
        test_set = MapSet.new(test_items)

        # Pedimos top_k + |train| para depois descontar items já vistos.
        request_k = k + length(train_items)

        {:ok, recs} =
          MeliGraph.recommend(name, "user:#{user}", :content,
            algorithm: :lightgcn,
            top_k: request_k
          )

        ranked =
          recs
          |> Enum.map(&item_id/1)
          |> Enum.reject(&(&1 == nil or MapSet.member?(train_set, &1)))
          |> Enum.take(k)

        hits =
          ranked
          |> Enum.with_index()
          |> Enum.filter(fn {item, _} -> MapSet.member?(test_set, item) end)

        n_test = MapSet.size(test_set)
        n_hits = length(hits)

        recall = n_hits / n_test
        precision = n_hits / k

        dcg =
          hits
          |> Enum.map(fn {_item, i} -> 1.0 / :math.log2(i + 2) end)
          |> Enum.sum()

        idcg =
          0..(min(k, n_test) - 1)
          |> Enum.map(fn i -> 1.0 / :math.log2(i + 2) end)
          |> Enum.sum()

        ndcg = if idcg == 0.0, do: 0.0, else: dcg / idcg

        {sr + recall, sn + ndcg, sp + precision, cnt + 1}
      end)

    {sum_recall / count, sum_ndcg / count, sum_precision / count, count}
  end

  defp item_id({"item:" <> rest, _score}) do
    case Integer.parse(rest) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp item_id(_), do: nil

  # --- Helpers ---

  defp avg(list) when list == [], do: 0.0

  defp avg(list) do
    Enum.sum(list) / length(list)
  end

  defp safe_div(_a, +0.0), do: 0.0
  defp safe_div(_a, -0.0), do: 0.0
  defp safe_div(a, b), do: a / b

  defp fmt(x) when is_float(x), do: :io_lib.format("~.4f", [x]) |> IO.iodata_to_binary()
  defp fmt(x), do: inspect(x)

  defp log(msg) do
    ts = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    IO.puts("[#{ts}] #{msg}")
  end
end

# --- CLI ---

defmodule LightGCNEval.CLI do
  @moduledoc false

  def parse(argv) do
    # `mix run script.exs -- --foo` deixa "--" em System.argv() e isso
    # quebra OptionParser (que para de ler switches a partir do "--").
    # Removemos para aceitar tanto a forma com quanto sem o separador.
    argv = Enum.drop_while(argv, &(&1 == "--"))

    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [
          train: :string,
          test: :string,
          users: :integer,
          epochs: :integer,
          dim: :integer,
          layers: :integer,
          lr: :float,
          lambda: :float,
          batch: :integer,
          seed: :integer,
          k: :integer
        ]
      )

    opts
  end
end

System.argv()
|> LightGCNEval.CLI.parse()
|> LightGCNEval.run()
