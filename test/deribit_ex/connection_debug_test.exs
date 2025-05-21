# defmodule DeribitEx.ConnectionDebugTest do
#   use ExUnit.Case

#   test "debug connection error" do
#     result = DeribitEx.Client.connect(%{callback_pid: self()})
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
