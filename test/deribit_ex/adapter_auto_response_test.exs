defmodule DeribitEx.AdapterAutoResponseTest do
  use ExUnit.Case

  alias DeribitEx.Adapter

  describe "handle_message/2 for test_request" do
    setup do
      {:ok, state} = Adapter.init(%{})
      %{state: state}
    end

    test "correctly responds to test_request messages", %{state: state} do
      # Simulate a test_request message from Deribit server
      test_request_message = %{
        "jsonrpc" => "2.0",
        "method" => "test_request",
        "params" => %{}
      }

      # The adapter should generate a public/test response
      {:reply, encoded_payload, state} =
        Adapter.handle_message(test_request_message, state)

      # Verify that a request for public/test was tracked in state
      # Find the request in the state requests map
      request =
        state.requests
        |> Map.values()
        |> Enum.find(fn req -> req.method == "public/test" end)

      assert request != nil
      assert request.method == "public/test"
      assert request.params == %{}

      # Verify the reply payload
      payload = Jason.decode!(encoded_payload)
      assert payload["jsonrpc"] == "2.0"
      assert payload["method"] == "public/test"
      assert Map.has_key?(payload, "id")
      assert is_integer(payload["id"])
    end

    test "correctly responds to test_request messages with parameters", %{state: state} do
      # Simulate a test_request message with params
      test_request_message = %{
        "jsonrpc" => "2.0",
        "method" => "test_request",
        "params" => %{"expected_result" => "hello"}
      }

      # The adapter should generate a public/test response with expected_result
      {:reply, encoded_payload, state} =
        Adapter.handle_message(test_request_message, state)

      # Verify that a request for public/test was tracked in state
      request =
        state.requests
        |> Map.values()
        |> Enum.find(fn req -> req.method == "public/test" end)

      assert request != nil
      assert request.method == "public/test"
      assert request.params == %{"expected_result" => "hello"}

      # Verify the reply payload
      payload = Jason.decode!(encoded_payload)
      assert payload["jsonrpc"] == "2.0"
      assert payload["method"] == "public/test"
      assert Map.has_key?(payload, "id")
      assert is_integer(payload["id"])
      assert payload["params"]["expected_result"] == "hello"
    end
  end
end
