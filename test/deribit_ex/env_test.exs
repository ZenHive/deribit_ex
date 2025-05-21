defmodule EnvTest do
  use ExUnit.Case

  test "credentials are correctly loaded for tests" do
    IO.puts("\n=== ENVIRONMENT VARIABLE TEST ===")

    # Test System.get_env directly
    client_id_env = System.get_env("DERIBIT_CLIENT_ID")
    client_secret_env = System.get_env("DERIBIT_CLIENT_SECRET")

    IO.puts("Direct check: DERIBIT_CLIENT_ID = #{inspect(client_id_env)}")

    IO.puts("Direct check: DERIBIT_CLIENT_SECRET = #{if client_secret_env, do: "[SET]", else: "nil"}")

    # Print environment and application config values
    IO.puts("\nEnvironment variables:")
    IO.puts("DERIBIT_CLIENT_ID: #{inspect(System.get_env("DERIBIT_CLIENT_ID"))}")

    IO.puts("DERIBIT_CLIENT_SECRET: #{if System.get_env("DERIBIT_CLIENT_SECRET"), do: "[SET]", else: "nil"}")

    IO.puts("DERIBIT_HOST: #{inspect(System.get_env("DERIBIT_HOST"))}")

    IO.puts("DERIBIT_AUTH_REFRESH_THRESHOLD: #{inspect(System.get_env("DERIBIT_AUTH_REFRESH_THRESHOLD"))}")

    IO.puts("DERIBIT_RATE_LIMIT_MODE: #{inspect(System.get_env("DERIBIT_RATE_LIMIT_MODE"))}")

    IO.puts("Application.get_env(:deribit_ex, :env): #{inspect(Application.get_env(:deribit_ex, :env))}")

    IO.puts("\nDirect Environment Check:")
    IO.puts("Process PID: #{inspect(self())}")

    # Check values directly
    deribit_client_id = System.get_env("DERIBIT_CLIENT_ID")
    IO.puts("DERIBIT_CLIENT_ID value: #{inspect(deribit_client_id)}")
    IO.puts("DERIBIT_CLIENT_ID type: #{inspect(typeof(deribit_client_id))}")

    deribit_client_secret = System.get_env("DERIBIT_CLIENT_SECRET") || ""
    IO.puts("DERIBIT_CLIENT_SECRET length: #{String.length(deribit_client_secret)}")

    IO.puts("DERIBIT_HOST: #{inspect(System.get_env("DERIBIT_HOST"))}")

    # Check application config
    websocket_config = Application.get_env(:deribit_ex, :websocket, [])
    IO.puts("Application.get_env(:deribit_ex, :websocket): #{inspect(websocket_config)}")

    # The real test is that credentials are in the application config
    assert is_binary(Keyword.get(websocket_config, :client_id)),
           "client_id not found in application config"

    assert is_binary(Keyword.get(websocket_config, :client_secret)),
           "client_secret not found in application config"
  end

  # Helper function to get type as string
  defp typeof(term) do
    cond do
      is_nil(term) -> "nil"
      is_binary(term) -> "binary (#{String.length(term)} chars)"
      is_boolean(term) -> "boolean"
      is_number(term) -> "number"
      is_atom(term) -> "atom"
      is_list(term) -> "list (#{length(term)} items)"
      is_tuple(term) -> "tuple"
      is_map(term) -> "map"
      is_pid(term) -> "pid"
      is_function(term) -> "function"
      is_reference(term) -> "reference"
      true -> "unknown"
    end
  end
end
