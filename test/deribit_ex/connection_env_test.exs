# defmodule MarketMaker.WS.ConnectionEnvTest do
#   use ExUnit.Case

#   alias MarketMaker.WS.DeribitClient

#   test "debug environment" do
#     IO.puts("Environment:")
#     IO.puts("MIX_ENV: #{Mix.env()}")
#     IO.puts("DERIBIT_HOST: #{System.get_env("DERIBIT_HOST") || "not set"}")
#     IO.puts("DERIBIT_CLIENT_ID: #{System.get_env("DERIBIT_CLIENT_ID") || "not set"}")

#     # Safely print secret without revealing full value
#     secret = System.get_env("DERIBIT_CLIENT_SECRET")
#     redacted_secret = if secret, do: String.slice(secret, 0..3) <> "..." <> String.slice(secret, -4..-1), else: "not set"
#     IO.puts("DERIBIT_CLIENT_SECRET: #{redacted_secret}")

#     # Try to connect with explicit host
#     result1 =
#       DeribitClient.connect(%{
#         host: "test.deribit.com",
#         callback_pid: self()
#       })

#     IO.inspect(result1, label: "Connection Result with explicit host")

#     # Try with default options
#     result2 = DeribitClient.connect()
#     IO.inspect(result2, label: "Connection Result with defaults")

#     assert true
#   end
# end
