defmodule MeliGraph.Telemetry do
  @moduledoc """
  Wrapper para `:telemetry.span/3` com prefixo `[:meli_graph]`.

  Todas as operações críticas do MeliGraph emitem eventos de telemetria,
  permitindo observabilidade via handlers externos.

  ## Eventos emitidos

    * `[:meli_graph, :ingestion, :insert_edge, :start | :stop | :exception]`
    * `[:meli_graph, :query, :recommend, :start | :stop | :exception]`
    * `[:meli_graph, :engine, :compute, :start | :stop | :exception]`
    * `[:meli_graph, :graph, :create_segment, :start | :stop | :exception]`
    * `[:meli_graph, :plugin, :prune, :start | :stop | :exception]`
    * `[:meli_graph, :plugin, :cache_clean, :start | :stop | :exception]`
  """

  @doc """
  Executa `fun` dentro de um `:telemetry.span/3` com o prefixo `[:meli_graph | event_suffix]`.

  `fun` deve retornar `{result, extra_measurements_or_metadata}`.
  """
  @spec span([atom()], map(), (-> {term(), map()})) :: term()
  def span(event_suffix, meta, fun) when is_list(event_suffix) and is_map(meta) do
    :telemetry.span([:meli_graph | event_suffix], meta, fun)
  end
end
