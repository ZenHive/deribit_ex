defmodule DeribitEx.RPCBatchTest do
  @moduledoc """
  Note: These tests are skipped because batch request functionality 
  has been removed from the codebase as Deribit API does not support 
  batch requests per their documentation.
  """

  use ExUnit.Case, async: true

  alias DeribitEx.RPC

  @moduletag :skip

  test "batch request functionality removed" do
    # Verify that batch request functionality has been removed
    refute function_exported?(RPC, :generate_batch_request, 1)
    refute function_exported?(RPC, :parse_batch_response, 1)
    refute function_exported?(RPC, :parse_batch_response, 2)
    refute function_exported?(RPC, :track_batch_request, 3)
    refute function_exported?(RPC, :track_batch_request, 4)
  end
end
