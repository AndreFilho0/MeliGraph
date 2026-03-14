defmodule MeliGraph.Registry do
  @moduledoc """
  Helpers para lookup de processos via Registry.

  Evita nomes hardcoded e permite múltiplas instâncias do MeliGraph
  no mesmo node, cada uma com seu namespace isolado.
  """

  alias MeliGraph.Config

  @doc """
  Retorna uma tupla `{:via, Registry, {registry, key}}` para registrar
  ou localizar um processo pelo nome lógico.
  """
  @spec via(Config.t(), term()) :: {:via, Registry, {atom(), term()}}
  def via(%Config{registry: registry}, key) do
    {:via, Registry, {registry, key}}
  end

  @doc """
  Localiza o PID de um processo registrado com a chave dada.
  Retorna `nil` se não encontrado.
  """
  @spec whereis(Config.t(), term()) :: pid() | nil
  def whereis(%Config{registry: registry}, key) do
    case Registry.lookup(registry, key) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end
end
