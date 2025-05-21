defmodule DeribitEx.DeribitRPCParseResponseTest do
  use ExUnit.Case

  alias DeribitEx.DeribitRPC

  describe "parse_response/1" do
    test "returns {:ok, result} when result field present" do
      resp = %{"jsonrpc" => "2.0", "id" => 1, "result" => "success"}
      assert DeribitRPC.parse_response(resp) == {:ok, "success"}
    end

    test "returns {:ok, result} with complex result data structure" do
      result = %{
        "timestamp" => 1_609_459_200_000,
        "server_time" => 1_609_459_200_000
      }

      resp = %{"jsonrpc" => "2.0", "id" => 2, "result" => result}
      assert DeribitRPC.parse_response(resp) == {:ok, result}
    end

    test "returns {:error, error_map} when error field present" do
      error = %{"code" => 10_001, "message" => "Invalid parameter"}
      resp = %{"jsonrpc" => "2.0", "id" => 3, "error" => error}
      assert DeribitRPC.parse_response(resp) == {:error, error}
    end

    test "returns {:error, {:invalid_response, _}} on unexpected structures" do
      # Empty map
      assert match?({:error, {:invalid_response, %{}}}, DeribitRPC.parse_response(%{}))

      # Map with irrelevant keys
      bad_resp = %{"foo" => "bar", "baz" => 123}
      assert match?({:error, {:invalid_response, ^bad_resp}}, DeribitRPC.parse_response(bad_resp))

      # Nil response
      assert match?({:error, {:invalid_response, nil}}, DeribitRPC.parse_response(nil))
    end
  end

  describe "classify_error/1" do
    test "classifies auth errors correctly" do
      error = %{"code" => 13_010, "message" => "Token expired"}
      assert DeribitRPC.classify_error(error) == {:auth, :token_expired, "Token expired"}

      error = %{"code" => 13_004, "message" => "Custom message"}
      assert DeribitRPC.classify_error(error) == {:auth, :not_authorized, "Custom message"}
    end

    test "classifies rate limit errors correctly" do
      error = %{"code" => 10_429, "message" => "Too many requests"}

      assert DeribitRPC.classify_error(error) ==
               {:rate_limit, :too_many_requests, "Too many requests"}
    end

    test "classifies validation errors correctly" do
      error = %{"code" => 10_001, "message" => "Invalid params"}
      assert DeribitRPC.classify_error(error) == {:validation, :invalid_params, "Invalid params"}
    end

    test "classifies order errors correctly" do
      error = %{"code" => 10_009, "message" => "Not enough funds"}
      assert DeribitRPC.classify_error(error) == {:order, :insufficient_funds, "Not enough funds"}
    end

    test "returns unknown classification for unknown error codes" do
      error = %{"code" => 99_999, "message" => "Unknown error"}
      assert DeribitRPC.classify_error(error) == {:unknown, :unknown_code, "Unknown error"}
    end

    test "handles invalid error format" do
      assert DeribitRPC.classify_error(%{}) ==
               {:unknown, :invalid_error_format, "Invalid error format"}

      assert DeribitRPC.classify_error(nil) ==
               {:unknown, :invalid_error_format, "Invalid error format"}
    end
  end

  describe "needs_reauth?/1" do
    test "returns true for authentication errors" do
      assert DeribitRPC.needs_reauth?(%{"code" => 13_004}) == true
      assert DeribitRPC.needs_reauth?(%{"code" => 13_009}) == true
      assert DeribitRPC.needs_reauth?(%{"code" => 13_010}) == true
      assert DeribitRPC.needs_reauth?(%{"code" => 13_011}) == true
    end

    test "returns false for non-authentication errors" do
      assert DeribitRPC.needs_reauth?(%{"code" => 10_001}) == false
      assert DeribitRPC.needs_reauth?(%{"code" => 10_429}) == false
      assert DeribitRPC.needs_reauth?(%{"code" => 11_003}) == false
      assert DeribitRPC.needs_reauth?(%{"code" => 99_999}) == false
    end

    test "returns false for invalid error format" do
      assert DeribitRPC.needs_reauth?(%{}) == false
      assert DeribitRPC.needs_reauth?(nil) == false
    end
  end

  describe "extract_metadata/1" do
    test "extracts subscription channel metadata" do
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "subscription",
        "params" => %{
          "channel" => "trades.BTC-PERPETUAL.raw",
          "data" => [%{"price" => 50_000}]
        }
      }

      expected = %{channel: "trades.BTC-PERPETUAL.raw", type: :subscription}
      assert DeribitRPC.extract_metadata(notification) == expected
    end

    test "extracts timing information from responses" do
      response = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => "success",
        "usIn" => 1_609_459_200_000_000,
        "usOut" => 1_609_459_200_001_000
      }

      metadata = DeribitRPC.extract_metadata(response)
      assert metadata.timing.user_in == 1_609_459_200_000_000
      assert metadata.timing.user_out == 1_609_459_200_001_000
      assert metadata.timing.processing_time == 1000
    end

    test "returns empty map for responses with no metadata" do
      response = %{"jsonrpc" => "2.0", "id" => 1, "result" => "success"}
      assert DeribitRPC.extract_metadata(response) == %{}
    end
  end
end
