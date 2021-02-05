defmodule OpenTelemetryDecorator.ErrorHandler do
  def add_error(error) do
    require IEx; IEx.pry()

    exception_attrs = []

    status = OpenTelemetry.status(:Error, "Error")
    span_ctx = Tracer.current_span_ctx()

    Span.add_event(span_ctx, "exception", exception_attrs)
    Span.set_status(span_ctx, status)
  end
end
