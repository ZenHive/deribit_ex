defmodule DeribitEx.OrderContext do
  @moduledoc """
  Manages order state preservation during token operations.

  This module is responsible for:
  - Tracking orders associated with specific sessions
  - Preserving order information during session transitions
  - Providing a clean interface for order management integration
  - Supporting order state migration between sessions

  Integrates with SessionContext to ensure order state continuity during
  authentication changes and token operations.
  """

  alias DeribitEx.SessionContext

  require Logger

  @typedoc """
  Tracks an order's association with a session.

  - `order_id`: The ID of the order from Deribit
  - `session_id`: The ID of the session that created the order
  - `instrument_name`: The instrument for this order (e.g., "BTC-PERPETUAL")
  - `direction`: Whether this is a "buy" or "sell" order
  - `status`: Current order status (e.g., "open", "filled", "cancelled")
  - `created_at`: When this order was created
  - `updated_at`: When this order was last updated
  - `metadata`: Additional order details that should be preserved
  """
  @type order_entry :: %{
          order_id: String.t(),
          session_id: String.t(),
          instrument_name: String.t(),
          direction: String.t(),
          status: String.t(),
          created_at: integer(),
          updated_at: integer(),
          metadata: map()
        }

  @typedoc """
  Represents the order context containing all tracked orders.

  - `orders`: Map of order_id to order entry information
  - `orders_by_session`: Map of session_id to list of order_ids
  - `active_session_id`: ID of the currently active session
  """
  @type t :: %__MODULE__{
          orders: %{optional(String.t()) => order_entry()},
          orders_by_session: %{optional(String.t()) => list(String.t())},
          active_session_id: String.t() | nil
        }

  defstruct orders: %{},
            orders_by_session: %{},
            active_session_id: nil

  @doc """
  Creates a new OrderContext instance.

  ## Returns
  - A new empty OrderContext
  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @doc """
  Registers a new order with the order context.

  ## Parameters
  - `context`: The current OrderContext
  - `order`: The order information to register
  - `session_id`: The ID of the session creating this order

  ## Returns
  - `{:ok, updated_context}`: Updated OrderContext with the new order
  """
  @spec register_order(t(), map(), String.t()) :: {:ok, t()}
  def register_order(context, order, session_id) do
    now = System.system_time(:millisecond)
    order_id = Map.get(order, "order_id")

    # Create order entry
    order_entry = %{
      order_id: order_id,
      session_id: session_id,
      instrument_name: Map.get(order, "instrument_name"),
      direction: Map.get(order, "direction"),
      status: Map.get(order, "order_state", "open"),
      created_at: now,
      updated_at: now,
      metadata: order
    }

    # Update orders map
    updated_orders = Map.put(context.orders, order_id, order_entry)

    # Update orders_by_session map
    current_session_orders = Map.get(context.orders_by_session, session_id, [])
    updated_session_orders = [order_id | current_session_orders]

    updated_orders_by_session =
      Map.put(context.orders_by_session, session_id, updated_session_orders)

    # Create updated context
    updated_context = %{
      context
      | orders: updated_orders,
        orders_by_session: updated_orders_by_session,
        active_session_id: session_id
    }

    # Emit telemetry
    :telemetry.execute(
      [:deribit_ex, :order_context, :order_registered],
      %{timestamp: now},
      %{
        order_id: order_id,
        session_id: session_id,
        instrument_name: Map.get(order, "instrument_name")
      }
    )

    {:ok, updated_context}
  end

  @doc """
  Updates an existing order in the context.

  ## Parameters
  - `context`: The current OrderContext
  - `order`: The updated order information

  ## Returns
  - `{:ok, updated_context}`: Updated OrderContext with the modified order
  - `{:error, :not_found}`: If the order doesn't exist in the context
  """
  @spec update_order(t(), map()) :: {:ok, t()} | {:error, :not_found}
  def update_order(context, order) do
    now = System.system_time(:millisecond)
    order_id = Map.get(order, "order_id")

    case Map.get(context.orders, order_id) do
      nil ->
        {:error, :not_found}

      existing_entry ->
        # Create updated entry
        updated_entry = %{
          existing_entry
          | status: Map.get(order, "order_state", existing_entry.status),
            updated_at: now,
            metadata: Map.merge(existing_entry.metadata, order)
        }

        # Update orders map
        updated_orders = Map.put(context.orders, order_id, updated_entry)
        updated_context = %{context | orders: updated_orders}

        # Emit telemetry
        :telemetry.execute(
          [:deribit_ex, :order_context, :order_updated],
          %{timestamp: now},
          %{
            order_id: order_id,
            session_id: existing_entry.session_id,
            status: updated_entry.status
          }
        )

        {:ok, updated_context}
    end
  end

  @doc """
  Handles a session transition by migrating order tracking.

  This is called when tokens are exchanged or forked, to ensure
  order state is preserved across session changes.

  ## Parameters
  - `context`: The current OrderContext
  - `prev_session`: The previous session that is being transitioned from
  - `new_session`: The new session being transitioned to

  ## Returns
  - `{:ok, updated_context}`: Updated OrderContext with the session transition
  """
  @spec handle_session_transition(t(), SessionContext.t(), SessionContext.t()) :: {:ok, t()}
  def handle_session_transition(context, prev_session, new_session) do
    now = System.system_time(:millisecond)

    # Update active session ID
    updated_context = %{context | active_session_id: new_session.id}

    # We don't actually need to migrate the orders - we just track which session
    # created them for auditing/debugging purposes

    # Emit telemetry for the transition
    :telemetry.execute(
      [:deribit_ex, :order_context, :session_transition],
      %{timestamp: now},
      %{
        previous_session_id: prev_session.id,
        new_session_id: new_session.id,
        transition_type: new_session.transition,
        order_count: length(Map.get(context.orders_by_session, prev_session.id, []))
      }
    )

    {:ok, updated_context}
  end

  @doc """
  Gets all orders from the specified session.

  ## Parameters
  - `context`: The current OrderContext
  - `session_id`: The session ID to get orders for

  ## Returns
  - `{:ok, orders}`: List of orders for the session
  """
  @spec get_orders_for_session(t(), String.t()) :: {:ok, list(order_entry())}
  def get_orders_for_session(context, session_id) do
    order_ids = Map.get(context.orders_by_session, session_id, [])
    orders = Enum.map(order_ids, fn id -> Map.get(context.orders, id) end)
    {:ok, orders}
  end

  @doc """
  Gets all active (open) orders from the specified session.

  ## Parameters
  - `context`: The current OrderContext
  - `session_id`: The session ID to get active orders for

  ## Returns
  - `{:ok, orders}`: List of active orders for the session
  """
  @spec get_active_orders_for_session(t(), String.t()) :: {:ok, list(order_entry())}
  def get_active_orders_for_session(context, session_id) do
    {:ok, orders} = get_orders_for_session(context, session_id)
    active_orders = Enum.filter(orders, fn order -> order.status == "open" end)
    {:ok, active_orders}
  end
end
