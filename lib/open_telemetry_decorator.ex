defmodule OpenTelemetryDecorator do
  @external_resource "README.md"

  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC -->")
             |> Enum.filter(&(&1 =~ ~r/<!\-\-\ INCLUDE\ \-\->/))
             |> Enum.join("\n")
             # compensate for anchor id differences between ExDoc and GitHub
             |> (&Regex.replace(~r/\(\#\K(?=[a-z][a-z0-9-]+\))/, &1, "module-")).()

  use Decorator.Define, with_span: 1, with_span: 2, trace: 1, trace: 2

  alias OpenTelemetryDecorator.Attributes
  alias OpenTelemetryDecorator.Validator
  alias OpenTelemetryDecorator.SpanName

  def trace(span_name, opts \\ [], body, context), do: with_span(span_name, opts, body, context)

  @doc """
  Decorate a function to add to or create an OpenTelemetry trace with a named span.

  You can provide span attributes by specifying a list of variable names as atoms.
  This list can include:

  - any variables (in the top level closure) available when the function exits,
  - the result of the function by including the atom `:result`,
  - map/struct properties using nested lists of atoms.

  ```elixir
  defmodule MyApp.Worker do
    use OpenTelemetryDecorator

    @decorate with_span("my_app.worker.do_work", include: [:arg1, [:arg2, :count], :total, :result])
    def do_work(arg1, arg2) do
      total = arg1.count + arg2.count
      {:ok, total}
    end
  end
  ```
  """
  def with_span(span_name, opts \\ [], body, context) do
    include = Keyword.get(opts, :include, [])
    Validator.validate_args(span_name, include)

    dynamic_links = Keyword.get(opts, :links, [])

    quote location: :keep do
      require OpenTelemetry.Tracer, as: Tracer
      require OpenTelemetry.Span, as: Span

      links =
        Kernel.binding()
        |> Enum.into(%{})
        |> Map.take(unquote(dynamic_links))
        |> Map.values()

      parent_span = O11y.start_span(unquote(span_name), links: links)
      new_span = Tracer.current_span_ctx()

      prefix = Attributes.attribute_prefix()

      input_params =
        Kernel.binding()
        |> Keyword.delete(:result)
        |> Keyword.take(unquote(include))
        |> O11y.set_attributes(namespace: prefix)

      try do
        result = unquote(body)

        # Called functions can mess up Tracer's current span context, so ensure we at least write to ours
        Tracer.set_current_span(new_span)

        Kernel.binding()
        |> Keyword.put(:result, result)
        |> Keyword.merge(input_params)
        |> Keyword.take(unquote(include))
        |> O11y.set_attributes(namespace: prefix)

        result
      rescue
        e ->
          O11y.record_exception(e)
          reraise e, __STACKTRACE__
      catch
        :exit, :normal ->
          O11y.set_attribute(:exit, :normal, namespace: prefix)
          exit(:normal)

        :exit, :shutdown ->
          O11y.set_attribute(:exit, :shutdown, namespace: prefix)
          exit(:shutdown)

        :exit, {:shutdown, reason} ->
          O11y.set_attributes(
            [exit: :shutdown, shutdown_reason: reason],
            namespace: prefix
          )

          exit({:shutdown, reason})

        :exit, reason ->
          O11y.set_error("exited: #{inspect(reason)}")
          :erlang.raise(:exit, reason, __STACKTRACE__)

        :throw, thrown ->
          O11y.set_error("uncaught: #{inspect(thrown)}")
          :erlang.raise(:throw, thrown, __STACKTRACE__)
      after
        O11y.end_span(parent_span)
      end
    end
  rescue
    e in ArgumentError ->
      target = "#{inspect(context.module)}.#{context.name}/#{context.arity} @decorate telemetry"
      reraise %ArgumentError{message: "#{target} #{e.message}"}, __STACKTRACE__
  end

  @doc """
  Decorate a function to add an OpenTelemetry trace with a named span. The input parameters and result are automatically added to the span attributes.
  You can specify a span name or one will be generated based on the module name, function name, and arity.

  ```elixir
  defmodule MyApp.Worker do
    use OpenTelemetryDecorator

    @decorate simple_trace()
    def do_work(arg1, arg2) do
      total = arg1.count + arg2.count
      {:ok, total}
    end

    @decorate simple_trace("worker.do_more_work")
    def handle_call({:do_more_work, args}, _from, state) do
      {:reply, {:ok, args}, state}
    end
  end
  ```
  """
  def simple_trace(body, context) do
    context
    |> SpanName.from_context()
    |> simple_trace(body, context)
  end

  def simple_trace(span_name, body, context) do
    quote location: :keep do
      require OpenTelemetry.Span
      require OpenTelemetry.Tracer

      parent_ctx = OpenTelemetry.Tracer.current_span_ctx()

      attributes =
        case Logger.metadata() do
          [request_id: value] -> [request_id: value]
          _ -> []
        end

      OpenTelemetry.Tracer.with_span unquote(span_name), %{
        parent: parent_ctx,
        attributes: attributes
      } do
        unquote(body) |> OpenTelemetryDecorator.treat_result()
      end
    end
  rescue
    e in ArgumentError ->
      target = "#{inspect(context.module)}.#{context.name}/#{context.arity} @decorate telemetry"
      reraise %ArgumentError{message: "#{target} #{e.message}"}, __STACKTRACE__
  end

  def treat_result(result) do
    case result do
      :error ->
        OpenTelemetryDecorator.add_error()
        :error

      tuple when is_tuple(tuple) ->
        case Tuple.to_list(tuple) do
          [:error | _tail] ->
            OpenTelemetryDecorator.add_error()
            tuple

          _any ->
            tuple
        end

      any ->
        any
    end
  end

  def add_error() do
    status = OpenTelemetry.status(:error, "Error")
    span_ctx = OpenTelemetry.Tracer.current_span_ctx()
    OpenTelemetry.Span.set_status(span_ctx, status)
  end
end
