defmodule DeribitEx.Telemetry do
  @moduledoc """
  Telemetry events for the DeribitEx library.

  This module provides a consistent interface for emitting telemetry events
  throughout the library. Use these functions instead of calling :telemetry.execute
  directly to ensure consistent event naming and metadata structure.
  
  ## Event Categories
  
  DeribitEx emits telemetry events in the following categories:
  
  - Connection: Events related to WebSocket connection lifecycle
  - RPC: Events for request/response operations
  - Auth: Authentication-related events
  - Subscription: Channel subscription events
  - Order Context: Order tracking events
  
  ## Example Usage
  
  ```elixir
  :telemetry.attach(
    "deribit-auth-handler",
    [:deribit_ex, :auth, :success],
    fn name, measurements, metadata, _config ->
      # Process authentication success event
    end,
    nil
  )
  ```
  """

  @typedoc """
  Connection identifier, typically the WebSocket client PID.
  """
  @type connection :: pid() | atom()

  @typedoc """
  Generic metadata map for telemetry events.
  """
  @type metadata :: map()

  @typedoc """
  RPC request types.
  """
  @type rpc_type :: :auth | :public | :private | :subscription | :heartbeat

  @typedoc """
  Session identifier for tracking session state.
  """
  @type session_id :: String.t()

  @typedoc """
  Types of session transitions.
  """
  @type transition_type :: :refresh | :exchange | :fork | :logout

  @doc """
  Emits a telemetry event when a connection is established.
  
  ## Parameters
  
  - `connection`: The WebSocket connection identifier
  - `metadata`: Additional metadata to include with the event
  """
  @spec emit_connection_opened(connection(), metadata()) :: :ok
  def emit_connection_opened(connection, metadata \\ %{}) do
    :telemetry.execute(
      [:deribit_ex, :connection, :opened],
      %{system_time: System.system_time()},
      Map.merge(%{connection: connection}, metadata)
    )
  end

  @doc """
  Emits a telemetry event when a connection is closed.
  
  ## Parameters
  
  - `connection`: The WebSocket connection identifier
  - `reason`: The reason for the connection closure
  - `metadata`: Additional metadata to include with the event
  """
  @spec emit_connection_closed(connection(), term(), metadata()) :: :ok
  def emit_connection_closed(connection, reason, metadata \\ %{}) do
    :telemetry.execute(
      [:deribit_ex, :connection, :closed],
      %{system_time: System.system_time()},
      Map.merge(%{connection: connection, reason: reason}, metadata)
    )
  end

  @doc """
  Emits a telemetry event when an RPC request is sent.
  
  ## Parameters
  
  - `type`: The type of RPC request (:auth, :public, :private, etc.)
  - `method`: The RPC method name
  - `metadata`: Additional metadata to include with the event
  """
  @spec emit_rpc_request(rpc_type(), String.t(), metadata()) :: :ok
  def emit_rpc_request(type, method, metadata \\ %{}) do
    :telemetry.execute(
      [:deribit_ex, :rpc, :request],
      %{system_time: System.system_time()},
      Map.merge(%{type: type, method: method}, metadata)
    )
  end

  @doc """
  Emits a telemetry event when an RPC response is received.
  
  ## Parameters
  
  - `type`: The type of RPC request that this is a response to
  - `method`: The RPC method name
  - `duration`: The duration of the request in native time units
  - `metadata`: Additional metadata to include with the event
  """
  @spec emit_rpc_response(rpc_type(), String.t(), integer(), metadata()) :: :ok
  def emit_rpc_response(type, method, duration, metadata \\ %{}) do
    :telemetry.execute(
      [:deribit_ex, :rpc, :response],
      %{system_time: System.system_time(), duration: duration},
      Map.merge(%{type: type, method: method}, metadata)
    )
  end

  @doc """
  Emits a telemetry event when authentication is successful.
  
  ## Parameters
  
  - `connection`: The WebSocket connection identifier
  - `metadata`: Additional metadata to include with the event
  """
  @spec emit_auth_success(connection(), metadata()) :: :ok
  def emit_auth_success(connection, metadata \\ %{}) do
    :telemetry.execute(
      [:deribit_ex, :auth, :success],
      %{system_time: System.system_time()},
      Map.merge(%{connection: connection}, metadata)
    )
  end

  @doc """
  Emits a telemetry event when authentication fails.
  
  ## Parameters
  
  - `connection`: The WebSocket connection identifier
  - `reason`: The reason for the authentication failure
  - `metadata`: Additional metadata to include with the event
  """
  @spec emit_auth_failure(connection(), term(), metadata()) :: :ok
  def emit_auth_failure(connection, reason, metadata \\ %{}) do
    :telemetry.execute(
      [:deribit_ex, :auth, :failure],
      %{system_time: System.system_time()},
      Map.merge(%{connection: connection, reason: reason}, metadata)
    )
  end

  @doc """
  Emits a telemetry event when a subscription is created.
  
  ## Parameters
  
  - `channel`: The channel name that was subscribed to
  - `metadata`: Additional metadata to include with the event
  """
  @spec emit_subscription_created(String.t(), metadata()) :: :ok
  def emit_subscription_created(channel, metadata \\ %{}) do
    :telemetry.execute(
      [:deribit_ex, :subscription, :created],
      %{system_time: System.system_time()},
      Map.merge(%{channel: channel}, metadata)
    )
  end

  @doc """
  Emits a telemetry event when a subscription is removed.
  
  ## Parameters
  
  - `channel`: The channel name that was unsubscribed from
  - `metadata`: Additional metadata to include with the event
  """
  @spec emit_subscription_removed(String.t(), metadata()) :: :ok
  def emit_subscription_removed(channel, metadata \\ %{}) do
    :telemetry.execute(
      [:deribit_ex, :subscription, :removed],
      %{system_time: System.system_time()},
      Map.merge(%{channel: channel}, metadata)
    )
  end

  @doc """
  Emits a telemetry event when an order is registered.
  
  ## Parameters
  
  - `order_id`: The ID of the order
  - `session_id`: The session ID that the order belongs to
  - `metadata`: Additional metadata to include with the event
  """
  @spec emit_order_registered(String.t(), session_id(), metadata()) :: :ok
  def emit_order_registered(order_id, session_id, metadata \\ %{}) do
    :telemetry.execute(
      [:deribit_ex, :order_context, :order_registered],
      %{system_time: System.system_time()},
      Map.merge(%{order_id: order_id, session_id: session_id}, metadata)
    )
  end

  @doc """
  Emits a telemetry event when an order is updated.
  
  ## Parameters
  
  - `order_id`: The ID of the order
  - `session_id`: The session ID that the order belongs to
  - `status`: The new status of the order
  - `metadata`: Additional metadata to include with the event
  """
  @spec emit_order_updated(String.t(), session_id(), String.t(), metadata()) :: :ok
  def emit_order_updated(order_id, session_id, status, metadata \\ %{}) do
    :telemetry.execute(
      [:deribit_ex, :order_context, :order_updated],
      %{system_time: System.system_time()},
      Map.merge(%{order_id: order_id, session_id: session_id, status: status}, metadata)
    )
  end

  @doc """
  Emits a telemetry event when a session transition occurs.
  
  ## Parameters
  
  - `prev_session_id`: The previous session ID
  - `new_session_id`: The new session ID
  - `transition_type`: The type of transition (:refresh, :exchange, :fork, :logout)
  - `metadata`: Additional metadata to include with the event
  """
  @spec emit_session_transition(session_id(), session_id(), transition_type(), metadata()) :: :ok
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