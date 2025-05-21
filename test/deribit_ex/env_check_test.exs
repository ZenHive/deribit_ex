defmodule MarketMaker.WS.EnvCheckTest do
  use ExUnit.Case

  test "check environment variables directly" do
    # Get environment variables in this process
    client_id = System.get_env("DERIBIT_CLIENT_ID")
    client_secret = System.get_env("DERIBIT_CLIENT_SECRET")
    host = System.get_env("DERIBIT_HOST")

    IO.puts("\nDirect Environment Check:")
    IO.puts("Process PID: #{inspect(self())}")
    IO.puts("DERIBIT_CLIENT_ID value: #{inspect(client_id)}")

    IO.puts(
      "DERIBIT_CLIENT_ID type: #{inspect((client_id && ((is_binary(client_id) && "string") || typeof(client_id))) || "nil")}"
    )

    IO.puts("DERIBIT_CLIENT_SECRET length: #{inspect((client_secret && String.length(client_secret)) || 0)}")
    IO.puts("DERIBIT_HOST: #{inspect(host)}")

    # Try getting from Application env
    config_entry = Application.get_env(:market_maker, :websocket, [])
    IO.puts("Application.get_env(:market_maker, :websocket): #{inspect(config_entry)}")

    # This assertion just prevents the test from failing
    assert true
  end

  defp typeof(term) do
    cond do
      is_binary(term) -> "string"
      is_integer(term) -> "integer"
      is_float(term) -> "float"
      is_boolean(term) -> "boolean"
      is_atom(term) -> "atom"
      is_list(term) -> "list"
      is_map(term) -> "map"
      is_tuple(term) -> "tuple"
      is_function(term) -> "function"
      is_pid(term) -> "pid"
      is_reference(term) -> "reference"
      is_port(term) -> "port"
      true -> "unknown"
    end
  end
end
