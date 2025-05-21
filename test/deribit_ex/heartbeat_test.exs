defmodule DeribitEx.HeartbeatTest do
  use ExUnit.Case

  alias DeribitEx.Adapter
  alias DeribitEx.Client

  # Setup for integration tests
  setup do
    :ok
  end

  describe "Adapter heartbeat functions" do
    test "generate_set_heartbeat_data/2 creates proper RPC payload" do
      # Create state for testing
      state = %{requests: %{}}

      # Set a test interval
      params = %{"interval" => 30}

      # Generate payload
      {:ok, payload, updated_state} = Adapter.generate_set_heartbeat_data(params, state)

      # Verify the payload is a valid JSON string
      assert is_binary(payload)

      # Parse and validate the payload
      decoded = Jason.decode!(payload)

      # Verify essential RPC elements
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "public/set_heartbeat"
      # ID can be a number or string
      assert decoded["id"] != nil
      assert decoded["params"]["interval"] == 30

      # Verify state updates
      assert updated_state.heartbeat_enabled == true
      assert updated_state.heartbeat_interval == 30
      assert Map.has_key?(updated_state.requests, decoded["id"])
    end

    test "generate_set_heartbeat_data/2 enforces minimum interval of 10" do
      # Create state for testing
      state = %{requests: %{}}

      # Set a too small interval
      params = %{"interval" => 5}

      # Generate payload
      {:ok, payload, updated_state} = Adapter.generate_set_heartbeat_data(params, state)

      # Parse and validate
      decoded = Jason.decode!(payload)

      # Verify minimum interval enforcement
      assert decoded["params"]["interval"] == 10
      assert updated_state.heartbeat_interval == 10
    end

    test "generate_disable_heartbeat_data/2 creates proper RPC payload" do
      # Create state for testing
      state = %{requests: %{}, heartbeat_enabled: true, heartbeat_interval: 30}

      # Generate payload
      {:ok, payload, updated_state} = Adapter.generate_disable_heartbeat_data(%{}, state)

      # Verify the payload is a valid JSON string
      assert is_binary(payload)

      # Parse and validate the payload
      decoded = Jason.decode!(payload)

      # Verify essential RPC elements
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "public/disable_heartbeat"
      # ID can be a number or string
      assert decoded["id"] != nil

      # Verify state updates
      assert Map.has_key?(updated_state.requests, decoded["id"])
    end

    test "handle_set_heartbeat_response/2 processes success response" do
      # Create state for testing
      state = %{}

      # Create a success response
      response = %{"result" => "ok"}

      # Process the response
      {:ok, updated_state} = Adapter.handle_set_heartbeat_response(response, state)

      # State should remain the same on success
      assert updated_state == state
    end

    test "handle_set_heartbeat_response/2 processes error response" do
      # Create state for testing
      state = %{heartbeat_enabled: true}

      # Create an error response
      error = %{"code" => 10_001, "message" => "Test error"}
      response = %{"error" => error}

      # Process the response
      {:error, returned_error, updated_state} =
        Adapter.handle_set_heartbeat_response(response, state)

      # Error should be returned
      assert returned_error == error

      # State should update the heartbeat flag
      assert updated_state.heartbeat_enabled == false
    end

    test "handle_disable_heartbeat_response/2 processes success response" do
      # Create state for testing
      state = %{heartbeat_enabled: true, heartbeat_interval: 30}

      # Create a success response
      response = %{"result" => "ok"}

      # Process the response
      {:ok, updated_state} = Adapter.handle_disable_heartbeat_response(response, state)

      # State should update on success
      assert updated_state.heartbeat_enabled == false
      refute Map.has_key?(updated_state, :heartbeat_interval)
    end

    test "handle_disable_heartbeat_response/2 processes error response" do
      # Create state for testing
      state = %{heartbeat_enabled: true}

      # Create an error response
      error = %{"code" => 10_001, "message" => "Test error"}
      response = %{"error" => error}

      # Process the response
      {:error, returned_error, updated_state} =
        Adapter.handle_disable_heartbeat_response(response, state)

      # Error should be returned
      assert returned_error == error

      # State should not change
      assert updated_state == state
    end
  end

  describe "Client heartbeat methods" do
    @tag :integration
    test "set_heartbeat/3 works with the real API" do
      # Connect to real API
      {:ok, conn} = Client.connect()

      # Test the function with real API
      result = Client.set_heartbeat(conn, 30)
      assert match?({:ok, _}, result)

      # Close the connection
      Client.disconnect(conn)
    end

    @tag :integration
    test "disable_heartbeat/2 works with the real API" do
      # Connect to real API
      {:ok, conn} = Client.connect()

      # Enable heartbeat first
      {:ok, _} = Client.set_heartbeat(conn, 30)

      # Test the disable function with real API
      result = Client.disable_heartbeat(conn)
      assert match?({:ok, _}, result)

      # Close the connection
      Client.disconnect(conn)
    end
  end
end
