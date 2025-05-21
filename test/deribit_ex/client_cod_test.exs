defmodule DeribitEx.ClientCODTest do
  @moduledoc """
  Unit tests for the validation logic in Client without requiring
  actual connections. We will use the integration tests to test the actual
  API interactions.
  """

  use ExUnit.Case, async: true

  alias DeribitEx.Client

  @moduletag :unit
  @moduletag :cod

  describe "enable_cancel_on_disconnect/3" do
    test "validates scope parameter" do
      # Mock conn that won't be used
      fake_conn = self()

      assert_raise RuntimeError, ~r/Invalid scope/, fn ->
        Client.enable_cancel_on_disconnect(fake_conn, "invalid_scope")
      end
    end
  end

  describe "disable_cancel_on_disconnect/3" do
    test "validates scope parameter" do
      # Mock conn that won't be used
      fake_conn = self()

      assert_raise RuntimeError, ~r/Invalid scope/, fn ->
        Client.disable_cancel_on_disconnect(fake_conn, "invalid_scope")
      end
    end
  end
end
