defmodule :telemetry_test_util do
  @moduledoc """
  Utilities for testing telemetry events.

  This module provides helpers for attaching handlers to telemetry events
  during tests, making it easier to assert that the expected events are fired.
  """

  @doc """
  Attaches event handlers that forward telemetry events to the specified process.

  ## Parameters
  - `pid` - The process ID to which events will be sent
  - `events` - A list of event name prefixes to attach to

  ## Returns
  - A reference that can be used to detach the handler later

  ## Example
  ```elixir
  # In a test
  test_pid = self()
  ref = :telemetry_test_util.attach_event_handlers(test_pid, [
    [:deribit_ex, :client, :get_time, :success]
  ])

  # The test will now receive messages when matching events are fired

  # Don't forget to detach the handler after the test
  on_exit(fn ->
    :telemetry.detach(ref)
  end)
  ```
  """
  @spec attach_event_handlers(pid(), [list()]) :: reference()
  def attach_event_handlers(pid, events) do
    handler_id = make_ref()

    for event <- events do
      :telemetry.attach(
        handler_id,
        event,
        fn event_name, measurements, metadata, _config ->
          send(pid, {event_name, measurements, metadata})
        end,
        nil
      )
    end

    handler_id
  end
end
