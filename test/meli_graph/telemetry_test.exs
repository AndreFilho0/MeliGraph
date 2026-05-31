defmodule MeliGraph.TelemetryTest do
  use ExUnit.Case, async: false

  import MeliGraph.TestHelpers

  alias MeliGraph.Telemetry

  describe "span/3" do
    test "emits start and stop events" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-span-#{inspect(ref)}",
        [:meli_graph, :test, :op, :stop],
        fn _event, measurements, _meta, _config ->
          send(test_pid, {:telemetry, measurements})
        end,
        nil
      )

      result =
        Telemetry.span([:test, :op], %{}, fn ->
          {"hello", %{}}
        end)

      assert result == "hello"
      assert_receive {:telemetry, measurements}
      assert is_integer(measurements.duration)

      :telemetry.detach("test-span-#{inspect(ref)}")
    end
  end

  describe "instance lifecycle events" do
    test "emits [:instance, :started] on boot and [:instance, :ready] after on_ready" do
      test_pid = self()
      handler_id = "test-instance-#{inspect(make_ref())}"

      :telemetry.attach_many(
        handler_id,
        [
          [:meli_graph, :instance, :started],
          [:meli_graph, :instance, :ready]
        ],
        fn event, _measurements, meta, _config ->
          send(test_pid, {:telemetry, event, meta})
        end,
        nil
      )

      name = unique_name()

      {:ok, _pid} =
        MeliGraph.start_link(
          name: name,
          graph_type: :bipartite,
          testing: :sync,
          on_ready: {MeliGraph.TestHelpers, :seed_edges, [name]}
        )

      assert_receive {:telemetry, [:meli_graph, :instance, :started], %{name: ^name}}
      assert_receive {:telemetry, [:meli_graph, :instance, :ready], %{name: ^name}}

      :telemetry.detach(handler_id)
    end
  end
end
