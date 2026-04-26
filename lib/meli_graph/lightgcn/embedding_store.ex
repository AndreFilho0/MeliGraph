defmodule MeliGraph.LightGCN.EmbeddingStore do
  @moduledoc """
  Gerencia o ciclo de vida dos embeddings LightGCN no `Store.ETS` por instância.

  A lib não persiste embeddings em disco — recebe um `binary` (produzido por
  `MeliGraph.LightGCN.Trainer.train/3` e persistido pela aplicação caller),
  desserializa, e mantém o payload em memória com TTL `:infinity` para que
  fique disponível à inferência até ser substituído por um novo treino.

  ## Formato do payload

      %{
        version: 1,
        embeddings: Nx.Tensor.t(),       # shape {node_count, embedding_dim}
        user_index: %{internal_id => row_index},
        item_index: %{internal_id => row_index},
        user_count: non_neg_integer(),
        item_count: non_neg_integer(),
        trained_at: unix_timestamp
      }

  ## Chave ETS

  Os embeddings ficam em `:lightgcn_embeddings` no `Store.ETS` da instância.
  O namespace é isolado por config (`MeliGraph.Config`).
  """

  alias MeliGraph.Config
  alias MeliGraph.Store.ETS, as: Store

  @key :lightgcn_embeddings

  @type payload :: %{
          required(:version) => pos_integer(),
          required(:embeddings) => Nx.Tensor.t(),
          required(:user_index) => %{non_neg_integer() => non_neg_integer()},
          required(:item_index) => %{non_neg_integer() => non_neg_integer()},
          required(:user_count) => non_neg_integer(),
          required(:item_count) => non_neg_integer(),
          required(:trained_at) => integer(),
          optional(atom()) => term()
        }

  @doc """
  Desserializa `binary` (gerado por `Trainer.train/3`) e armazena o payload
  no `Store.ETS` com TTL `:infinity`. Substitui qualquer embedding anterior.

  Retorna `{:error, :invalid_binary}` se o binário não for um payload válido.
  """
  @spec load(Config.t(), binary()) :: :ok | {:error, :invalid_binary}
  def load(%Config{} = conf, binary) when is_binary(binary) do
    case safe_decode(binary) do
      {:ok, payload} ->
        Store.put(conf, @key, payload, :infinity)

      :error ->
        {:error, :invalid_binary}
    end
  end

  def load(_conf, _other), do: {:error, :invalid_binary}

  @doc """
  Recupera o payload completo (embeddings + índices) carregado, ou `:miss`
  se nenhum embedding foi carregado ainda.
  """
  @spec get(Config.t()) :: {:ok, payload()} | :miss
  def get(%Config{} = conf) do
    Store.get(conf, @key)
  end

  @doc """
  Retorna `true` se há embeddings carregados na instância.
  """
  @spec ready?(Config.t()) :: boolean()
  def ready?(%Config{} = conf) do
    match?({:ok, _}, get(conf))
  end

  # --- Private ---

  # `:erlang.binary_to_term/2` com `[:safe]` evita executar átomos novos
  # ou closures embarcadas em binários hostis. Combinamos com validação
  # estrutural para descartar termos válidos mas que não são payloads.
  defp safe_decode(binary) do
    try do
      term = :erlang.binary_to_term(binary, [:safe])
      if valid_payload?(term), do: {:ok, term}, else: :error
    rescue
      ArgumentError -> :error
    end
  end

  defp valid_payload?(%{
         version: v,
         embeddings: %Nx.Tensor{},
         user_index: u_idx,
         item_index: i_idx,
         user_count: uc,
         item_count: ic,
         trained_at: ts
       })
       when is_integer(v) and is_map(u_idx) and is_map(i_idx) and
              is_integer(uc) and is_integer(ic) and is_integer(ts),
       do: true

  defp valid_payload?(_), do: false
end
