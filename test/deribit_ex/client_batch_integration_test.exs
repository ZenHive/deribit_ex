defmodule DeribitEx.ClientBatchIntegrationTest do
  @moduledoc """
  Note: These tests are skipped because batch request functionality
  has been removed from the codebase as Deribit API does not support
  batch requests per their documentation.
  """

  use ExUnit.Case

  alias DeribitEx.Client

  @moduletag :integration
  @moduletag :skip

  test "batch request functionality removed" do
    # Verify that batch request functionality has been removed
    refute function_exported?(Client, :batch_json_rpc, 2)
    refute function_exported?(Client, :batch_json_rpc, 3)
    refute function_exported?(Client, :batch, 2)
    refute function_exported?(Client, :batch, 3)
  end

  test "individual request functions still exist" do
    # Verify that individual request functionality still exists
    assert function_exported?(Client, :get_time, 1)
    assert function_exported?(Client, :get_time, 2)
    assert function_exported?(Client, :test, 2)
    assert function_exported?(Client, :test, 3)
    assert function_exported?(Client, :status, 1)
    assert function_exported?(Client, :status, 2)
  end
end
