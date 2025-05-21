defmodule DeribitEx.AdapterTest do
  use ExUnit.Case, async: true

  alias DeribitEx.Adapter

  describe "connection_info/1" do
    test "returns correct defaults for test environment" do
      {:ok, info} = Adapter.connection_info(%{})

      assert info.host == "test.deribit.com"
      assert info.port == 443
      assert info.path == "/ws/api/v2"
      assert info.transport == :tls
    end

    test "host can be overridden" do
      {:ok, info} = Adapter.connection_info(%{host: "custom.deribit.com"})

      assert info.host == "custom.deribit.com"
    end
  end

  describe "init/1" do
    test "initializes state correctly" do
      {:ok, state} = Adapter.init(%{})

      assert state.auth_status == :unauthenticated
      assert state.reconnect_attempts == 0
      assert state.max_reconnect_attempts == 5
      assert map_size(state.subscriptions) == 0
      assert map_size(state.subscription_requests) == 0
    end
  end

  describe "generate_auth_data/1" do
    setup do
      System.put_env("DERIBIT_CLIENT_ID", "test_client_id")
      System.put_env("DERIBIT_CLIENT_SECRET", "test_client_secret")

      on_exit(fn ->
        System.delete_env("DERIBIT_CLIENT_ID")
        System.delete_env("DERIBIT_CLIENT_SECRET")
      end)

      # Initialize state with credentials already set
      {:ok, state} = Adapter.init(%{})

      state =
        put_in(state, [:credentials], %{api_key: "test_client_id", secret: "test_client_secret"})

      %{state: state}
    end

    test "generates correct auth payload", %{state: state} do
      {:ok, payload, updated_state} = Adapter.generate_auth_data(state)

      # Decode the payload to verify its structure
      decoded = Jason.decode!(payload)

      assert decoded["method"] == "public/auth"
      assert decoded["params"]["grant_type"] == "client_credentials"
      assert decoded["params"]["client_id"] == "test_client_id"
      assert decoded["params"]["client_secret"] == "test_client_secret"

      # Check that credentials remain in state
      assert updated_state.credentials.api_key == "test_client_id"
      assert updated_state.credentials.secret == "test_client_secret"
    end
  end

  describe "handle_auth_response/2" do
    setup do
      {:ok, state} = Adapter.init(%{})
      %{state: state}
    end

    test "handles successful auth response", %{state: state} do
      response = %{
        "result" => %{
          "access_token" => "test_token",
          "refresh_token" => "test_refresh_token",
          "expires_in" => 900
        }
      }

      {:ok, updated_state} = Adapter.handle_auth_response(response, state)

      assert updated_state.auth_status == :authenticated
      assert updated_state.access_token == "test_token"
      assert updated_state.auth_expires_in == 900
      assert %DateTime{} = updated_state.auth_expires_at
    end

    test "handles general error auth response", %{state: state} do
      error = %{"code" => 10_001, "message" => "Invalid credentials"}
      response = %{"error" => error}

      {:error, returned_error, updated_state} =
        Adapter.handle_auth_response(response, state)

      assert updated_state.auth_status == :failed
      assert updated_state.auth_error == error
      assert returned_error == error
    end

    test "handles auth token expired error with reconnect", %{state: state} do
      error = %{"code" => 13_010, "message" => "Token expired"}
      response = %{"error" => error}

      {:reconnect, {:auth_error, returned_error}, updated_state} =
        Adapter.handle_auth_response(response, state)

      assert updated_state.auth_status == :failed
      assert updated_state.auth_error == error
      assert returned_error == error
    end

    test "handles invalid token error with reconnect", %{state: state} do
      error = %{"code" => 13_009, "message" => "Invalid token"}
      response = %{"error" => error}

      {:reconnect, {:auth_error, returned_error}, updated_state} =
        Adapter.handle_auth_response(response, state)

      assert updated_state.auth_status == :failed
      assert updated_state.auth_error == error
      assert returned_error == error
    end
  end

  describe "subscribe/3" do
    setup do
      {:ok, state} = Adapter.init(%{})
      state = Map.put(state, :access_token, "test_token")
      %{state: state}
    end

    test "generates correct public subscription payload", %{state: state} do
      channel = "ticker.BTC-PERPETUAL.100ms"
      {:ok, payload, updated_state} = Adapter.subscribe(channel, %{}, state)

      # Decode the payload to verify its structure
      decoded = Jason.decode!(payload)

      assert decoded["method"] == "public/subscribe"
      assert decoded["params"]["channels"] == [channel]

      # Check that subscription request was stored
      subscription_id = decoded["id"]
      assert get_in(updated_state, [:subscription_requests, subscription_id]) != nil
    end

    test "generates correct private subscription payload", %{state: state} do
      channel = "user.orders.BTC-PERPETUAL.raw"
      {:ok, payload, updated_state} = Adapter.subscribe(channel, %{}, state)

      # Decode the payload to verify its structure
      decoded = Jason.decode!(payload)

      assert decoded["method"] == "private/subscribe"
      assert decoded["params"]["channels"] == [channel]
      assert decoded["params"]["access_token"] == "test_token"

      # Check that subscription request was stored
      subscription_id = decoded["id"]
      assert get_in(updated_state, [:subscription_requests, subscription_id]) != nil
    end
  end

  describe "handle_subscription_response/2" do
    setup do
      {:ok, state} = Adapter.init(%{})

      # Add a subscription request to state
      subscription_id = 12_345
      channel = "ticker.BTC-PERPETUAL.100ms"

      subscription_requests = %{
        subscription_id => %{
          channel: channel,
          params: %{}
        }
      }

      state = Map.put(state, :subscription_requests, subscription_requests)

      %{state: state, subscription_id: subscription_id, channel: channel}
    end

    test "handles successful subscription response", %{
      state: state,
      subscription_id: id,
      channel: channel
    } do
      response = %{
        "id" => id,
        "result" => %{
          "subscribed" => [channel]
        }
      }

      {:ok, updated_state} = Adapter.handle_subscription_response(response, state)

      # Check that subscription was moved from requests to active subscriptions
      assert Map.has_key?(updated_state.subscriptions, channel)
      assert updated_state.subscriptions[channel].id == id
      assert updated_state.subscriptions[channel].status == :active

      # Check that request was removed
      assert Map.get(updated_state.subscription_requests, id) == nil
    end

    test "handles error subscription response", %{state: state} do
      error = %{"code" => 10_001, "message" => "Invalid channel"}
      response = %{"error" => error}

      {:error, returned_error, updated_state} =
        Adapter.handle_subscription_response(response, state)

      assert returned_error == error
      # State should remain unchanged except for adding the error
      assert updated_state.subscription_requests == state.subscription_requests
    end
  end

  describe "handle_message/2" do
    setup do
      {:ok, state} = Adapter.init(%{})
      %{state: state}
    end

    test "detects when authentication is needed", %{state: state} do
      message = %{
        "error" => %{
          "code" => 13_778,
          "message" => "raw_subscriptions_not_available_for_unauthorized"
        }
      }

      {:needs_auth, returned_message, _updated_state} =
        Adapter.handle_message(message, state)

      assert returned_message == message
    end
  end

  describe "send_rpc_request/4" do
    setup do
      {:ok, state} = Adapter.init(%{})
      state = Map.put(state, :access_token, "test_token")

      # Set up telemetry handler to catch events
      test_pid = self()

      :ok =
        :telemetry.attach(
          "test-rpc-request",
          [:deribit_ex, :rpc, :request],
          fn event_name, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event_name, measurements, metadata})
          end,
          nil
        )

      on_exit(fn ->
        :telemetry.detach("test-rpc-request")
      end)

      %{state: state}
    end

    test "generates and tracks public request", %{state: state} do
      method = "public/get_time"
      params = %{}

      {:ok, encoded_request, updated_state} =
        Adapter.send_rpc_request(method, params, state)

      # Verify the request was encoded properly
      decoded = Jason.decode!(encoded_request)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == method
      assert decoded["params"] == params
      assert is_integer(decoded["id"])

      # Verify request was tracked
      request_id = decoded["id"]
      assert Map.has_key?(updated_state.requests, request_id)
      assert updated_state.requests[request_id].method == method

      # Verify telemetry was emitted
      assert_received {:telemetry, [:deribit_ex, :rpc, :request], %{system_time: _}, metadata}
      assert metadata.method == method
      assert metadata.request_id == request_id
    end

    test "adds auth token for private request", %{state: state} do
      method = "private/get_position"
      params = %{instrument_name: "BTC-PERPETUAL"}

      {:ok, encoded_request, _updated_state} =
        Adapter.send_rpc_request(method, params, state)

      # Verify auth token was added
      decoded = Jason.decode!(encoded_request)
      assert decoded["params"]["access_token"] == "test_token"
      assert decoded["params"]["instrument_name"] == "BTC-PERPETUAL"
    end

    test "respects custom timeout", %{state: state} do
      method = "public/get_time"
      params = %{}
      options = %{timeout: 20_000}

      {:ok, _encoded_request, updated_state} =
        Adapter.send_rpc_request(method, params, state, options)

      # The timeout should have been set up, but we can't easily test the actual timer
      # Instead, we verify that the options were stored with the request
      [request_id] = Map.keys(updated_state.requests)
      assert updated_state.requests[request_id].options == options
    end
  end

  describe "handle_info/2" do
    setup do
      {:ok, state} = Adapter.init(%{})
      %{state: state}
    end

    test "ignores :refresh_auth when not authenticated", %{state: state} do
      {:ok, updated_state} = Adapter.handle_info(:refresh_auth, state)
      assert updated_state.auth_status == :unauthenticated
    end

    test "handles :refresh_auth when token is about to expire", %{state: state} do
      # Create a state with an expiring token
      expiring_state =
        state
        |> Map.put(:auth_status, :authenticated)
        |> Map.put(:access_token, "test_token")
        |> Map.put(:auth_expires_in, 30)
        |> Map.put(:auth_refresh_threshold, 60)
        |> Map.put(:auth_expires_at, DateTime.add(DateTime.utc_now(), 30, :second))
        |> Map.put(:credentials, %{api_key: "test_key", secret: "test_secret"})

      # Refresh should be triggered
      {:ok, request, _updated_state} = Adapter.handle_info(:refresh_auth, expiring_state)

      # Request should be a JSON-RPC auth request
      decoded = Jason.decode!(request)
      assert decoded["method"] == "public/auth"
      assert decoded["params"]["client_id"] == "test_key"
      assert decoded["params"]["client_secret"] == "test_secret"
    end

    test "ignores unknown messages", %{state: state} do
      {:ok, updated_state} = Adapter.handle_info(:unknown_message, state)
      assert updated_state == state
    end
  end

  describe "handle_connect/2" do
    setup do
      {:ok, state} = Adapter.init(%{})

      # Set up telemetry handler to catch events
      test_pid = self()

      :ok =
        :telemetry.attach(
          "test-connection-opened",
          [:deribit_ex, :connection, :opened],
          fn event_name, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event_name, measurements, metadata})
          end,
          nil
        )

      :ok =
        :telemetry.attach(
          "test-reconnect-auth",
          [:deribit_ex, :connection, :reconnect_with_auth],
          fn event_name, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event_name, measurements, metadata})
          end,
          nil
        )

      on_exit(fn ->
        :telemetry.detach("test-connection-opened")
        :telemetry.detach("test-reconnect-auth")
      end)

      %{state: state}
    end

    test "emits telemetry event and updates state on initial connection", %{state: state} do
      # Call handle_connect
      {:ok, updated_state} = Adapter.handle_connect(:http, state)

      # Verify telemetry event was sent
      assert_received {:telemetry, [:deribit_ex, :connection, :opened], %{system_time: _}, metadata}

      assert metadata.transport == :http
      assert metadata.reconnect_attempts == 0

      # Verify state was updated
      assert updated_state.connected_at != nil
      assert updated_state.transport == :http
      assert updated_state.reconnect_attempts == 0
      refute Map.get(updated_state, :need_resubscribe, false)
    end

    test "returns authenticate signal on reconnection with authenticated state", %{state: state} do
      # Prepare a state that indicates a reconnection
      reconnection_state =
        state
        |> Map.put(:reconnect_attempts, 1)
        |> Map.put(:auth_status, :authenticated)
        |> Map.put(:subscriptions, %{"test.channel" => %{status: :active}})
        |> Map.put(:access_token, "old_token")

      # Call handle_connect
      {:authenticate, updated_state} = Adapter.handle_connect(:http, reconnection_state)

      # Verify telemetry events were sent
      assert_received {:telemetry, [:deribit_ex, :connection, :opened], %{system_time: _}, metadata}

      assert metadata.reconnect_attempts == 1

      assert_received {:telemetry, [:deribit_ex, :connection, :reconnect_with_auth], %{system_time: _},
                       subscription_metadata}

      assert subscription_metadata.subscription_count == 1

      # Verify state reflects reconnection status
      assert updated_state.reconnect_attempts == 0
      # Auth status is preserved for WebsockexNova to handle
      assert updated_state.auth_status == :authenticated
      assert updated_state.need_resubscribe == true
    end
  end

  describe "terminate/2" do
    setup do
      {:ok, state} = Adapter.init(%{})

      state =
        state
        |> Map.put(:connected_at, DateTime.add(DateTime.utc_now(), -10, :second))
        |> Map.put(:max_reconnect_attempts, 3)

      # Set up telemetry handler to catch events
      test_pid = self()

      :ok =
        :telemetry.attach(
          "test-connection-closed",
          [:deribit_ex, :connection, :closed],
          fn event_name, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event_name, measurements, metadata})
          end,
          nil
        )

      :ok =
        :telemetry.attach(
          "test-auth-error-reconnect",
          [:deribit_ex, :connection, :auth_error_reconnect],
          fn event_name, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event_name, measurements, metadata})
          end,
          nil
        )

      on_exit(fn ->
        :telemetry.detach("test-connection-closed")
        :telemetry.detach("test-auth-error-reconnect")
      end)

      %{state: state}
    end

    test "emits telemetry event and doesn't reconnect on normal termination", %{state: state} do
      # Call terminate with normal reason
      :ok = Adapter.terminate(:normal, state)

      # Verify telemetry event was sent
      assert_received {:telemetry, [:deribit_ex, :connection, :closed], %{system_time: _}, metadata}

      # Verify metadata includes reason and duration
      assert metadata.reason == :normal
      # at least 10 seconds in milliseconds
      assert metadata.duration >= 10_000
      assert metadata.will_reconnect == false
    end

    test "handles reconnection for network errors", %{state: state} do
      # Call terminate with network error
      {:reconnect, updated_state} = Adapter.terminate({:error, :network_error}, state)

      # Verify telemetry event
      assert_received {:telemetry, [:deribit_ex, :connection, :closed], %{system_time: _}, metadata}

      assert metadata.reason == {:error, :network_error}
      assert metadata.will_reconnect == true

      # Check reconnect counter was incremented
      assert updated_state.reconnect_attempts == 1
    end

    test "respects max reconnect attempts", %{state: state} do
      # Set reconnect attempts to max
      state_at_max = Map.put(state, :reconnect_attempts, 3)

      # Call terminate with network error when already at max attempts
      :ok = Adapter.terminate({:error, :network_error}, state_at_max)

      # Verify telemetry indicates no more reconnects
      assert_received {:telemetry, [:deribit_ex, :connection, :closed], %{system_time: _}, metadata}

      assert metadata.reason == {:error, :network_error}
      assert metadata.will_reconnect == false
      assert metadata.reconnect_attempts == 3
      assert metadata.max_reconnect_attempts == 3
    end

    test "handles unauthenticated auth errors with normal reconnection", %{state: state} do
      # Call terminate with auth error but not authenticated
      {:reconnect, updated_state} =
        Adapter.terminate({:auth_error, "Invalid credentials"}, state)

      # Verify telemetry event
      assert_received {:telemetry, [:deribit_ex, :connection, :closed], %{system_time: _}, metadata}

      assert metadata.will_reconnect == true
      assert metadata.auth_status == :unauthenticated

      # Check reconnect counter was incremented
      assert updated_state.reconnect_attempts == 1
    end

    test "uses reconnect_and_authenticate for authenticated auth errors", %{state: state} do
      # Set up an authenticated state
      authenticated_state =
        state
        |> Map.put(:auth_status, :authenticated)
        |> Map.put(:access_token, "test_token")

      # Call terminate with auth error
      {:reconnect_and_authenticate, updated_state} =
        Adapter.terminate({:auth_error, "Token expired"}, authenticated_state)

      # Verify telemetry events
      assert_received {:telemetry, [:deribit_ex, :connection, :closed], %{system_time: _}, metadata}

      assert metadata.will_reconnect == true
      assert metadata.auth_status == :authenticated

      assert_received {:telemetry, [:deribit_ex, :connection, :auth_error_reconnect], %{system_time: _}, error_metadata}

      assert error_metadata.reason == {:auth_error, "Token expired"}

      # Check reconnect counter was incremented
      assert updated_state.reconnect_attempts == 1
    end
  end
end
