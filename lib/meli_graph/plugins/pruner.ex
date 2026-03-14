defmodule MeliGraph.Plugins.Pruner do
  @moduledoc """
  Plugin que remove segmentos temporais expirados.

  Executa periodicamente e remove segmentos cuja idade excede
  o `segment_ttl` configurado.
  """

  use GenServer

  @behaviour MeliGraph.Plugin

  alias MeliGraph.Graph.SegmentManager
  alias MeliGraph.Telemetry

  @impl MeliGraph.Plugin
  def validate(opts) do
    if Keyword.has_key?(opts, :interval) and is_integer(opts[:interval]) and opts[:interval] > 0 do
      :ok
    else
      {:error, "Pruner requires a positive integer :interval option"}
    end
  end

  @impl MeliGraph.Plugin
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    conf = Keyword.fetch!(opts, :conf)
    interval = Keyword.fetch!(opts, :interval)
    schedule(interval)
    {:ok, %{conf: conf, interval: interval}}
  end

  @impl GenServer
  def handle_info(:prune, state) do
    Telemetry.span([:plugin, :prune], %{conf: state.conf}, fn ->
      cutoff = System.monotonic_time(:millisecond) - state.conf.segment_ttl
      {:ok, pruned_count} = SegmentManager.prune(state.conf, cutoff)
      {pruned_count, %{pruned: pruned_count}}
    end)

    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval) do
    Process.send_after(self(), :prune, interval)
  end
end
