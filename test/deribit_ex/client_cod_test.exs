defmodule DeribitEx.DeribitClientCODTest do
  @moduledoc """
  Unit tests for the validation logic in DeribitClient without requiring
  actual connections. We will use the integration tests to test the actual
  API interactions.
  """

  use ExUnit.Case, async: true

  alias DeribitEx.DeribitClient

  @moduletag :unit
  @moduletag :cod

  describe "enable_cancel_on_disconnect/3" do
    test "validates scope parameter" do
      # Mock conn that won't be used
      fake_conn = self()

      assert_raise RuntimeError, ~r/Invalid scope/, fn ->
        DeribitClient.enable_cancel_on_disconnect(fake_conn, "invalid_scope")
      end
    end
  end

  describe "disable_cancel_on_disconnect/3" do
    test "validates scope parameter" do
      # Mock conn that won't be used
      fake_conn = self()

      assert_raise RuntimeError, ~r/Invalid scope/, fn ->
        DeribitClient.disable_cancel_on_disconnect(fake_conn, "invalid_scope")
      end
    end
  end
end
