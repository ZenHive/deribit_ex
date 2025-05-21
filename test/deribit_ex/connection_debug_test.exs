# defmodule MarketMaker.WS.ConnectionDebugTest do
#   use ExUnit.Case

#   test "debug connection error" do
#     result = MarketMaker.WS.DeribitClient.connect(%{callback_pid: self()})
#     IO.inspect(result, label: "Connection Result")

#     case result do
#       {:error, error} ->
#         IO.inspect(error, label: "Error Details")

#       _ ->
#         :ok
#     end

#     assert true
#   end
# end
