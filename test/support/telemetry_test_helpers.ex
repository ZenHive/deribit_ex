defmodule DeribitEx.TelemetryTestHelpers do
  @moduledoc """
  Helper module for testing telemetry events.
  """

  @doc """
  Attaches event handlers for the specified events.

  Returns a unique reference that can be used to detach the handlers.

  ## Example
      
      # Setup
      ref = :telemetry_test.attach_event_handlers(self(), [[:my_app, :event]])
      
      # Trigger code that emits telemetry
      my_function()
      
      # Assert
      assert_receive {[:my_app, :event], _ref, measurements, metadata}
      
      # Clean up
      :telemetry.detach(ref)
  """
  @spec attach_event_handlers(pid(), list(list(atom()))) :: reference()
  def attach_event_handlers(pid, events) do
    reference = make_ref()

    for event <- events do
      :telemetry.attach(
        {reference, event},
        event,
        fn event, measurements, metadata, _config ->
          send(pid, {event, reference, measurements, metadata})
        end,
        nil
      )
    end

    reference
  end

  @doc """
  Detaches all event handlers that were attached with the given reference.

  ## Example
      
      ref = :telemetry_test.attach_event_handlers(self(), events)
      # ... code ...
      :telemetry_test.detach_event_handlers(ref, events)
  """
  @spec detach_event_handlers(reference(), list(list(atom()))) :: :ok
  def detach_event_handlers(reference, events) do
    for event <- events do
      :telemetry.detach({reference, event})
    end

    :ok
  end
end
