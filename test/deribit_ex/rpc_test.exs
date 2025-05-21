defmodule MarketMaker.WS.DeribitRPCTest do
  use ExUnit.Case, async: true

  alias MarketMaker.WS.DeribitRPC

  describe "generate_request/3" do
    test "generates proper JSON-RPC request structure" do
      method = "public/get_time"
      params = %{}

      {:ok, payload, id} = DeribitRPC.generate_request(method, params)

      assert payload["jsonrpc"] == "2.0"
      assert payload["method"] == method
      assert payload["params"] == params
      assert payload["id"] == id
      assert is_integer(id)
    end

    test "uses provided ID when specified" do
      method = "public/get_time"
      params = %{}
      id = 12_345

      {:ok, payload, returned_id} = DeribitRPC.generate_request(method, params, id)

      assert payload["id"] == id
      assert returned_id == id
    end

    test "handles complex parameter structures" do
      method = "public/auth"

      params = %{
        "grant_type" => "client_credentials",
        "client_id" => "test_id",
        "client_secret" => "test_secret"
      }

      {:ok, payload, _id} = DeribitRPC.generate_request(method, params)

      assert payload["params"] == params
    end

    test "merges with default parameters for known methods" do
      # Test for hello method which has default client_name and client_version
      method = "public/hello"
      params = %{"custom_param" => "value"}

      {:ok, payload, _id} = DeribitRPC.generate_request(method, params)

      assert payload["params"]["client_name"] == "market_maker"
      assert payload["params"]["client_version"] == "1.0.0"
      assert payload["params"]["custom_param"] == "value"
    end

    test "emits telemetry events when generating request" do
      method = "public/get_time"
      params = %{}

      # Setup telemetry handler
      events = [[:market_maker, :rpc, :request_generated]]
      ref = MarketMaker.TelemetryTestHelpers.attach_event_handlers(self(), events)

      {:ok, _payload, id} = DeribitRPC.generate_request(method, params)

      # Assert telemetry event was emitted
      assert_receive {[:market_maker, :rpc, :request_generated], ^ref, measurements, metadata}
      assert is_map(measurements)
      assert is_integer(measurements.system_time)
      assert metadata.method == method
      assert metadata.request_id == id

      # Clean up telemetry handler
      MarketMaker.TelemetryTestHelpers.detach_event_handlers(ref, events)
    end

    test "raises FunctionClauseError when params is not a map" do
      method = "public/get_time"
      invalid_params = "not_a_map"

      assert_raise FunctionClauseError, fn ->
        DeribitRPC.generate_request(method, invalid_params)
      end

      assert_raise FunctionClauseError, fn ->
        DeribitRPC.generate_request(method, ["array", "not", "a", "map"])
      end

      assert_raise FunctionClauseError, fn ->
        DeribitRPC.generate_request(method, 123)
      end
    end
  end

  describe "parse_response/1" do
    test "handles successful response with result" do
      response = %{
        "jsonrpc" => "2.0",
        "id" => 123,
        "result" => "success"
      }

      assert DeribitRPC.parse_response(response) == {:ok, "success"}
    end

    test "handles error response" do
      error = %{"code" => 10_001, "message" => "Error message"}

      response = %{
        "jsonrpc" => "2.0",
        "id" => 123,
        "error" => error
      }

      assert DeribitRPC.parse_response(response) == {:error, error}
    end

    test "emits telemetry for error responses" do
      error = %{"code" => 10_001, "message" => "Error message"}

      response = %{
        "jsonrpc" => "2.0",
        "id" => 123,
        "error" => error
      }

      # Setup telemetry handler
      events = [[:market_maker, :rpc, :error_response]]
      ref = MarketMaker.TelemetryTestHelpers.attach_event_handlers(self(), events)

      DeribitRPC.parse_response(response)

      # Assert telemetry event was emitted
      assert_receive {[:market_maker, :rpc, :error_response], ^ref, measurements, metadata}
      assert is_map(measurements)
      assert is_integer(measurements.system_time)
      assert metadata.error == error
      assert metadata.request_id == 123
      assert metadata.usermsg == "Error message"

      # Clean up telemetry handler
      MarketMaker.TelemetryTestHelpers.detach_event_handlers(ref, events)
    end

    test "handles invalid response structure and emits telemetry" do
      invalid_response = %{"foo" => "bar"}

      # Setup telemetry handler to capture the event
      events = [[:market_maker, :rpc, :invalid_response]]
      ref = MarketMaker.TelemetryTestHelpers.attach_event_handlers(self(), events)

      assert DeribitRPC.parse_response(invalid_response) ==
               {:error, {:invalid_response, invalid_response}}

      # Assert telemetry event was emitted with expected data
      assert_receive {[:market_maker, :rpc, :invalid_response], _ref, measurements, metadata}
      assert is_map(measurements)
      assert is_integer(measurements.system_time)
      assert metadata.response == invalid_response

      # Clean up telemetry handler
      MarketMaker.TelemetryTestHelpers.detach_event_handlers(ref, events)
    end
  end

  describe "needs_reauth?/1" do
    test "detects authentication required errors" do
      # not_authorized
      assert DeribitRPC.needs_reauth?(%{"code" => 13_004, "message" => "Not authorized"})
      # invalid_token
      assert DeribitRPC.needs_reauth?(%{"code" => 13_009, "message" => "Invalid token"})
      # token_expired
      assert DeribitRPC.needs_reauth?(%{"code" => 13_010, "message" => "Token expired"})
      # token_missing
      assert DeribitRPC.needs_reauth?(%{"code" => 13_011, "message" => "Access token required"})
    end

    test "returns false for other error types" do
      refute DeribitRPC.needs_reauth?(%{"code" => 10_001, "message" => "Error"})
      refute DeribitRPC.needs_reauth?(%{"message" => "No code"})
      refute DeribitRPC.needs_reauth?("Not a map")
    end
  end

  describe "classify_error/1" do
    test "classifies authentication errors" do
      assert DeribitRPC.classify_error(%{"code" => 13_004, "message" => "Not authorized"}) ==
               {:auth, :not_authorized, "Not authorized"}

      assert DeribitRPC.classify_error(%{"code" => 13_009, "message" => "Invalid token"}) ==
               {:auth, :invalid_token, "Invalid token"}

      assert DeribitRPC.classify_error(%{"code" => 13_010, "message" => "Token expired"}) ==
               {:auth, :token_expired, "Token expired"}
    end

    test "classifies rate limit errors" do
      assert DeribitRPC.classify_error(%{"code" => 10_429, "message" => "Too many requests"}) ==
               {:rate_limit, :too_many_requests, "Too many requests"}

      assert DeribitRPC.classify_error(%{"code" => 11_010, "message" => "Max requests exceeded"}) ==
               {:rate_limit, :max_requests_exceeded, "Max requests exceeded"}
    end

    test "classifies validation errors" do
      assert DeribitRPC.classify_error(%{"code" => 10_001, "message" => "Invalid params"}) ==
               {:validation, :invalid_params, "Invalid params"}
    end

    test "handles unknown error codes" do
      assert DeribitRPC.classify_error(%{"code" => 99_999, "message" => "Unknown error"}) ==
               {:unknown, :unknown_code, "Unknown error"}
    end

    test "handles invalid error format" do
      assert DeribitRPC.classify_error("not a map") ==
               {:unknown, :invalid_error_format, "Invalid error format"}

      assert DeribitRPC.classify_error(%{}) ==
               {:unknown, :invalid_error_format, "Invalid error format"}
    end
  end

  describe "method_type/1" do
    test "correctly identifies public methods" do
      assert DeribitRPC.method_type("public/get_time") == :public
      assert DeribitRPC.method_type("public/auth") == :public
      assert DeribitRPC.method_type("public/test") == :public
    end

    test "correctly identifies private methods" do
      assert DeribitRPC.method_type("private/get_position") == :private
      assert DeribitRPC.method_type("private/enable_cancel_on_disconnect") == :private
      assert DeribitRPC.method_type("private/get_transfers") == :private
    end

    test "returns :unknown for unrecognized methods" do
      assert DeribitRPC.method_type("get_time") == :unknown
      assert DeribitRPC.method_type("invalid") == :unknown
      assert DeribitRPC.method_type("") == :unknown
    end
  end

  describe "requires_auth?/1" do
    test "returns true for private methods" do
      assert DeribitRPC.requires_auth?("private/get_position")
      assert DeribitRPC.requires_auth?("private/enable_cancel_on_disconnect")
    end

    test "returns false for public methods" do
      refute DeribitRPC.requires_auth?("public/get_time")
      refute DeribitRPC.requires_auth?("public/auth")
    end

    test "returns false for unrecognized methods" do
      refute DeribitRPC.requires_auth?("invalid_method")
      refute DeribitRPC.requires_auth?("")
    end
  end

  describe "add_auth_params/3" do
    test "adds access_token for private methods" do
      params = %{"param1" => "value1"}
      token = "test_token"

      result = DeribitRPC.add_auth_params(params, "private/get_position", token)

      assert result["access_token"] == token
      assert result["param1"] == "value1"
    end

    test "does not add token for public methods" do
      params = %{"param1" => "value1"}
      token = "test_token"

      result = DeribitRPC.add_auth_params(params, "public/get_time", token)

      refute Map.has_key?(result, "access_token")
      assert result["param1"] == "value1"
    end

    test "does not modify params when token is nil" do
      params = %{"param1" => "value1"}

      result = DeribitRPC.add_auth_params(params, "private/get_position", nil)

      assert result == params
    end
  end

  describe "track_request/5" do
    test "adds request to state" do
      state = %{request_timeout: 15_000}
      id = 12_345
      method = "public/get_time"
      params = %{}

      updated_state = DeribitRPC.track_request(state, id, method, params)

      assert Map.has_key?(updated_state, :requests)
      assert Map.has_key?(updated_state.requests, id)
      assert updated_state.requests[id].method == method
      assert updated_state.requests[id].params == params
      assert updated_state.requests[id].id == id
      assert %DateTime{} = updated_state.requests[id].sent_at
      assert is_reference(updated_state.requests[id].timeout_ref)
    end

    test "preserves existing requests" do
      existing_request = %{
        id: 9999,
        method: "public/test",
        params: %{},
        sent_at: DateTime.utc_now(),
        options: nil,
        timeout_ref: nil
      }

      state = %{requests: %{9999 => existing_request}, request_timeout: 15_000}
      id = 12_345
      method = "public/get_time"
      params = %{}

      updated_state = DeribitRPC.track_request(state, id, method, params)

      assert Map.has_key?(updated_state.requests, 9999)
      assert Map.has_key?(updated_state.requests, id)
    end

    test "uses method-specific timeout values" do
      state = %{request_timeout: 15_000}

      # Auth method should use 30_000 ms timeout
      auth_state = DeribitRPC.track_request(state, 1, "public/auth", %{})

      # Test method should use 2_000 ms timeout
      test_state = DeribitRPC.track_request(state, 2, "public/test", %{})

      assert is_reference(auth_state.requests[1].timeout_ref)
      assert is_reference(test_state.requests[2].timeout_ref)
    end

    test "respects override timeout value in options" do
      state = %{request_timeout: 15_000}
      options = %{timeout: 500}

      updated_state = DeribitRPC.track_request(state, 1, "public/get_time", %{}, options)

      assert is_reference(updated_state.requests[1].timeout_ref)
    end
  end

  describe "remove_tracked_request/2" do
    test "removes specified request from state" do
      # Create a real timeout reference
      timeout_ref = Process.send_after(self(), :test, 10_000)

      existing_request = %{
        id: 12_345,
        method: "public/test",
        params: %{},
        sent_at: DateTime.utc_now(),
        options: nil,
        timeout_ref: timeout_ref
      }

      state = %{requests: %{12_345 => existing_request}}

      updated_state = DeribitRPC.remove_tracked_request(state, 12_345)

      assert map_size(updated_state.requests) == 0

      # Ensure the timer was canceled (should return false if already canceled)
      assert Process.cancel_timer(timeout_ref) == false
    end

    test "handles non-existent request IDs gracefully" do
      state = %{requests: %{}}

      updated_state = DeribitRPC.remove_tracked_request(state, 9999)

      assert updated_state.requests == %{}
    end

    test "preserves other requests" do
      # Create real timeout references
      timeout_ref1 = Process.send_after(self(), :test1, 10_000)
      timeout_ref2 = Process.send_after(self(), :test2, 10_000)

      request1 = %{
        id: 1111,
        method: "public/test",
        params: %{},
        sent_at: DateTime.utc_now(),
        options: nil,
        timeout_ref: timeout_ref1
      }

      request2 = %{
        id: 2222,
        method: "public/get_time",
        params: %{},
        sent_at: DateTime.utc_now(),
        options: nil,
        timeout_ref: timeout_ref2
      }

      state = %{requests: %{1111 => request1, 2222 => request2}}

      updated_state = DeribitRPC.remove_tracked_request(state, 1111)

      refute Map.has_key?(updated_state.requests, 1111)
      assert Map.has_key?(updated_state.requests, 2222)

      # Ensure the first timer was canceled
      assert Process.cancel_timer(timeout_ref1) == false

      # Ensure the second timer is still active
      assert is_integer(Process.cancel_timer(timeout_ref2))
    end

    test "handles missing or invalid timeout_ref" do
      # Request with nil timeout_ref
      request1 = %{
        id: 1111,
        method: "public/test",
        params: %{},
        sent_at: DateTime.utc_now(),
        options: nil,
        timeout_ref: nil
      }

      # Request with invalid timeout_ref (not a reference)
      request2 = %{
        id: 2222,
        method: "public/get_time",
        params: %{},
        sent_at: DateTime.utc_now(),
        options: nil,
        timeout_ref: "not_a_reference"
      }

      state = %{requests: %{1111 => request1, 2222 => request2}}

      # This should not raise any errors
      updated_state1 = DeribitRPC.remove_tracked_request(state, 1111)
      updated_state2 = DeribitRPC.remove_tracked_request(updated_state1, 2222)

      assert map_size(updated_state2.requests) == 0
    end
  end

  describe "error/2" do
    test "creates standardized error structure" do
      {:error, error} = DeribitRPC.error(:connection_failed)

      assert error.reason == :connection_failed
      assert error.details == nil
    end

    test "includes details when provided" do
      details = %{message: "Connection timeout"}
      {:error, error} = DeribitRPC.error(:connection_failed, details)

      assert error.reason == :connection_failed
      assert error.details == details
    end
  end

  describe "extract_metadata/1" do
    test "extracts metadata from subscription notifications" do
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "subscription",
        "params" => %{
          "channel" => "trades.BTC-PERPETUAL.raw",
          "data" => [%{"price" => 50_000}]
        }
      }

      metadata = DeribitRPC.extract_metadata(notification)

      assert metadata.channel == "trades.BTC-PERPETUAL.raw"
      assert metadata.type == :subscription
    end

    test "extracts timing information from responses" do
      response = %{
        "jsonrpc" => "2.0",
        "id" => 123,
        "result" => "success",
        # Microseconds timestamp for request received
        "usIn" => 1_609_459_200_000_000,
        # Microseconds timestamp for response sent
        "usOut" => 1_609_459_200_050_000
      }

      metadata = DeribitRPC.extract_metadata(response)

      assert metadata.timing.user_in == 1_609_459_200_000_000
      assert metadata.timing.user_out == 1_609_459_200_050_000
      # 50ms in microseconds
      assert metadata.timing.processing_time == 50_000
    end

    test "returns empty map for responses without metadata" do
      response = %{
        "jsonrpc" => "2.0",
        "id" => 123,
        "result" => "success"
      }

      metadata = DeribitRPC.extract_metadata(response)

      assert metadata == %{}
    end
  end

  describe "microseconds_to_datetime/1" do
    test "converts microsecond timestamps to DateTime" do
      # 2021-01-01 00:00:00 UTC in microseconds
      timestamp_us = 1_609_459_200_000_000

      datetime = DeribitRPC.microseconds_to_datetime(timestamp_us)

      assert datetime.year == 2021
      assert datetime.month == 1
      assert datetime.day == 1
      assert datetime.hour == 0
      assert datetime.minute == 0
      assert datetime.second == 0
      assert datetime.microsecond == {0, 6}
      assert datetime.time_zone == "Etc/UTC"
    end

    test "handles microsecond precision correctly" do
      # 2021-01-01 00:00:00.123456 UTC in microseconds
      timestamp_us = 1_609_459_200_123_456

      datetime = DeribitRPC.microseconds_to_datetime(timestamp_us)

      assert datetime.year == 2021
      assert datetime.month == 1
      assert datetime.day == 1
      assert datetime.hour == 0
      assert datetime.minute == 0
      assert datetime.second == 0
      assert datetime.microsecond == {123_456, 6}
    end
  end

  describe "get_timeout/3" do
    test "returns default timeout from state" do
      state = %{request_timeout: 12_000}
      method = "some/unknown/method"

      timeout = DeribitRPC.get_timeout(method, nil, state)

      assert timeout == 12_000
    end

    test "uses method-specific timeouts" do
      state = %{request_timeout: 10_000}

      assert DeribitRPC.get_timeout("public/auth", nil, state) == 30_000
      assert DeribitRPC.get_timeout("private/logout", nil, state) == 5000
      assert DeribitRPC.get_timeout("public/test", nil, state) == 2000
      assert DeribitRPC.get_timeout("public/get_time", nil, state) == 5000
    end

    test "uses timeout from options when provided" do
      state = %{request_timeout: 10_000}
      options = %{timeout: 3000}

      # Even with method-specific timeout, options should override
      assert DeribitRPC.get_timeout("public/auth", options, state) == 3000
    end

    test "uses default 10000ms when state has no request_timeout" do
      state = %{}

      assert DeribitRPC.get_timeout("some/unknown/method", nil, state) == 10_000
    end
  end

  describe "generate_timeout_reference/1" do
    test "returns a reference that will trigger a timeout message" do
      request_id = 12_345

      ref = DeribitRPC.generate_timeout_reference(request_id)

      assert is_reference(ref)

      # Clean up by canceling the timer
      Process.cancel_timer(ref)
    end
  end
end
