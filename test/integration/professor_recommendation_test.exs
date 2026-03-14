defmodule MeliGraph.Integration.ProfessorRecommendationTest do
  @moduledoc """
  Testes de feature: recomendação de professores para alunos.

  Grafo bipartido: profile ↔ professor
  Sinal: aluno curtiu um post do tipo 'sobre_professor' com professor_id=X
         → aluno tem interesse no professor X

  Este é o caso de uso principal da rede social universitária.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias MeliGraph.DatasetLoader

  setup_all do
    {:ok, _} = MeliGraph.start_link(
      name: :prof_rec,
      graph_type: :bipartite,
      testing: :sync
    )

    {:ok, stats} = DatasetLoader.load_professor_interactions(:prof_rec)
    interactions  = DatasetLoader.read_professor_interactions()
    professors    = DatasetLoader.read_professors()

    IO.puts("""

    ╔══════════════════════════════════════════╗
    ║   Professor Recommendation — Dataset    ║
    ╠══════════════════════════════════════════╣
    ║  Interações únicas:  #{String.pad_leading("#{stats.inserted}", 18)} ║
    ║  Duplicatas:         #{String.pad_leading("#{stats.duplicates}", 18)} ║
    ║  Arestas no grafo:   #{String.pad_leading("#{MeliGraph.edge_count(:prof_rec)}", 18)} ║
    ║  Vértices:           #{String.pad_leading("#{MeliGraph.vertex_count(:prof_rec)}", 18)} ║
    ║  Professores no BD:  #{String.pad_leading("#{length(professors)}", 18)} ║
    ╚══════════════════════════════════════════╝
    """)

    # Aluno com mais interações com professores
    {most_active, _} =
      interactions
      |> Enum.group_by(& &1.profile_id)
      |> Enum.max_by(fn {_, list} -> length(list) end)

    # Professor com mais alunos interessados
    {most_popular_prof, _} =
      interactions
      |> Enum.group_by(& &1.professor_id)
      |> Enum.max_by(fn {_, list} -> length(list) end)

    %{
      interactions:        interactions,
      professors:          professors,
      most_active:         most_active,
      most_popular_prof:   most_popular_prof
    }
  end

  test "professores que um aluno interagiu são seus vizinhos de saída",
       %{most_active: profile, interactions: interactions} do
    expected =
      interactions
      |> Enum.filter(fn %{profile_id: p} -> p == profile end)
      |> Enum.map(& &1.professor_id)
      |> MapSet.new()

    actual =
      MeliGraph.neighbors(:prof_rec, profile, :outgoing, type: :liked_professor)
      |> MapSet.new()

    assert MapSet.equal?(expected, actual)

    IO.puts("\n  #{profile} interagiu com #{MapSet.size(expected)} professor(es):")
    MapSet.to_list(expected) |> Enum.each(fn prof_id ->
      meta = find_professor_meta(prof_id, interactions)
      IO.puts("    #{prof_id}#{meta}")
    end)
  end

  test "alunos que interagiram com um professor são seus vizinhos de saída (bidirecional)",
       %{most_popular_prof: professor, interactions: interactions} do
    expected =
      interactions
      |> Enum.filter(fn %{professor_id: p} -> p == professor end)
      |> Enum.map(& &1.profile_id)
      |> MapSet.new()

    actual =
      MeliGraph.neighbors(:prof_rec, professor, :outgoing, type: :liked_professor)
      |> MapSet.new()

    assert MapSet.equal?(expected, actual)

    IO.puts("\n  #{professor} tem #{MapSet.size(expected)} aluno(s) interessado(s): #{inspect(MapSet.to_list(expected))}")
  end

  test "PageRank recomenda professores via rede social do aluno",
       %{most_active: profile, interactions: interactions, professors: professors} do
    already_interacted =
      interactions
      |> Enum.filter(fn %{profile_id: p} -> p == profile end)
      |> Enum.map(& &1.professor_id)
      |> MapSet.new()

    {:ok, recs} = MeliGraph.recommend(
      :prof_rec,
      profile,
      :content,
      algorithm: :pagerank,
      num_walks: 2000,
      walk_length: 8,
      top_k: 15
    )

    prof_recs =
      recs
      |> Enum.filter(fn {id, _} -> String.starts_with?(id, "professor:") end)
      |> Enum.reject(fn {id, _} -> MapSet.member?(already_interacted, id) end)

    IO.puts("\n  Recomendações de professores para #{profile}:")
    IO.puts("  (já interagiu com #{MapSet.size(already_interacted)} professor(es))\n")

    if prof_recs == [] do
      IO.puts("  (sem recomendações novas — grafo pequeno)")
    else
      Enum.each(prof_recs, fn {prof_id, score} ->
        prof = Enum.find(professors, fn p -> p.professor_id == prof_id end)
        nome     = if prof, do: prof.nome, else: "?"
        nota     = if prof, do: "nota #{prof.nota}/100 (#{prof.qts_avaliacao} aval.)", else: ""
        IO.puts("  ★ #{nome} [#{prof_id}]")
        IO.puts("    score: #{Float.round(score, 4)} | #{nota}")
      end)
    end

    assert is_list(recs)
  end

  test "top professores mais bem avaliados no dataset", %{professors: professors} do
    top = Enum.take(professors, 10)

    IO.puts("\n  Top 10 professores por nota:")
    Enum.each(top, fn p ->
      bar = String.duplicate("█", div(p.nota, 10))
      IO.puts("  #{String.pad_trailing(p.nome, 35)} #{bar} #{p.nota}/100 (#{p.qts_avaliacao} aval.) [#{p.instituto}]")
    end)

    assert length(top) > 0
    # Ordenados por nota decrescente
    notas = Enum.map(top, & &1.nota)
    assert notas == Enum.sort(notas, :desc)
  end

  test "professores com mais interações sociais no grafo",
       %{interactions: interactions, professors: professors} do
    ranking =
      interactions
      |> Enum.group_by(& &1.professor_id)
      |> Enum.map(fn {prof_id, list} -> {prof_id, length(list)} end)
      |> Enum.sort_by(fn {_, n} -> n end, :desc)

    IO.puts("\n  Professores com mais interesse dos alunos:")
    Enum.each(ranking, fn {prof_id, count} ->
      prof = Enum.find(professors, fn p -> p.professor_id == prof_id end)
      nome = if prof, do: prof.nome, else: prof_id
      nota = if prof, do: " | nota #{prof.nota}/100", else: ""
      IO.puts("  #{String.pad_trailing(nome, 35)} #{count} aluno(s)#{nota}")
    end)

    assert length(ranking) > 0
  end

  test "SALSA recomenda professores via Circle of Trust",
       %{most_active: profile} do
    {:ok, recs} = MeliGraph.recommend(
      :prof_rec,
      profile,
      :content,
      algorithm: :salsa,
      seed_size: 20,
      iterations: 5,
      top_k: 10
    )

    IO.puts("\n  SALSA para #{profile}: #{length(recs)} resultado(s)")

    Enum.each(recs, fn {id, score} ->
      IO.puts("    #{id}  score: #{Float.round(score, 4)}")
    end)
  end

  # --- Private ---

  defp find_professor_meta(prof_id, _interactions) do
    # Placeholder — enriquecido pelo read_professors se necessário
    " (#{prof_id})"
  end
end
