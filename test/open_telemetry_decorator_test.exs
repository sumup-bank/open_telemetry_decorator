defmodule OpenTelemetryDecoratorTest do
  use ExUnit.Case, async: true
  doctest OpenTelemetryDecorator

  require OpenTelemetry.Tracer
  require OpenTelemetry.Span

  require Record

  # Make span methods available
  for {name, spec} <- Record.extract_all(from_lib: "opentelemetry/include/otel_span.hrl") do
    Record.defrecord(name, spec)
  end

  setup [:telemetry_pid_reporter]

  describe "trace" do
    defmodule Example do
      use OpenTelemetryDecorator

      @decorate trace("Example.step", include: [:id, :result])
      def step(id), do: {:ok, id}

      @decorate trace("Example.workflow", include: [:count, :result])
      def workflow(count), do: Enum.map(1..count, fn id -> step(id) end)

      @decorate trace("Example.numbers", include: [:up_to])
      def numbers(up_to), do: [1..up_to]

      @decorate trace("Example.find", include: [:id, [:user, :name], :error, :_even, :result])
      def find(id) do
        _even = rem(id, 2) == 0
        user = %{id: id, name: "my user"}

        case id do
          1 ->
            {:ok, user}

          error ->
            {:error, error}
        end
      end

      @decorate trace("bad_result")
      def bad_result, do: :error

      @decorate trace("bad_tuple_result")
      def bad_tuple_result, do: {:error, 1, 2, 3, 4}

      @decorate trace("Example.no_include")
      def no_include(opts), do: {:ok, opts}
    end

    test "does not modify inputs or function result" do
      assert Example.step(1) == {:ok, 1}
    end

    test "automatically links spans" do
      Example.workflow(2)

      assert_receive {:span,
                      span(
                        name: "Example.workflow",
                        trace_id: parent_trace_id,
                        attributes: {:attributes, _, :infinity, _, %{count: 2}}
                      )}

      assert_receive {:span,
                      span(
                        name: "Example.step",
                        trace_id: ^parent_trace_id,
                        attributes: {:attributes, _, :infinity, _, %{id: 1}}
                      )}

      assert_receive {:span,
                      span(
                        name: "Example.step",
                        trace_id: ^parent_trace_id,
                        attributes: {:attributes, _, :infinity, _, %{id: 2}}
                      )}
    end

    test "handles simple attributes" do
      Example.find(1)

      assert_receive {:span,
                      span(
                        name: "Example.find",
                        attributes: {:attributes, _, :infinity, _, attrs}
                      )}

      assert Map.get(attrs, :id) == 1
    end

    test "handles nested attributes" do
      Example.find(1)

      assert_receive {:span,
                      span(
                        name: "Example.find",
                        attributes: {:attributes, _, :infinity, _, attrs}
                      )}

      assert Map.get(attrs, :user_name) == "my user"
    end

    test "handles handles underscored attributes" do
      Example.find(2)

      assert_receive {:span,
                      span(
                        name: "Example.find",
                        attributes: {:attributes, _, :infinity, _, attrs}
                      )}

      assert Map.get(attrs, :id) == 2
    end

    test "converts atoms to strings" do
      Example.step(:two)

      assert_receive {:span,
                      span(
                        name: "Example.step",
                        attributes: {:attributes, _, :infinity, _, attrs}
                      )}

      assert Map.get(attrs, :id) == "two"
    end

    test "does not include result unless asked for" do
      Example.numbers(1000)

      assert_receive {:span,
                      span(
                        name: "Example.numbers",
                        attributes: {:attributes, _, :infinity, _, attrs}
                      )}

      assert Map.has_key?(attrs, :result) == false
    end

    test "does not include variables not in scope when the function exists" do
      Example.find(098)

      assert_receive {:span,
                      span(
                        name: "Example.find",
                        attributes: {:attributes, _, :infinity, _, attrs}
                      )}

      assert Map.has_key?(attrs, :error) == false
    end

    test "does not include anything unless specified" do
      Example.no_include(include_me: "nope")

      assert_receive {:span,
                      span(
                        name: "Example.no_include",
                        attributes: {:attributes, _, :infinity, _, %{}}
                      )}
    end

    test "treat span simple error" do
      Example.bad_result()
      expected_status = OpenTelemetry.status(:error, "Error")
      assert_receive {:span, span(name: "bad_result", status: ^expected_status)}
    end

    test "treat span tuple error" do
      Example.bad_tuple_result()
      expected_status = OpenTelemetry.status(:error, "Error")
      assert_receive {:span, span(name: "bad_tuple_result", status: ^expected_status)}
    end
  end

  describe "simple_trace" do
    defmodule Math do
      use OpenTelemetryDecorator

      @decorate simple_trace()
      def add(a, b), do: a + b

      @decorate simple_trace("math.subtraction")
      def subtract(a, b), do: a - b

      @decorate simple_trace("math.bad_subtraction")
      def bad_subtract(_a, _b), do: {:error, :bad_subtract}
    end

    test "generates span name" do
      Math.add(2, 3)

      assert_receive {:span,
                      span(
                        name: "OpenTelemetryDecoratorTest.Math.add/2",
                        attributes: {:attributes, _, :infinity, _, %{}}
                      )}
    end

    test "span name can be specified" do
      Math.subtract(3, 2)

      assert_receive {:span,
                      span(
                        name: "math.subtraction",
                        attributes: {:attributes, _, :infinity, _, %{}}
                      )}
    end

    test "span with error status" do
      Math.bad_subtract(3, 2)

      expected_status = OpenTelemetry.status(:error, "Error")

      assert_receive {:span,
                      span(
                        name: "math.bad_subtraction",
                        status: ^expected_status
                      )}
    end
  end

  def telemetry_pid_reporter(_) do
    ExUnit.CaptureLog.capture_log(fn -> :application.stop(:opentelemetry) end)

    :application.set_env(:opentelemetry, :tracer, :otel_tracer_default)

    :application.set_env(:opentelemetry, :processors, [
      {:otel_batch_processor, %{scheduled_delay_ms: 1}}
    ])

    :application.start(:opentelemetry)

    :otel_batch_processor.set_exporter(:otel_exporter_pid, self())

    :ok
  end
end
