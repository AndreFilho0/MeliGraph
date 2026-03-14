defmodule MeliGraph.TelemetryTest do
  use ExUnit.Case, async: true

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

      result = Telemetry.span([:test, :op], %{}, fn ->
        {"hello", %{}}
      end)

      assert result == "hello"
      assert_receive {:telemetry, measurements}
      assert is_integer(measurements.duration)

      :telemetry.detach("test-span-#{inspect(ref)}")
    end
  end
end
