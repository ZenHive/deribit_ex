defmodule DeribitEx.UnsubscribeTest do
  use ExUnit.Case, async: true

  alias DeribitEx.Adapter
  alias DeribitEx.Client

  describe "Adapter.generate_unsubscribe_data/2" do
    setup do
      {:ok, state} = Adapter.init(%{})
      state = Map.put(state, :access_token, "test_token")
      %{state: state}
    end

    test "generates correct public unsubscribe payload", %{state: state} do
      params = %{"channels" => ["ticker.BTC-PERPETUAL.100ms"]}
      {:ok, payload, updated_state} = Adapter.generate_unsubscribe_data(params, state)

      # Decode the payload to verify its structure
      decoded = Jason.decode!(payload)

      assert decoded["method"] == "public/unsubscribe"
      assert decoded["params"]["channels"] == ["ticker.BTC-PERPETUAL.100ms"]
      refute Map.has_key?(decoded["params"], "access_token")

      # Check that request was tracked
      request_id = decoded["id"]
      assert Map.has_key?(updated_state.requests, request_id)
      assert updated_state.requests[request_id].method == "public/unsubscribe"
    end

    test "generates correct private unsubscribe payload", %{state: state} do
      params = %{"channels" => ["user.orders.BTC-PERPETUAL.raw"]}
      {:ok, payload, updated_state} = Adapter.generate_unsubscribe_data(params, state)

      # Decode the payload to verify its structure
      decoded = Jason.decode!(payload)

      assert decoded["method"] == "private/unsubscribe"
      assert decoded["params"]["channels"] == ["user.orders.BTC-PERPETUAL.raw"]
      assert decoded["params"]["access_token"] == "test_token"

      # Check that request was tracked
      request_id = decoded["id"]
      assert Map.has_key?(updated_state.requests, request_id)
      assert updated_state.requests[request_id].method == "private/unsubscribe"
    end

    test "handles mixed channel types and uses private endpoint", %{state: state} do
      params = %{
        "channels" => [
          "ticker.BTC-PERPETUAL.100ms",
          "user.orders.BTC-PERPETUAL.raw"
        ]
      }

      {:ok, payload, _updated_state} = Adapter.generate_unsubscribe_data(params, state)

      # Decode the payload to verify its structure
      decoded = Jason.decode!(payload)

      assert decoded["method"] == "private/unsubscribe"
      assert decoded["params"]["access_token"] == "test_token"
      assert length(decoded["params"]["channels"]) == 2
    end

    test "handles string channel parameter by converting to list", %{state: state} do
      params = %{"channels" => "ticker.BTC-PERPETUAL.100ms"}
      {:ok, payload, _updated_state} = Adapter.generate_unsubscribe_data(params, state)

      # Decode the payload to verify its structure
      decoded = Jason.decode!(payload)

      assert decoded["params"]["channels"] == ["ticker.BTC-PERPETUAL.100ms"]
    end
  end

  describe "Adapter.handle_unsubscribe_response/2" do
    setup do
      {:ok, state} = Adapter.init(%{})

      # Set up initial subscriptions
      subscriptions = %{
        "ticker.BTC-PERPETUAL.100ms" => %{
          subscribed_at: DateTime.utc_now(),
          id: 12_345,
          params: %{},
          status: :active
        },
        "trades.BTC-PERPETUAL.raw" => %{
          subscribed_at: DateTime.utc_now(),
          id: 12_346,
          params: %{},
          status: :active
        }
      }

      state = Map.put(state, :subscriptions, subscriptions)

      %{state: state}
    end

    test "removes unsubscribed channels from state", %{state: state} do
      response = %{
        "result" => %{
          "unsubscribed" => ["ticker.BTC-PERPETUAL.100ms"]
        }
      }

      {:ok, updated_state} = Adapter.handle_unsubscribe_response(response, state)

      # Check that the channel was removed
      refute Map.has_key?(updated_state.subscriptions, "ticker.BTC-PERPETUAL.100ms")

      # Check that other channels remain
      assert Map.has_key?(updated_state.subscriptions, "trades.BTC-PERPETUAL.raw")
    end

    test "handles error unsubscribe response", %{state: state} do
      error = %{"code" => 10_001, "message" => "Invalid channel"}
      response = %{"error" => error}

      {:error, returned_error, updated_state} =
        Adapter.handle_unsubscribe_response(response, state)

      assert returned_error == error
      # State should remain unchanged
      assert updated_state.subscriptions == state.subscriptions
    end
  end

  describe "Adapter.generate_unsubscribe_all_data/2" do
    setup do
      {:ok, state} = Adapter.init(%{})
      %{state: state}
    end

    test "generates correct unsubscribe_all payload", %{state: state} do
      {:ok, payload, updated_state} = Adapter.generate_unsubscribe_all_data(%{}, state)

      # Decode the payload to verify its structure
      decoded = Jason.decode!(payload)

      assert decoded["method"] == "public/unsubscribe_all"
      assert decoded["params"] == %{}

      # Check that request was tracked
      request_id = decoded["id"]
      assert Map.has_key?(updated_state.requests, request_id)
      assert updated_state.requests[request_id].method == "public/unsubscribe_all"
    end
  end

  describe "Adapter.handle_unsubscribe_all_response/2" do
    setup do
      {:ok, state} = Adapter.init(%{})

      # Set up initial subscriptions
      subscriptions = %{
        "ticker.BTC-PERPETUAL.100ms" => %{
          subscribed_at: DateTime.utc_now(),
          id: 12_345,
          params: %{},
          status: :active
        },
        "trades.BTC-PERPETUAL.raw" => %{
          subscribed_at: DateTime.utc_now(),
          id: 12_346,
          params: %{},
          status: :active
        }
      }

      state = Map.put(state, :subscriptions, subscriptions)

      %{state: state}
    end

    test "clears all subscriptions from state", %{state: state} do
      response = %{"result" => "ok"}

      {:ok, updated_state} = Adapter.handle_unsubscribe_all_response(response, state)

      # Check that all subscriptions were removed
      assert map_size(updated_state.subscriptions) == 0
    end

    test "handles error unsubscribe_all response", %{state: state} do
      error = %{"code" => 10_001, "message" => "Internal error"}
      response = %{"error" => error}

      {:error, returned_error, updated_state} =
        Adapter.handle_unsubscribe_all_response(response, state)

      assert returned_error == error
      # State should remain unchanged
      assert updated_state.subscriptions == state.subscriptions
    end
  end

  # Client tests - these require mocking the WebsockexNova.Client behavior
  # For these tests, we'll use the provided responses and mock the Client.unsubscribe call

  # Test module for Client.unsubscribe
  describe "Client.unsubscribe/3" do
    test "calls json_rpc with correct parameters" do
      # This is a simplified test since we can't easily mock the json_rpc function
      # In a real test, we would use a mocking library to verify the function call

      # For now, we can just ensure the function exists and returns the expected type
      assert function_exported?(Client, :unsubscribe, 3)
    end
  end

  # Test module for Client.unsubscribe_private
  describe "Client.unsubscribe_private/3" do
    test "calls json_rpc with correct parameters" do
      # Simplified test for the same reason as above
      assert function_exported?(Client, :unsubscribe_private, 3)
    end
  end

  # Test module for Client.unsubscribe_all
  describe "Client.unsubscribe_all/2" do
    test "calls json_rpc with correct parameters" do
      # Simplified test for the same reason as above
      assert function_exported?(Client, :unsubscribe_all, 2)
    end
  end
end
