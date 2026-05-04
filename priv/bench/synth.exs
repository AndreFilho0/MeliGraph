# Synthetic LightGCN benchmark.
#
#   mix run priv/bench/synth.exs                     # EXLA (default)
#   NO_EXLA=1 mix run priv/bench/synth.exs           # Nx.Defn.Evaluator
#
# Flags: --users N --items N --interactions N --epochs N --dim N

defmodule Bench do
  def run do
    {opts, _, _} =
      OptionParser.parse(System.argv(),
        strict: [
          users: :integer,
          items: :integer,
          interactions: :integer,
          epochs: :integer,
          dim: :integer
        ]
      )

    users = Keyword.get(opts, :users, 2_000)
    items = Keyword.get(opts, :items, 2_000)
    inter = Keyword.get(opts, :interactions, 20_000)
    epochs = Keyword.get(opts, :epochs, 100)
    dim = Keyword.get(opts, :dim, 64)

    backend = setup_backend()
    {:ok, _} = MeliGraph.start_link(name: :bench, graph_type: :bipartite, testing: :sync)

    IO.puts("\n== Bench LightGCN ==")
    IO.puts("  backend:   #{backend}")
    IO.puts("  users:     #{users}")
    IO.puts("  items:     #{items}")
    IO.puts("  inter:     #{inter}")
    IO.puts("  epochs:    #{epochs}")
    IO.puts("  dim:       #{dim}")
    IO.puts("  nodes:     #{users + items}  (matriz densa: #{(users + items) * (users + items) * 4} bytes)")

    weights = [0.5, 1.0, 1.5, 2.0]
    :rand.seed(:exsss, {1, 2, 3})

    {ingest_ms, _} =
      :timer.tc(fn ->
        for _ <- 1..inter do
          u = :rand.uniform(users) - 1
          i = :rand.uniform(items) - 1
          w = Enum.random(weights)
          MeliGraph.insert_edge(:bench, "profile:#{u}", "post:#{i}", :inter, w)
        end
      end)

    edges = MeliGraph.edge_count(:bench)
    IO.puts("\n  ingestão:  #{div(ingest_ms, 1000)}ms (#{edges} arestas)")

    {train_ms, result} =
      :timer.tc(fn ->
        MeliGraph.train_embeddings(:bench,
          user_prefix: "profile:",
          embedding_dim: dim,
          layers: 3,
          epochs: epochs
        )
      end)

    case result do
      {:ok, binary} ->
        train_ms = div(train_ms, 1000)
        per_epoch = Float.round(train_ms / epochs, 2)

        IO.puts("  treino:    #{train_ms}ms  (#{per_epoch}ms/época, payload #{byte_size(binary)} bytes)")
        IO.puts("")

      {:error, reason} ->
        IO.puts("  treino falhou: #{inspect(reason)}")
    end
  end

  defp setup_backend do
    case System.get_env("NO_EXLA") do
      "1" ->
        Nx.global_default_backend(Nx.BinaryBackend)
        Nx.Defn.global_default_options(compiler: Nx.Defn.Evaluator)
        "Nx.BinaryBackend (Evaluator)"

      _ ->
        case Application.ensure_all_started(:exla) do
          {:ok, _} ->
            "EXLA (compiler=#{inspect(Nx.Defn.default_options()[:compiler])})"

          {:error, reason} ->
            IO.puts("EXLA falhou: #{inspect(reason)}; caindo em BinaryBackend")
            "Nx.BinaryBackend (fallback)"
        end
    end
  end
end

Bench.run()
