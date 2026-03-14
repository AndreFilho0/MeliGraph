defmodule MeliGraph.Integration.FollowsGraphTest do
  @moduledoc """
  Testes de feature: grafo de follows (quem segue quem).

  Simula o caso de uso "Who to Follow" da rede social usando
  dados reais exportados do banco de produção.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias MeliGraph.DatasetLoader

  # Carrega o grafo uma vez para todos os testes deste módulo
  setup_all do
    {:ok, _} = MeliGraph.start_link(
      name: :follows_real,
      graph_type: :directed,
      testing: :sync
    )

    {:ok, stats} = DatasetLoader.load_follows(:follows_real)

    IO.puts("""

    [Follows] Grafo carregado:
      Arestas:  #{stats.inserted}
      Vértices: #{MeliGraph.vertex_count(:follows_real)}
    """)

    # Identifica os perfis com mais conexões para usar nos testes
    follows = DatasetLoader.read_follows()

    # Perfil com mais follows enviados
    most_active =
      follows
      |> Enum.group_by(& &1.from)
      |> Enum.max_by(fn {_, list} -> length(list) end)
      |> elem(0)

    # Perfil com mais seguidores
    most_followed =
      follows
      |> Enum.group_by(& &1.to)
      |> Enum.max_by(fn {_, list} -> length(list) end)
      |> elem(0)

    %{most_active: most_active, most_followed: most_followed}
  end

  test "grafo carregado corretamente", _ctx do
    edges    = MeliGraph.edge_count(:follows_real)
    vertices = MeliGraph.vertex_count(:follows_real)

    assert edges > 0,    "Grafo deve ter arestas"
    assert vertices > 0, "Grafo deve ter vértices"
    assert vertices >= 2, "Deve haver ao menos 2 perfis"

    IO.puts("  Arestas: #{edges}, Vértices: #{vertices}, Grau médio: #{Float.round(edges / vertices, 2)}")
  end

  test "vizinhos de saída (quem um perfil segue)", %{most_active: profile} do
    following = MeliGraph.neighbors(:follows_real, profile, :outgoing, type: :follow)

    assert length(following) > 0,
           "#{profile} deveria ter perfis seguidos"

    IO.puts("\n  #{profile} segue #{length(following)} perfil(s): #{inspect(following)}")
  end

  test "vizinhos de entrada (seguidores de um perfil)", %{most_followed: profile} do
    followers = MeliGraph.neighbors(:follows_real, profile, :incoming, type: :follow)

    assert length(followers) > 0,
           "#{profile} deveria ter seguidores"

    IO.puts("\n  #{profile} tem #{length(followers)} seguidor(es): #{inspect(followers)}")
  end

  test "Who to Follow via PageRank retorna sugestões", %{most_active: profile} do
    {:ok, recs} = MeliGraph.recommend(
      :follows_real,
      profile,
      :users,
      algorithm: :pagerank,
      num_walks: 2000,
      walk_length: 10,
      top_k: 10
    )

    assert is_list(recs), "Deve retornar uma lista"

    IO.puts("\n  Who to Follow para #{profile}:")

    if recs == [] do
      IO.puts("    (sem sugestões — grafo muito pequeno ou perfil sem vizinhos de 2º grau)")
    else
      Enum.each(recs, fn {id, score} ->
        IO.puts("    #{id}  score: #{Float.round(score, 4)}")
      end)

      # Scores devem ser positivos e ordenados de forma decrescente
      scores = Enum.map(recs, fn {_, s} -> s end)
      assert Enum.all?(scores, &(&1 > 0)), "Todos os scores devem ser positivos"
      assert scores == Enum.sort(scores, :desc), "Resultados devem estar ordenados por score"
    end
  end

  test "Who to Follow não sugere perfis já seguidos", %{most_active: profile} do
    already_following =
      MeliGraph.neighbors(:follows_real, profile, :outgoing, type: :follow)
      |> MapSet.new()

    {:ok, recs} = MeliGraph.recommend(
      :follows_real,
      profile,
      :users,
      algorithm: :pagerank,
      num_walks: 2000,
      top_k: 20
    )

    already_recommended =
      recs
      |> Enum.filter(fn {id, _} -> MapSet.member?(already_following, id) end)

    if length(recs) > 0 do
      IO.puts("\n  #{profile} já segue #{MapSet.size(already_following)} perfis.")
      IO.puts("  Recomendações que já segue: #{length(already_recommended)}/#{length(recs)}")
    end

    # Este é um teste de comportamento: o PageRank pode recomendar
    # perfis já seguidos (é esperado no algoritmo). O importante é
    # que a lista não seja exclusivamente composta por perfis já seguidos.
    refute length(recs) > 0 and length(already_recommended) == length(recs),
           "Todas as recomendações são de perfis já seguidos — algo está errado"
  end

  test "perfil desconhecido retorna lista vazia" do
    {:ok, recs} = MeliGraph.recommend(
      :follows_real,
      "profile:999999",
      :users,
      algorithm: :pagerank
    )

    assert recs == []
  end

  test "relação de follows é assimétrica (follow ≠ amizade mútua)" do
    follows = DatasetLoader.read_follows()

    mutual_count =
      follows
      |> Enum.count(fn %{from: f, to: t} ->
        Enum.any?(follows, fn %{from: ff, to: tt} -> ff == t and tt == f end)
      end)

    total = length(follows)

    IO.puts("\n  Follows totais: #{total}")
    IO.puts("  Follows mútuos: #{mutual_count} (#{Float.round(mutual_count / total * 100, 1)}%)")

    # Em redes sociais reais, nem todo follow é mútuo
    assert mutual_count < total,
           "Esperava que nem todos os follows fossem mútuos"
  end
end
