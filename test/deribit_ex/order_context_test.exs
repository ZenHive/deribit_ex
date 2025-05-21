defmodule DeribitEx.OrderContextTest do
  use ExUnit.Case, async: true

  alias DeribitEx.OrderContext
  alias DeribitEx.SessionContext

  describe "new/0" do
    test "creates a new empty OrderContext" do
      context = OrderContext.new()

      assert context.orders == %{}
      assert context.orders_by_session == %{}
      assert context.active_session_id == nil
    end
  end

  describe "register_order/3" do
    test "registers a new order with the context" do
      context = OrderContext.new()
      session_id = "test_session_123"

      order = %{
        "order_id" => "ETH-123456",
        "instrument_name" => "ETH-PERPETUAL",
        "direction" => "buy",
        "order_state" => "open",
        "price" => 2000.0,
        "amount" => 10.0
      }

      {:ok, updated_context} = OrderContext.register_order(context, order, session_id)

      # Order should be added to the orders map
      assert Map.has_key?(updated_context.orders, "ETH-123456")

      # Order should be tracked by session
      assert "ETH-123456" in Map.get(updated_context.orders_by_session, session_id, [])

      # Active session should be updated
      assert updated_context.active_session_id == session_id

      # Verify order details
      stored_order = updated_context.orders["ETH-123456"]
      assert stored_order.order_id == "ETH-123456"
      assert stored_order.session_id == session_id
      assert stored_order.instrument_name == "ETH-PERPETUAL"
      assert stored_order.direction == "buy"
      assert stored_order.status == "open"
      assert stored_order.metadata == order
    end

    test "handles multiple orders in the same session" do
      context = OrderContext.new()
      session_id = "test_session_123"

      order1 = %{"order_id" => "ETH-123456", "instrument_name" => "ETH-PERPETUAL", "direction" => "buy"}
      order2 = %{"order_id" => "BTC-654321", "instrument_name" => "BTC-PERPETUAL", "direction" => "sell"}

      {:ok, context1} = OrderContext.register_order(context, order1, session_id)
      {:ok, context2} = OrderContext.register_order(context1, order2, session_id)

      # Both orders should be in the orders map
      assert Map.has_key?(context2.orders, "ETH-123456")
      assert Map.has_key?(context2.orders, "BTC-654321")

      # Both orders should be tracked by the same session
      session_orders = Map.get(context2.orders_by_session, session_id, [])
      assert "ETH-123456" in session_orders
      assert "BTC-654321" in session_orders
      assert length(session_orders) == 2
    end
  end

  describe "update_order/2" do
    test "updates an existing order" do
      # Create context with an order
      context = OrderContext.new()
      session_id = "test_session_123"

      original_order = %{
        "order_id" => "ETH-123456",
        "instrument_name" => "ETH-PERPETUAL",
        "direction" => "buy",
        "order_state" => "open",
        "price" => 2000.0,
        "amount" => 10.0,
        "filled_amount" => 0.0
      }

      {:ok, context_with_order} = OrderContext.register_order(context, original_order, session_id)

      # Update the order
      updated_order_data = %{
        "order_id" => "ETH-123456",
        "order_state" => "filled",
        "filled_amount" => 10.0
      }

      {:ok, updated_context} = OrderContext.update_order(context_with_order, updated_order_data)

      # Verify the order was updated
      updated_order = updated_context.orders["ETH-123456"]
      assert updated_order.status == "filled"

      # Original fields should be preserved
      assert updated_order.order_id == "ETH-123456"
      assert updated_order.instrument_name == "ETH-PERPETUAL"
      assert updated_order.direction == "buy"

      # Metadata should be merged
      assert updated_order.metadata["filled_amount"] == 10.0
      assert updated_order.metadata["price"] == 2000.0
    end

    test "returns error for non-existent order" do
      context = OrderContext.new()

      update_data = %{"order_id" => "NONEXISTENT", "order_state" => "filled"}

      result = OrderContext.update_order(context, update_data)

      assert result == {:error, :not_found}
    end
  end

  describe "handle_session_transition/3" do
    test "updates active session ID after transition" do
      # Create sessions
      {:ok, prev_session} =
        SessionContext.new_from_auth(%{
          "access_token" => "old_token",
          "refresh_token" => "old_refresh",
          "expires_in" => 900
        })

      {:ok, new_session} =
        SessionContext.new_from_exchange(
          prev_session,
          %{
            "access_token" => "new_token",
            "refresh_token" => "new_refresh",
            "expires_in" => 900
          },
          123
        )

      # Create order context with orders in previous session
      context = OrderContext.new()

      order = %{"order_id" => "ETH-123456", "instrument_name" => "ETH-PERPETUAL", "direction" => "buy"}
      {:ok, context_with_order} = OrderContext.register_order(context, order, prev_session.id)

      # Handle session transition
      {:ok, transitioned_context} =
        OrderContext.handle_session_transition(
          context_with_order,
          prev_session,
          new_session
        )

      # Active session should be updated
      assert transitioned_context.active_session_id == new_session.id

      # Orders from previous session should still be associated with that session
      session_orders = Map.get(transitioned_context.orders_by_session, prev_session.id, [])
      assert "ETH-123456" in session_orders
    end
  end

  describe "get_orders_for_session/2" do
    test "returns all orders for a given session" do
      # Create context with orders in different sessions
      context = OrderContext.new()

      session1 = "session_123"
      session2 = "session_456"

      order1 = %{"order_id" => "ETH-123", "instrument_name" => "ETH-PERPETUAL", "direction" => "buy"}
      order2 = %{"order_id" => "BTC-456", "instrument_name" => "BTC-PERPETUAL", "direction" => "sell"}
      order3 = %{"order_id" => "SOL-789", "instrument_name" => "SOL-PERPETUAL", "direction" => "buy"}

      {:ok, context1} = OrderContext.register_order(context, order1, session1)
      {:ok, context2} = OrderContext.register_order(context1, order2, session1)
      {:ok, context3} = OrderContext.register_order(context2, order3, session2)

      # Get orders for session1
      {:ok, session1_orders} = OrderContext.get_orders_for_session(context3, session1)

      # Should return both orders from session1
      assert length(session1_orders) == 2

      order_ids = Enum.map(session1_orders, & &1.order_id)
      assert "ETH-123" in order_ids
      assert "BTC-456" in order_ids
      assert "SOL-789" not in order_ids

      # Get orders for session2
      {:ok, session2_orders} = OrderContext.get_orders_for_session(context3, session2)

      # Should return only the order from session2
      assert length(session2_orders) == 1
      assert hd(session2_orders).order_id == "SOL-789"
    end

    test "returns empty list for unknown session" do
      context = OrderContext.new()

      {:ok, orders} = OrderContext.get_orders_for_session(context, "nonexistent_session")

      assert orders == []
    end
  end

  describe "get_active_orders_for_session/2" do
    test "returns only open orders for a session" do
      # Create context with various order states
      context = OrderContext.new()
      session_id = "test_session"

      open_order = %{
        "order_id" => "ETH-123",
        "instrument_name" => "ETH-PERPETUAL",
        "direction" => "buy",
        "order_state" => "open"
      }

      filled_order = %{
        "order_id" => "BTC-456",
        "instrument_name" => "BTC-PERPETUAL",
        "direction" => "sell",
        "order_state" => "filled"
      }

      cancelled_order = %{
        "order_id" => "SOL-789",
        "instrument_name" => "SOL-PERPETUAL",
        "direction" => "buy",
        "order_state" => "cancelled"
      }

      {:ok, context1} = OrderContext.register_order(context, open_order, session_id)
      {:ok, context2} = OrderContext.register_order(context1, filled_order, session_id)
      {:ok, context3} = OrderContext.register_order(context2, cancelled_order, session_id)

      # Get active orders
      {:ok, active_orders} = OrderContext.get_active_orders_for_session(context3, session_id)

      # Should only return the open order
      assert length(active_orders) == 1
      assert hd(active_orders).order_id == "ETH-123"
    end
  end
end
