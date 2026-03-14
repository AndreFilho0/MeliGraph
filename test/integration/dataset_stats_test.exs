defmodule MeliGraph.Integration.DatasetStatsTest do
  @moduledoc """
  Valida a integridade do dataset exportado do banco de produção.
  Roda primeiro para garantir que os arquivos estão corretos antes
  dos testes de feature.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias MeliGraph.DatasetLoader

  test "arquivos CSV existem e são legíveis" do
    base = Path.join([File.cwd!(), "tmp"])

    for file <- ["meli_graph_follows.csv", "meli_graph_likes.csv", "meli_graph_posts.csv"] do
      path = Path.join(base, file)
      assert File.exists?(path), "Arquivo não encontrado: #{path}"
      assert File.stat!(path).size > 0, "Arquivo vazio: #{path}"
    end
  end

  test "follows.csv tem colunas corretas" do
    [first | _] = DatasetLoader.read_follows()
    assert Map.has_key?(first, :from)
    assert Map.has_key?(first, :to)
    assert String.starts_with?(first.from, "profile:")
    assert String.starts_with?(first.to, "profile:")
  end

  test "likes.csv tem colunas corretas e deduplica" do
    likes = DatasetLoader.read_likes()
    assert length(likes) > 0

    [first | _] = likes
    assert Map.has_key?(first, :profile_id)
    assert Map.has_key?(first, :post_id)
    assert String.starts_with?(first.profile_id, "profile:")
    assert String.starts_with?(first.post_id, "post:")

    # Confirma que deduplicação funciona
    pairs = Enum.map(likes, fn %{profile_id: p, post_id: po} -> {p, po} end)
    assert length(pairs) == length(Enum.uniq(pairs)),
           "DatasetLoader.read_likes deveria retornar apenas pares únicos"
  end

  test "posts.csv tem colunas corretas" do
    posts = DatasetLoader.read_posts()
    assert length(posts) > 0

    [first | _] = posts
    assert Map.has_key?(first, :post_id)
    assert Map.has_key?(first, :profile_id)
    assert Map.has_key?(first, :type)
    assert String.starts_with?(first.post_id, "post:")
    assert String.starts_with?(first.profile_id, "profile:")
  end

  test "imprime estatísticas do dataset" do
    stats = DatasetLoader.stats()

    IO.puts("""

    ╔══════════════════════════════════╗
    ║     Dataset Stats (Produção)     ║
    ╠══════════════════════════════════╣
    ║  Follows (únicos):   #{String.pad_leading("#{stats.follows}", 8)} ║
    ║  Likes (únicos):     #{String.pad_leading("#{stats.likes}", 8)} ║
    ║  Posts:              #{String.pad_leading("#{stats.posts}", 8)} ║
    ║  Perfis únicos:      #{String.pad_leading("#{stats.unique_profiles}", 8)} ║
    ╠══════════════════════════════════╣
    ║  Tipos de post:                  ║
    #{format_types(stats.post_types)}╚══════════════════════════════════╝
    """)

    assert stats.follows > 0
    assert stats.likes > 0
    assert stats.posts > 0
    assert stats.unique_profiles > 0
  end

  defp format_types(types) do
    types
    |> Enum.map(fn {type, count} ->
      label = String.pad_trailing("  #{type}:", 22)
      "    ║  #{label}#{String.pad_leading("#{count}", 6)} ║\n"
    end)
    |> Enum.join()
  end
end
