defmodule MeliGraph.Plugins.CacheCleaner do
  @moduledoc """
  Plugin que remove entradas expiradas do cache de resultados.
  """

  use GenServer

  @behaviour MeliGraph.Plugin

  alias MeliGraph.Store.ETS, as: Store
  alias MeliGraph.Telemetry

  @impl MeliGraph.Plugin
  def validate(opts) do
    if Keyword.has_key?(opts, :interval) and is_integer(opts[:interval]) and opts[:interval] > 0 do
      :ok
    else
      {:error, "CacheCleaner requires a positive integer :interval option"}
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
  def handle_info(:clean, state) do
    Telemetry.span([:plugin, :cache_clean], %{conf: state.conf}, fn ->
      cleaned = Store.clean_expired(state.conf)
      {cleaned, %{cleaned: cleaned}}
    end)

    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval) do
    Process.send_after(self(), :clean, interval)
  end
end
