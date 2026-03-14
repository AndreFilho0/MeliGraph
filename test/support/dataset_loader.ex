defmodule MeliGraph.DatasetLoader do
  @moduledoc """
  Carrega os CSVs exportados do banco de produção para instâncias MeliGraph.

  Os arquivos devem estar em `tmp/` na raiz do projeto.
  Para alterar o caminho, passe `base_path:` nas opções.

  ## Observações sobre o dataset

  - `likes.csv` contém entradas duplicadas (mesmo profile+post em cliques rápidos).
    O loader deduplica por `{profile_id, post_id}` antes de inserir.
  - `follows.csv` representa o grafo social dirigido (quem segue quem).
  - `posts.csv` contém metadados dos posts (autor, categoria, tipo).
  """

  @default_base_path Path.join([File.cwd!(), "tmp"])

  # --- Follows ---

  @doc """
  Carrega o grafo de follows (profile → profile, aresta :follow).
  Retorna `{:ok, %{inserted: n, skipped: n}}`.
  """
  def load_follows(graph_name, opts \\ []) do
    path = csv_path("meli_graph_follows.csv", opts)

    rows =
      path
      |> stream_csv()
      |> Enum.to_list()

    Enum.each(rows, fn row ->
      from = "profile:#{row["from_profile_id"]}"
      to   = "profile:#{row["to_profile_id"]}"
      MeliGraph.insert_edge(graph_name, from, to, :follow)
    end)

    {:ok, %{inserted: length(rows)}}
  end

  @doc """
  Retorna as arestas de follows como lista de `%{from: id, to: id}`.
  """
  def read_follows(opts \\ []) do
    csv_path("meli_graph_follows.csv", opts)
    |> stream_csv()
    |> Enum.map(fn row ->
      %{
        from: "profile:#{row["from_profile_id"]}",
        to:   "profile:#{row["to_profile_id"]}",
        inserted_at: row["inserted_at"]
      }
    end)
  end

  # --- Likes ---

  @doc """
  Carrega o grafo de likes (profile → post, aresta :like).
  Deduplica entradas com mesmo `{profile_id, post_id}` antes de inserir.
  Retorna `{:ok, %{inserted: n, duplicates: n}}`.
  """
  def load_likes(graph_name, opts \\ []) do
    path = csv_path("meli_graph_likes.csv", opts)

    all_rows = path |> stream_csv() |> Enum.to_list()

    unique_rows =
      all_rows
      |> Enum.uniq_by(fn row -> {row["profile_id"], row["post_id"]} end)

    Enum.each(unique_rows, fn row ->
      profile = "profile:#{row["profile_id"]}"
      post    = "post:#{row["post_id"]}"
      MeliGraph.insert_edge(graph_name, profile, post, :like)
      MeliGraph.insert_edge(graph_name, post, profile, :like)
    end)

    {:ok, %{inserted: length(unique_rows), duplicates: length(all_rows) - length(unique_rows)}}
  end

  @doc """
  Retorna as arestas de likes únicas como lista de `%{profile_id: id, post_id: id}`.
  """
  def read_likes(opts \\ []) do
    csv_path("meli_graph_likes.csv", opts)
    |> stream_csv()
    |> Enum.uniq_by(fn row -> {row["profile_id"], row["post_id"]} end)
    |> Enum.map(fn row ->
      %{
        profile_id: "profile:#{row["profile_id"]}",
        post_id:    "post:#{row["post_id"]}"
      }
    end)
  end

  # --- Posts ---

  @doc """
  Retorna metadados dos posts como lista de maps.
  """
  def read_posts(opts \\ []) do
    csv_path("meli_graph_posts.csv", opts)
    |> stream_csv()
    |> Enum.map(fn row ->
      %{
        post_id:       "post:#{row["post_id"]}",
        profile_id:    "profile:#{row["profile_id"]}",
        likes_count:   parse_int(row["likes_count"]),
        reposts_count: parse_int(row["reposts_count"]),
        category:      row["category"],
        type:          row["type"],
        inserted_at:   row["inserted_at"]
      }
    end)
  end

  # --- Professores ---

  @doc """
  Carrega o grafo bipartido de interações profile ↔ professor a partir de
  ratings e posts sobre professores. Cada interação é inserida como aresta
  bidirecional (profile → professor e professor → profile), permitindo
  que random walks (PageRank/SALSA) atravessem o grafo bipartido.

  Deduplica por `{profile_id, professor_id}` em cada fonte.
  Retorna `{:ok, %{ratings: n, posts: n, total_edges: n}}`.
  """
  def load_professor_graph(graph_name, opts \\ []) do
    ratings_count = load_professor_ratings(graph_name, opts)
    posts_count = load_professor_posts(graph_name, opts)

    {:ok, %{ratings: ratings_count, posts: posts_count, total_edges: ratings_count + posts_count}}
  end

  defp load_professor_ratings(graph_name, opts) do
    path = csv_path("meli_graph_professor_ratings.csv", opts)

    rows =
      path
      |> stream_csv()
      |> Enum.uniq_by(fn row -> {row["profile_id"], row["professor_id"]} end)

    Enum.each(rows, fn row ->
      profile   = "profile:#{row["profile_id"]}"
      professor = "professor:#{row["professor_id"]}"
      MeliGraph.insert_edge(graph_name, profile, professor, :avaliou)
      MeliGraph.insert_edge(graph_name, professor, profile, :avaliou)
    end)

    length(rows)
  end

  defp load_professor_posts(graph_name, opts) do
    path = csv_path("meli_graph_professor_posts.csv", opts)

    rows =
      path
      |> stream_csv()
      |> Enum.uniq_by(fn row -> {row["profile_id"], row["professor_id"]} end)

    Enum.each(rows, fn row ->
      profile   = "profile:#{row["profile_id"]}"
      professor = "professor:#{row["professor_id"]}"
      MeliGraph.insert_edge(graph_name, profile, professor, :postou)
      MeliGraph.insert_edge(graph_name, professor, profile, :postou)
    end)

    length(rows)
  end

  @doc """
  Carrega o grafo bipartido de interações profile ↔ professor (formato antigo).
  Mantido para compatibilidade com testes existentes.
  """
  def load_professor_interactions(graph_name, opts \\ []) do
    path = csv_path("meli_graph_profile_professor.csv", opts)

    all_rows = path |> stream_csv() |> Enum.to_list()

    unique_rows =
      all_rows
      |> Enum.uniq_by(fn row -> {row["profile_id"], row["professor_id"]} end)

    Enum.each(unique_rows, fn row ->
      profile   = "profile:#{row["profile_id"]}"
      professor = "professor:#{row["professor_id"]}"
      MeliGraph.insert_edge(graph_name, profile, professor, :liked_professor)
      MeliGraph.insert_edge(graph_name, professor, profile, :liked_professor)
    end)

    {:ok, %{inserted: length(unique_rows), duplicates: length(all_rows) - length(unique_rows)}}
  end

  @doc """
  Retorna as avaliações como lista de maps.
  """
  def read_professor_ratings(opts \\ []) do
    csv_path("meli_graph_professor_ratings.csv", opts)
    |> stream_csv()
    |> Enum.map(fn row ->
      %{
        profile_id:   "profile:#{row["profile_id"]}",
        professor_id: "professor:#{row["professor_id"]}",
        nota:         parse_int(row["nota"]),
        inserted_at:  row["inserted_at"]
      }
    end)
  end

  @doc """
  Retorna os posts sobre professores como lista de maps.
  """
  def read_professor_posts(opts \\ []) do
    csv_path("meli_graph_professor_posts.csv", opts)
    |> stream_csv()
    |> Enum.map(fn row ->
      %{
        profile_id:   "profile:#{row["profile_id"]}",
        professor_id: "professor:#{row["professor_id"]}",
        post_id:      "post:#{row["post_id"]}",
        likes_count:  parse_int(row["likes_count"]),
        type:         row["type"],
        inserted_at:  row["inserted_at"]
      }
    end)
  end

  @doc """
  Retorna as interações profile→professor únicas como lista de maps (formato antigo).
  """
  def read_professor_interactions(opts \\ []) do
    csv_path("meli_graph_profile_professor.csv", opts)
    |> stream_csv()
    |> Enum.uniq_by(fn row -> {row["profile_id"], row["professor_id"]} end)
    |> Enum.map(fn row ->
      %{
        profile_id:   "profile:#{row["profile_id"]}",
        professor_id: "professor:#{row["professor_id"]}"
      }
    end)
  end

  @doc """
  Retorna os metadados dos professores como lista de maps, ordenados por nota.
  """
  def read_professors(opts \\ []) do
    csv_path("meli_graph_professors.csv", opts)
    |> stream_csv()
    |> Enum.map(fn row ->
      %{
        professor_id:   "professor:#{row["id"]}",
        nome:           row["nome_professor"],
        instituto:      row["instituto"],
        nota:           parse_int(row["nota"]),
        qts_avaliacao:  parse_int(row["qts_avaliacao"]),
        instituto_id:   row["instituto_id"]
      }
    end)
    |> Enum.sort_by(& &1.nota, :desc)
  end

  # --- Estatísticas ---

  @doc """
  Retorna um mapa com estatísticas do dataset:
  profiles únicos, posts únicos, follows únicos, likes únicos.
  """
  def stats do
    follows = read_follows()
    likes   = read_likes()
    posts   = read_posts()

    follow_profiles =
      Enum.flat_map(follows, fn %{from: f, to: t} -> [f, t] end)
      |> Enum.uniq()

    like_profiles =
      likes |> Enum.map(& &1.profile_id) |> Enum.uniq()

    %{
      follows:          length(follows),
      likes:            length(likes),
      posts:            length(posts),
      unique_profiles:  Enum.uniq(follow_profiles ++ like_profiles) |> length(),
      post_types:       posts |> Enum.group_by(& &1.type) |> Map.new(fn {k, v} -> {k, length(v)} end)
    }
  end

  # --- Private ---

  defp stream_csv(path) do
    path
    |> File.stream!()
    |> CSV.decode!(headers: true)
  end

  defp csv_path(filename, opts) do
    base = Keyword.get(opts, :base_path, @default_base_path)
    Path.join(base, filename)
  end

  defp parse_int(nil), do: 0
  defp parse_int(""), do: 0
  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 0
    end
  end
end
