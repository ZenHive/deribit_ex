defmodule DeribitEx.DirectWebsocketTest do
  use ExUnit.Case, async: false

  @moduletag :debug

  @tag :skip
  test "direct websocket connection with debug" do
    # Skip this test - it's trying to use private functions in WebsockexNova
    IO.puts("This test is skipped because it uses private functions in WebsockexNova")
    assert true
  end

  test "print environment variables for debugging" do
    # Print relevant environment variables to debug connection issues
    IO.puts("\nEnvironment variables:")
    IO.puts("DERIBIT_CLIENT_ID: #{inspect(System.get_env("DERIBIT_CLIENT_ID"))}")
    IO.puts("DERIBIT_CLIENT_SECRET: #{inspect(System.get_env("DERIBIT_CLIENT_SECRET"))}")
    IO.puts("DERIBIT_HOST: #{inspect(System.get_env("DERIBIT_HOST"))}")
    IO.puts("DERIBIT_AUTH_REFRESH_THRESHOLD: #{inspect(System.get_env("DERIBIT_AUTH_REFRESH_THRESHOLD"))}")
    IO.puts("DERIBIT_RATE_LIMIT_MODE: #{inspect(System.get_env("DERIBIT_RATE_LIMIT_MODE"))}")

    # Check if we can parse common Elixir environment values
    app_env = Application.get_env(:market_maker, :env, :not_defined)
    IO.puts("Application.get_env(:market_maker, :env): #{inspect(app_env)}")

    assert true
  end
end
