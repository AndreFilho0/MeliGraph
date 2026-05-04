defmodule Mix.Tasks.MeliGraph.Demo do
  @moduledoc """
  Demo end-to-end: lê um dataset TSV (formato heterogêneo descrito no README),
  insere as arestas com peso no grafo, treina embeddings LightGCN e imprime
  recomendações top-K para um perfil.

  ## Uso

      mix meli_graph.demo --data PATH --profile PROFILE_ID [opções]

  ## Opções

    * `--data PATH`     — diretório com os TSVs (obrigatório)
    * `--profile ID`    — profile_id alvo da recomendação (obrigatório)
    * `--epochs N`      — épocas de treino (default 500)
    * `--top-k N`       — número de recomendações (default 20)
    * `--embedding-dim N` — dimensão dos embeddings (default 64)
    * `--layers N`      — camadas LGC (default 3)
    * `--exclude-seen`  — filtra itens já interagidos (emula pipeline de feed)

  ## Arquivos esperados em `--data`

      users.tsv          user_idx \\t profile_id           (com header)
      items.tsv          item_idx \\t tipo \\t db_id        (com header)
      interactions.tsv   user_idx \\t item_idx \\t weight \\t inserted_at  (com header)

  ## Exemplo

      mix meli_graph.demo \\
        --data /home/dede/pessoal/melivra/priv/lightgcn/data \\
        --profile 166
  """
  use Mix.Task

  @shortdoc "Treina LightGCN num dataset TSV e recomenda top-K para um profile"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          data: :string,
          profile: :integer,
          epochs: :integer,
          top_k: :integer,
          embedding_dim: :integer,
          layers: :integer,
          exclude_seen: :boolean
        ]
      )

    data = opts[:data] || Mix.raise("--data PATH é obrigatório")
    profile = opts[:profile] || Mix.raise("--profile ID é obrigatório")
    epochs = Keyword.get(opts, :epochs, 500)
    top_k = Keyword.get(opts, :top_k, 20)
    embedding_dim = Keyword.get(opts, :embedding_dim, 64)
    layers = Keyword.get(opts, :layers, 3)
    exclude_seen? = Keyword.get(opts, :exclude_seen, false)

    Mix.Task.run("app.start")
    maybe_start_exla()

    Mix.shell().info("== Carregando dataset em #{data} ==")
    users = parse_users(Path.join(data, "users.tsv"))
    items = parse_items(Path.join(data, "items.tsv"))
    interactions = parse_interactions(Path.join(data, "interactions.tsv"))

    Mix.shell().info("  users: #{map_size(users)}")
    Mix.shell().info("  items: #{map_size(items)}")
    Mix.shell().info("  interactions: #{length(interactions)}")

    by_type =
      items
      |> Map.values()
      |> Enum.frequencies_by(fn {tipo, _id} -> tipo end)

    Mix.shell().info("  itens por tipo: #{inspect(by_type)}")

    Mix.shell().info("\n== Iniciando instância MeliGraph ==")
    name = :demo

    {:ok, _sup} =
      MeliGraph.start_link(
        name: name,
        graph_type: :bipartite,
        testing: :sync,
        segment_max_edges: 1_000_000
      )

    Mix.shell().info("== Inserindo arestas com peso ==")

    Enum.each(interactions, fn {user_idx, item_idx, weight} ->
      profile_id = Map.fetch!(users, user_idx)
      {tipo, db_id} = Map.fetch!(items, item_idx)

      MeliGraph.insert_edge(
        name,
        "profile:#{profile_id}",
        "#{tipo}:#{db_id}",
        :interaction,
        weight
      )
    end)

    Mix.shell().info("  arestas no grafo: #{MeliGraph.edge_count(name)}")
    Mix.shell().info("  vértices: #{MeliGraph.vertex_count(name)}")

    Mix.shell().info(
      "\n== Treinando LightGCN (dim=#{embedding_dim}, K=#{layers}, epochs=#{epochs}) =="
    )

    started_at = System.monotonic_time(:millisecond)

    {:ok, binary} =
      MeliGraph.train_embeddings(name,
        user_prefix: "profile:",
        embedding_dim: embedding_dim,
        layers: layers,
        epochs: epochs
      )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    Mix.shell().info("  treino completo em #{elapsed_ms}ms (payload #{byte_size(binary)} bytes)")

    :ok = MeliGraph.load_embeddings(name, binary)
    true = MeliGraph.embeddings_ready?(name)

    Mix.shell().info("\n== Top-#{top_k} recomendações para profile:#{profile} ==")
    profile_key = "profile:#{profile}"

    seen =
      interactions
      |> Enum.filter(fn {u, _i, _w} -> users[u] == profile end)
      |> Enum.map(fn {_u, i, _w} ->
        {tipo, db_id} = items[i]
        "#{tipo}:#{db_id}"
      end)
      |> MapSet.new()

    # Quando excluindo seen, peço top_k + |seen| pro modelo e filtro depois,
    # garantindo `top_k` itens novos no resultado final.
    request_k = if exclude_seen?, do: top_k + MapSet.size(seen), else: top_k

    case MeliGraph.recommend(name, profile_key, :content,
           algorithm: :lightgcn,
           top_k: request_k
         ) do
      {:ok, []} ->
        Mix.shell().info("  (vazio — usuário não estava no grafo no momento do treino)")

      {:ok, raw_recs} ->
        recs =
          if exclude_seen? do
            raw_recs
            |> Enum.reject(fn {item_id, _} -> MapSet.member?(seen, item_id) end)
            |> Enum.take(top_k)
          else
            raw_recs
          end

        if exclude_seen? do
          Mix.shell().info("  (filtrando #{MapSet.size(seen)} itens já interagidos)\n")
        else
          Mix.shell().info("  (* = item já interagido pelo profile)\n")
        end

        Mix.shell().info(
          "  #{String.pad_trailing("rank", 5)}#{String.pad_trailing("item", 18)}#{String.pad_trailing("score", 12)}seen?"
        )

        Mix.shell().info("  " <> String.duplicate("-", 45))

        recs
        |> Enum.with_index(1)
        |> Enum.each(fn {{item_id, score}, rank} ->
          mark = if MapSet.member?(seen, item_id), do: "*", else: " "
          rank_s = String.pad_trailing("#{rank}", 5)
          item_s = String.pad_trailing(to_string(item_id), 18)
          score_s = String.pad_trailing(:io_lib.format("~.4f", [score]) |> to_string(), 12)
          Mix.shell().info("  #{rank_s}#{item_s}#{score_s}#{mark}")
        end)

        # Quebra do ranking por tipo (post / review / ad)
        by_type_count =
          recs
          |> Enum.frequencies_by(fn {item_id, _} ->
            item_id |> String.split(":") |> hd()
          end)

        Mix.shell().info("\n  composição do top-#{top_k}: #{inspect(by_type_count)}")

      {:error, reason} ->
        Mix.shell().error("  erro: #{inspect(reason)}")
    end
  end

  # --- TSV parsing ---

  defp parse_users(path) do
    path
    |> stream_data_lines()
    |> Enum.reduce(%{}, fn line, acc ->
      [user_idx, profile_id] = String.split(line, "\t")
      Map.put(acc, String.to_integer(user_idx), String.to_integer(profile_id))
    end)
  end

  defp parse_items(path) do
    path
    |> stream_data_lines()
    |> Enum.reduce(%{}, fn line, acc ->
      [item_idx, tipo, db_id] = String.split(line, "\t")
      Map.put(acc, String.to_integer(item_idx), {tipo, String.to_integer(db_id)})
    end)
  end

  defp parse_interactions(path) do
    path
    |> stream_data_lines()
    |> Enum.map(fn line ->
      [user_idx, item_idx, weight, _inserted_at] = String.split(line, "\t")
      {String.to_integer(user_idx), String.to_integer(item_idx), parse_float(weight)}
    end)
  end

  defp stream_data_lines(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim_trailing/1)
    |> Stream.reject(&(&1 == ""))
    |> Stream.drop(1)
  end

  defp parse_float(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> raise "valor de peso inválido: #{inspect(s)}"
    end
  end

  # EXLA é optional: true → não inicia via app.start. Sobe manualmente quando
  # disponível para que o trainer JIT-compile via XLA em vez de cair no
  # Nx.BinaryBackend.
  defp maybe_start_exla do
    if Code.ensure_loaded?(EXLA) do
      case Application.ensure_all_started(:exla) do
        {:ok, _} ->
          Mix.shell().info("  EXLA: ON (compiler=#{inspect(Nx.Defn.default_options()[:compiler])})")

        {:error, reason} ->
          Mix.shell().info("  EXLA: falhou ao iniciar (#{inspect(reason)}) — usando Nx.BinaryBackend")
      end
    else
      Mix.shell().info("  EXLA: indisponível — usando Nx.BinaryBackend (lento)")
    end
  end
end
