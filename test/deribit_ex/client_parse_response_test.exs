defmodule DeribitEx.ClientParseResponseTest do
  use ExUnit.Case

  alias DeribitEx.Client

  describe "parse_response/1" do
    test "delegates to RPC.parse_response/1 for successful responses" do
      resp = %{"jsonrpc" => "2.0", "id" => 1, "result" => 42}
      assert Client.parse_response(resp) == {:ok, 42}
    end

    test "delegates to RPC.parse_response/1 for error responses" do
      error = %{"code" => 10_001, "message" => "Invalid parameter"}
      resp = %{"jsonrpc" => "2.0", "id" => 2, "error" => error}
      assert Client.parse_response(resp) == {:error, error}
    end

    test "delegates to RPC.parse_response/1 for invalid responses" do
      invalid_resp = %{"foo" => "bar"}
      assert match?({:error, {:invalid_response, _}}, Client.parse_response(invalid_resp))
    end
  end
end
