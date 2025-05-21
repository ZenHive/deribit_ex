defmodule DeribitEx.DeribitRPCRequestFormatTest do
  use ExUnit.Case

  alias DeribitEx.DeribitRPC

  describe "generate_request/2" do
    test "builds a JSON-RPC request for public/get_time" do
      {:ok, payload, id} = DeribitRPC.generate_request("public/get_time", %{})

      assert payload["jsonrpc"] == "2.0"
      assert payload["id"] == id
      assert payload["method"] == "public/get_time"
      assert payload["params"] == %{}
    end

    test "builds a JSON-RPC request with parameters" do
      params = %{"instrument_name" => "BTC-PERPETUAL"}
      {:ok, payload, id} = DeribitRPC.generate_request("public/ticker", params)

      assert payload["jsonrpc"] == "2.0"
      assert payload["id"] == id
      assert payload["method"] == "public/ticker"
      assert payload["params"] == params
    end

    test "merges default_params when provided" do
      # "public/hello" has defaults in @default_params
      {:ok, payload, _} = DeribitRPC.generate_request("public/hello", %{"foo" => "bar"})

      # Default params should be merged with provided params
      assert payload["params"]["client_name"] == "market_maker"
      assert payload["params"]["client_version"] == "1.0.0"
      assert payload["params"]["foo"] == "bar"
    end

    test "uses passed ID when provided" do
      custom_id = 12_345
      {:ok, payload, id} = DeribitRPC.generate_request("public/get_time", %{}, custom_id)

      assert payload["id"] == custom_id
      assert id == custom_id
    end
  end

  describe "method_type/1" do
    test "identifies public methods" do
      assert DeribitRPC.method_type("public/get_time") == :public
      assert DeribitRPC.method_type("public/ticker") == :public
      assert DeribitRPC.method_type("public/auth") == :public
    end

    test "identifies private methods" do
      assert DeribitRPC.method_type("private/get_position") == :private
      assert DeribitRPC.method_type("private/buy") == :private
      assert DeribitRPC.method_type("private/logout") == :private
    end

    test "marks non-standard methods as unknown" do
      assert DeribitRPC.method_type("get_time") == :unknown
      assert DeribitRPC.method_type("unknown/method") == :unknown
      assert DeribitRPC.method_type(nil) == :unknown
    end
  end

  describe "requires_auth?/1" do
    test "private methods require auth" do
      assert DeribitRPC.requires_auth?("private/get_position") == true
      assert DeribitRPC.requires_auth?("private/buy") == true
    end

    test "public methods don't require auth" do
      assert DeribitRPC.requires_auth?("public/get_time") == false
      assert DeribitRPC.requires_auth?("public/ticker") == false
    end
  end

  describe "add_auth_params/3" do
    test "adds access_token for private methods when token provided" do
      params = %{"instrument" => "BTC-PERPETUAL"}
      method = "private/get_position"
      token = "test_token"

      result = DeribitRPC.add_auth_params(params, method, token)
      assert result == Map.put(params, "access_token", token)
    end

    test "returns original params for public methods even with token" do
      params = %{"instrument" => "BTC-PERPETUAL"}
      method = "public/get_time"
      token = "test_token"

      result = DeribitRPC.add_auth_params(params, method, token)
      assert result == params
      refute Map.has_key?(result, "access_token")
    end

    test "returns original params for private methods when token is nil" do
      params = %{"instrument" => "BTC-PERPETUAL"}
      method = "private/get_position"
      token = nil

      result = DeribitRPC.add_auth_params(params, method, token)
      assert result == params
      refute Map.has_key?(result, "access_token")
    end
  end
end
