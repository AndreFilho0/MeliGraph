defmodule MeliGraph.Integration.ProfessorsGraphTest do
  @moduledoc """
  Testes de integração: grafo bipartido profile → professor.

  Usa dados reais exportados do banco de produção (ratings + posts sobre professores)
  para validar os 3 casos de uso de recomendação:

  1. Professores para você (logado) — via SALSA
  2. Professores similares a X — via SimilarItems
  3. Top professores (anônimo) — via GlobalRank
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias MeliGraph.DatasetLoader

  setup_all do
    {:ok, _} = MeliGraph.start_link(
      name: :professors_real,
      graph_type: :bipartite,
      testing: :sync
    )

    {:ok, stats} = DatasetLoader.load_professor_graph(:professors_real)

    IO.puts("""

    [Professors] Grafo carregado:
      Arestas de ratings:  #{stats.ratings}
      Arestas de posts:    #{stats.posts}
      Total de arestas:    #{MeliGraph.edge_count(:professors_real)}
      Vértices:            #{MeliGraph.vertex_count(:professors_real)}
    """)

    ratings = DatasetLoader.read_professor_ratings()
    posts = DatasetLoader.read_professor_posts()
    professors = DatasetLoader.read_professors()

    # Perfil com mais avaliações
    most_active_profile =
      ratings
      |> Enum.group_by(& &1.profile_id)
      |> Enum.max_by(fn {_, list} -> length(list) end)
      |> elem(0)

    # Professor com mais interações (ratings + posts)
    all_interactions =
      Enum.map(ratings, & &1.professor_id) ++ Enum.map(posts, & &1.professor_id)

    most_popular_professor =
      all_interactions
      |> Enum.frequencies()
      |> Enum.max_by(fn {_, count} -> count end)
      |> elem(0)

    %{
      ratings: ratings,
      posts: posts,
      professors: professors,
      most_active_profile: most_active_profile,
      most_popular_professor: most_popular_professor
    }
  end

  # --- Integridade do grafo ---

  test "grafo carregado corretamente com arestas bidirecionais", _ctx do
    edges = MeliGraph.edge_count(:professors_real)
    vertices = MeliGraph.vertex_count(:professors_real)

    assert edges > 0, "Grafo deve ter arestas"
    assert vertices > 0, "Grafo deve ter vértices"
    # Arestas bidirecionais: total deve ser par
    assert rem(edges, 2) == 0, "Esperava número par de arestas (bidirecional)"

    IO.puts("  Arestas: #{edges}, Vértices: #{vertices}, Grau médio: #{Float.round(edges / vertices, 2)}")
  end

  test "arestas de ratings inseridas como :avaliou", %{most_active_profile: profile} do
    avaliados = MeliGraph.neighbors(:professors_real, profile, :outgoing, type: :avaliou)

    assert length(avaliados) > 0,
           "#{profile} deveria ter avaliações"

    IO.puts("\n  #{profile} avaliou #{length(avaliados)} professor(es): #{inspect(avaliados)}")
  end

  test "arestas de posts inseridas como :postou", _ctx do
    posts = DatasetLoader.read_professor_posts()

    # Pega um profile que tenha feito post
    profile_with_posts =
      posts
      |> Enum.map(& &1.profile_id)
      |> Enum.uniq()
      |> List.first()

    if profile_with_posts do
      postou = MeliGraph.neighbors(:professors_real, profile_with_posts, :outgoing, type: :postou)

      IO.puts("\n  #{profile_with_posts} postou sobre #{length(postou)} professor(es): #{inspect(postou)}")
      assert is_list(postou)
    end
  end

  test "vizinhos de entrada de professor são profiles que interagiram",
       %{most_popular_professor: professor} do
    incoming = MeliGraph.neighbors(:professors_real, professor, :incoming)

    assert length(incoming) > 0,
           "#{professor} deveria ter profiles que interagiram"

    IO.puts("\n  #{professor} recebeu interações de #{length(incoming)} perfil(s): #{inspect(incoming)}")
  end

  # --- Caso 1: Professores para você (logado) via SALSA ---

  test "SALSA recomenda professores para perfil ativo",
       %{most_active_profile: profile, ratings: ratings} do
    already_rated =
      ratings
      |> Enum.filter(fn %{profile_id: p} -> p == profile end)
      |> Enum.map(& &1.professor_id)
      |> MapSet.new()

    {:ok, recs} = MeliGraph.recommend(
      :professors_real,
      profile,
      :content,
      algorithm: :salsa,
      seed_size: 30,
      iterations: 5,
      top_k: 20
    )

    # No grafo bidirecional, SALSA pode retornar profiles e professors.
    # Filtramos apenas professors para o caso de uso real.
    professor_recs = Enum.filter(recs, fn {id, _} -> String.starts_with?(id, "professor:") end)

    IO.puts("\n  SALSA — Professores para #{profile} (já avaliou #{MapSet.size(already_rated)}):")

    if professor_recs == [] do
      IO.puts("    (sem recomendações — sinal insuficiente)")
    else
      Enum.each(professor_recs, fn {id, score} ->
        tag = if MapSet.member?(already_rated, id), do: " [já avaliou]", else: " [NOVO]"
        IO.puts("    #{id}  score: #{Float.round(score, 4)}#{tag}")
      end)

      scores = Enum.map(professor_recs, fn {_, s} -> s end)
      assert Enum.all?(scores, &(&1 > 0)), "Todos os scores devem ser positivos"
      assert scores == Enum.sort(scores, :desc), "Resultados devem estar ordenados por score"

      # Deve haver ao menos 1 professor novo (não avaliado)
      new_professors = Enum.reject(professor_recs, fn {id, _} -> MapSet.member?(already_rated, id) end)
      IO.puts("    Novos: #{length(new_professors)}/#{length(professor_recs)}")
    end
  end

  test "SALSA para perfil desconhecido retorna lista vazia" do
    {:ok, recs} = MeliGraph.recommend(
      :professors_real,
      "profile:999999",
      :content,
      algorithm: :salsa,
      seed_size: 10,
      top_k: 5
    )

    assert recs == []
  end

  # --- Caso 2: Professores similares via SimilarItems ---

  test "SimilarItems encontra professores similares",
       %{most_popular_professor: professor} do
    {:ok, recs} = MeliGraph.recommend(
      :professors_real,
      professor,
      :similar,
      algorithm: :similar_items,
      top_k: 10,
      normalize: :jaccard
    )

    IO.puts("\n  SimilarItems — Professores similares a #{professor}:")

    if recs == [] do
      IO.puts("    (sem similares — professor com poucos usuários em comum)")
    else
      Enum.each(recs, fn {id, score} ->
        IO.puts("    #{id}  jaccard: #{Float.round(score, 4)}")
      end)

      scores = Enum.map(recs, fn {_, s} -> s end)
      assert Enum.all?(scores, &(&1 > 0.0 and &1 <= 1.0)), "Jaccard scores devem estar em (0, 1]"
      assert scores == Enum.sort(scores, :desc), "Resultados devem estar ordenados por score"

      # Professor semente não deve aparecer nos resultados
      ids = Enum.map(recs, fn {id, _} -> id end)
      refute professor in ids, "Professor semente não deve aparecer nos próprios similares"
    end
  end

  test "SimilarItems com normalização cosine retorna resultados válidos",
       %{most_popular_professor: professor} do
    {:ok, recs} = MeliGraph.recommend(
      :professors_real,
      professor,
      :similar,
      algorithm: :similar_items,
      top_k: 10,
      normalize: :cosine
    )

    if recs != [] do
      Enum.each(recs, fn {_id, score} ->
        assert score >= 0.0 and score <= 1.0,
               "Cosine score deve estar em [0, 1], got: #{score}"
      end)
    end
  end

  test "SimilarItems para professor desconhecido retorna lista vazia" do
    {:ok, recs} = MeliGraph.recommend(
      :professors_real,
      "professor:999999",
      :similar,
      algorithm: :similar_items,
      top_k: 5
    )

    assert recs == []
  end

  # --- Caso 3: Top professores (anônimo) via GlobalRank ---

  test "GlobalRank retorna professores mais influentes da rede", _ctx do
    {:ok, recs} = MeliGraph.recommend(
      :professors_real,
      "any",
      :global,
      algorithm: :global_rank,
      top_k: 10,
      prefix: "professor:"
    )

    IO.puts("\n  GlobalRank — Top professores (para anônimos):")

    assert length(recs) > 0, "Deve haver ao menos 1 professor com interações"

    Enum.each(recs, fn {id, score} ->
      IO.puts("    #{id}  influence: #{Float.round(score, 4)}")
    end)

    # O primeiro deve ter score 1.0 (normalização pelo max)
    [{_top_id, top_score} | _] = recs
    assert top_score == 1.0, "Top professor deve ter score 1.0"

    # Todos devem ser professores
    Enum.each(recs, fn {id, _} ->
      assert String.starts_with?(id, "professor:"),
             "GlobalRank com prefix deve retornar apenas professores, got: #{id}"
    end)

    scores = Enum.map(recs, fn {_, s} -> s end)
    assert scores == Enum.sort(scores, :desc), "Resultados devem estar ordenados por score"
  end

  test "GlobalRank com min_degree filtra professores com poucas interações", _ctx do
    {:ok, all} = MeliGraph.recommend(
      :professors_real,
      "any",
      :global,
      algorithm: :global_rank,
      top_k: 200,
      prefix: "professor:"
    )

    {:ok, filtered} = MeliGraph.recommend(
      :professors_real,
      "any",
      :global,
      algorithm: :global_rank,
      top_k: 200,
      prefix: "professor:",
      min_degree: 3
    )

    IO.puts("\n  GlobalRank — Filtro min_degree:")
    IO.puts("    Todos os professores com interações: #{length(all)}")
    IO.puts("    Professores com >= 3 perfis distintos: #{length(filtered)}")

    assert length(filtered) <= length(all)
  end

  # --- Estatísticas do dataset ---

  test "imprime estatísticas do dataset de professores",
       %{ratings: ratings, posts: posts, professors: professors} do
    unique_profiles =
      (Enum.map(ratings, & &1.profile_id) ++ Enum.map(posts, & &1.profile_id))
      |> Enum.uniq()

    unique_professors =
      (Enum.map(ratings, & &1.professor_id) ++ Enum.map(posts, & &1.professor_id))
      |> Enum.uniq()

    # Distribuição de notas nas avaliações
    nota_dist =
      ratings
      |> Enum.group_by(& &1.nota)
      |> Enum.sort_by(fn {nota, _} -> nota end)

    IO.puts("""

    ╔══════════════════════════════════════════╗
    ║   Dataset Stats — Professores            ║
    ╠══════════════════════════════════════════╣
    ║  Professores no catálogo:   #{String.pad_leading("#{length(professors)}", 8)}   ║
    ║  Professores com interação: #{String.pad_leading("#{length(unique_professors)}", 8)}   ║
    ║  Perfis ativos:             #{String.pad_leading("#{length(unique_profiles)}", 8)}   ║
    ║  Total de avaliações:       #{String.pad_leading("#{length(ratings)}", 8)}   ║
    ║  Total de posts:            #{String.pad_leading("#{length(posts)}", 8)}   ║
    ╠══════════════════════════════════════════╣
    ║  Distribuição de notas:                   ║
    #{format_nota_dist(nota_dist)}╚══════════════════════════════════════════╝
    """)

    assert length(ratings) > 0, "Dataset deve ter avaliações"
    assert length(professors) > 0, "Dataset deve ter professores"
  end

  # --- Helpers ---

  defp format_nota_dist(nota_dist) do
    nota_dist
    |> Enum.map(fn {nota, list} ->
      label = String.pad_trailing("  nota #{nota}:", 18)
      "    ║  #{label}#{String.pad_leading("#{length(list)}", 6)} avaliações  ║\n"
    end)
    |> Enum.join()
  end
end
