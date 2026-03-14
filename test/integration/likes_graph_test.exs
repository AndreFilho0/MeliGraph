defmodule MeliGraph.Integration.LikesGraphTest do
  @moduledoc """
  Testes de feature: grafo bipartido de likes (profile ↔ post).

  Cada like é inserido como aresta bidirecional (profile→post e post→profile),
  permitindo que os algoritmos de random walk atravessem o grafo bipartido
  e descubram posts de segundo grau (amigos de amigos curtiram X).
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias MeliGraph.DatasetLoader

  setup_all do
    {:ok, _} = MeliGraph.start_link(
      name: :likes_real,
      graph_type: :bipartite,
      testing: :sync
    )

    {:ok, stats} = DatasetLoader.load_likes(:likes_real)

    IO.puts("""

    [Likes] Grafo carregado:
      Pares únicos (profile↔post): #{stats.inserted}
      Arestas no grafo (bidirecionais): #{MeliGraph.edge_count(:likes_real)}
      Duplicatas removidas: #{stats.duplicates}
      Vértices: #{MeliGraph.vertex_count(:likes_real)}
    """)

    likes = DatasetLoader.read_likes()
    posts = DatasetLoader.read_posts()

    most_active_profile =
      likes
      |> Enum.group_by(& &1.profile_id)
      |> Enum.max_by(fn {_, list} -> length(list) end)
      |> elem(0)

    most_liked_post =
      likes
      |> Enum.group_by(& &1.post_id)
      |> Enum.max_by(fn {_, list} -> length(list) end)
      |> elem(0)

    %{
      likes: likes,
      posts: posts,
      most_active_profile: most_active_profile,
      most_liked_post: most_liked_post
    }
  end

  test "grafo bipartido carregado com arestas bidirecionais", _ctx do
    edges    = MeliGraph.edge_count(:likes_real)
    vertices = MeliGraph.vertex_count(:likes_real)

    assert edges > 0
    assert vertices > 0
    # Com arestas bidirecionais, total de arestas deve ser par
    assert rem(edges, 2) == 0, "Esperava número par de arestas (bidirecional)"

    IO.puts("  Arestas: #{edges}, Vértices: #{vertices}")
  end

  test "posts curtidos por um perfil são seus vizinhos de saída",
       %{most_active_profile: profile, likes: likes} do
    expected_posts =
      likes
      |> Enum.filter(fn %{profile_id: p} -> p == profile end)
      |> Enum.map(& &1.post_id)
      |> MapSet.new()

    actual_neighbors =
      MeliGraph.neighbors(:likes_real, profile, :outgoing, type: :like)
      |> MapSet.new()

    assert MapSet.equal?(expected_posts, actual_neighbors),
           """
           Vizinhos de saída não batem com os likes do CSV.
           Esperado:   #{inspect(MapSet.to_list(expected_posts))}
           Encontrado: #{inspect(MapSet.to_list(actual_neighbors))}
           """

    IO.puts("\n  #{profile} curtiu #{MapSet.size(expected_posts)} post(s): #{inspect(MapSet.to_list(expected_posts))}")
  end

  test "perfis que curtiram um post são seus vizinhos de saída (bidirecional)",
       %{most_liked_post: post, likes: likes} do
    expected_profiles =
      likes
      |> Enum.filter(fn %{post_id: p} -> p == post end)
      |> Enum.map(& &1.profile_id)
      |> MapSet.new()

    # Com arestas bidirecionais, post→profile fica nos vizinhos de saída do post
    actual_profiles =
      MeliGraph.neighbors(:likes_real, post, :outgoing, type: :like)
      |> MapSet.new()

    assert MapSet.equal?(expected_profiles, actual_profiles),
           """
           Quem curtiu o post não bate com o CSV.
           Esperado:   #{inspect(MapSet.to_list(expected_profiles))}
           Encontrado: #{inspect(MapSet.to_list(actual_profiles))}
           """

    IO.puts("\n  #{post} foi curtido por #{MapSet.size(expected_profiles)} perfil(s): #{inspect(MapSet.to_list(expected_profiles))}")
  end

  test "PageRank encontra posts de segundo grau via arestas bidirecionais",
       %{most_active_profile: profile, likes: likes} do
    already_liked =
      likes
      |> Enum.filter(fn %{profile_id: p} -> p == profile end)
      |> Enum.map(& &1.post_id)
      |> MapSet.new()

    {:ok, recs} = MeliGraph.recommend(
      :likes_real,
      profile,
      :content,
      algorithm: :pagerank,
      num_walks: 1000,
      walk_length: 8,
      top_k: 20
    )

    all_ids     = Enum.map(recs, fn {id, _} -> id end)
    post_recs   = Enum.filter(all_ids, &String.starts_with?(&1, "post:"))
    new_posts   = Enum.reject(post_recs, &MapSet.member?(already_liked, &1))

    IO.puts("\n  PageRank para #{profile}:")
    IO.puts("  Posts já curtidos no resultado: #{Enum.count(post_recs, &MapSet.member?(already_liked, &1))}")
    IO.puts("  Posts novos (segundo grau):     #{length(new_posts)}")

    Enum.each(recs, fn {id, score} ->
      tipo = cond do
        String.starts_with?(id, "post:") and MapSet.member?(already_liked, id) -> " [já curtiu]"
        String.starts_with?(id, "post:")    -> " [NOVO]"
        String.starts_with?(id, "profile:") -> " [perfil]"
        true -> ""
      end
      IO.puts("    #{id}  #{Float.round(score, 4)}#{tipo}")
    end)

    assert length(recs) > 0, "PageRank deve retornar resultados"

    scores = Enum.map(recs, fn {_, s} -> s end)
    assert scores == Enum.sort(scores, :desc), "Resultados devem estar ordenados por score"
  end

  test "recomendação via SALSA no grafo bipartido",
       %{most_active_profile: profile} do
    already_liked =
      MeliGraph.neighbors(:likes_real, profile, :outgoing, type: :like)
      |> MapSet.new()

    {:ok, recs} = MeliGraph.recommend(
      :likes_real,
      profile,
      :content,
      algorithm: :salsa,
      seed_size: 20,
      iterations: 5,
      top_k: 10
    )

    IO.puts("\n  SALSA para #{profile} (já curtiu #{MapSet.size(already_liked)} posts):")

    if recs == [] do
      IO.puts("    (sem recomendações — sinal insuficiente no grafo)")
    else
      Enum.each(recs, fn {id, score} ->
        tag = if MapSet.member?(already_liked, id), do: " ← já curtiu", else: ""
        IO.puts("    #{id}  score: #{Float.round(score, 4)}#{tag}")
      end)

      scores = Enum.map(recs, fn {_, s} -> s end)
      assert scores == Enum.sort(scores, :desc), "Resultados devem estar ordenados por score"
    end
  end

  test "perfil desconhecido retorna lista vazia" do
    {:ok, recs} = MeliGraph.recommend(
      :likes_real,
      "profile:999999",
      :content,
      algorithm: :pagerank
    )

    assert recs == []
  end

  test "distribuição de likes por post (posts populares vs cauda longa)" do
    likes = DatasetLoader.read_likes()

    distribution =
      likes
      |> Enum.group_by(& &1.post_id)
      |> Enum.map(fn {post, likers} -> {post, length(likers)} end)
      |> Enum.sort_by(fn {_, count} -> count end, :desc)

    IO.puts("\n  Top 5 posts mais curtidos:")
    distribution |> Enum.take(5) |> Enum.each(fn {post, count} ->
      IO.puts("    #{post}: #{count} like(s)")
    end)

    total = length(distribution)
    cauda = Enum.count(distribution, fn {_, c} -> c == 1 end)
    IO.puts("  Posts com apenas 1 like (cauda longa): #{cauda}/#{total} (#{round(cauda / total * 100)}%)")

    assert total > 0
  end
end
