defmodule DeribitEx.Telemetry do
  @moduledoc """
  Telemetry events for the DeribitEx library.

  This module provides a consistent interface for emitting telemetry events
  throughout the library. Use these functions instead of calling :telemetry.execute
  directly to ensure consistent event naming and metadata structure.
  """

  @doc """
  Emits a telemetry event when a connection is established.
  """
  def emit_connection_opened(connection, metadata \\ %{}) do
    :telemetry.execute(
      [:deribit_ex, :connection, :opened],
      %{system_time: System.system_time()},
      Map.merge(%{connection: connection}, metadata)
    )
  end

  @doc """
  Emits a telemetry event when a connection is closed.
  """
  def emit_connection_closed(connection, reason, metadata \\ %{}) do
    :telemetry.execute(
      [:deribit_ex, :connection, :closed],
      %{system_time: System.system_time()},
      Map.merge(%{connection: connection, reason: reason}, metadata)
    )
  end

  @doc """
  Emits a telemetry event when an RPC request is sent.
  """
  def emit_rpc_request(type, method, metadata \\ %{}) do
    :telemetry.execute(
      [:deribit_ex, :rpc, :request],
      %{system_time: System.system_time()},
      Map.merge(%{type: type, method: method}, metadata)
    )
  end

  @doc """
  Emits a telemetry event when an RPC response is received.
  """
  def emit_rpc_response(type, method, duration, metadata \\ %{}) do
    :telemetry.execute(
      [:deribit_ex, :rpc, :response],
      %{system_time: System.system_time(), duration: duration},
      Map.merge(%{type: type, method: method}, metadata)
    )
  end

  @doc """
  Emits a telemetry event when authentication is successful.
  """
  def emit_auth_success(connection, metadata \\ %{}) do
    :telemetry.execute(
      [:deribit_ex, :auth, :success],
      %{system_time: System.system_time()},
      Map.merge(%{connection: connection}, metadata)
    )
  end

  @doc """
  Emits a telemetry event when authentication fails.
  """
  def emit_auth_failure(connection, reason, metadata \\ %{}) do
    :telemetry.execute(
      [:deribit_ex, :auth, :failure],
      %{system_time: System.system_time()},
      Map.merge(%{connection: connection, reason: reason}, metadata)
    )
  end

  @doc """
  Emits a telemetry event when a subscription is created.
  """
  def emit_subscription_created(channel, metadata \\ %{}) do
    :telemetry.execute(
      [:deribit_ex, :subscription, :created],
      %{system_time: System.system_time()},
      Map.merge(%{channel: channel}, metadata)
    )
  end

  @doc """
  Emits a telemetry event when a subscription is removed.
  """
  def emit_subscription_removed(channel, metadata \\ %{}) do
    :telemetry.execute(
      [:deribit_ex, :subscription, :removed],
      %{system_time: System.system_time()},
      Map.merge(%{channel: channel}, metadata)
    )
  end

  @doc """
  Emits a telemetry event when an order is registered.
  """
  def emit_order_registered(order_id, session_id, metadata \\ %{}) do
    :telemetry.execute(
      [:deribit_ex, :order_context, :order_registered],
      %{system_time: System.system_time()},
      Map.merge(%{order_id: order_id, session_id: session_id}, metadata)
    )
  end

  @doc """
  Emits a telemetry event when an order is updated.
  """
  def emit_order_updated(order_id, session_id, status, metadata \\ %{}) do
    :telemetry.execute(
      [:deribit_ex, :order_context, :order_updated],
      %{system_time: System.system_time()},
      Map.merge(%{order_id: order_id, session_id: session_id, status: status}, metadata)
    )
  end

  @doc """
  Emits a telemetry event when a session transition occurs.
  """
  def emit_session_transition(prev_session_id, new_session_id, transition_type, metadata \\ %{}) do
    :telemetry.execute(
      [:deribit_ex, :order_context, :session_transition],
      %{system_time: System.system_time()},
      Map.merge(
        %{
          previous_session_id: prev_session_id,
          new_session_id: new_session_id,
          transition_type: transition_type
        },
        metadata
      )
    )
  end
end
