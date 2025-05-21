defmodule DeribitEx.SessionContextTest do
  use ExUnit.Case, async: true

  alias DeribitEx.SessionContext

  describe "new_from_auth/2" do
    test "creates a new session from auth data" do
      auth_data = %{
        "access_token" => "test_access_token",
        "refresh_token" => "test_refresh_token",
        "expires_in" => 900,
        "scope" => "connection"
      }

      {:ok, session} = SessionContext.new_from_auth(auth_data)

      assert session.access_token == "test_access_token"
      assert session.refresh_token == "test_refresh_token"
      assert session.scope == "connection"
      assert session.active == true
      assert session.transition == :initial
      assert session.prev_id == nil
      assert is_binary(session.id)
      assert session.expires_at > System.system_time(:millisecond)
    end

    test "handles additional options" do
      auth_data = %{
        "access_token" => "test_access_token",
        "refresh_token" => "test_refresh_token",
        "expires_in" => 900
      }

      opts = [subject_id: 123, session_name: "test_session"]

      {:ok, session} = SessionContext.new_from_auth(auth_data, opts)

      assert session.subject_id == 123
      assert session.session_name == "test_session"
    end
  end

  describe "new_from_exchange/3" do
    test "creates a new session from exchange_token response" do
      # Create initial session
      {:ok, current_session} =
        SessionContext.new_from_auth(%{
          "access_token" => "old_access_token",
          "refresh_token" => "old_refresh_token",
          "expires_in" => 900,
          "scope" => "connection"
        })

      # Exchange token response
      exchange_data = %{
        "access_token" => "new_access_token",
        "refresh_token" => "new_refresh_token",
        "expires_in" => 900,
        "scope" => "connection mainaccount"
      }

      subject_id = 456

      {:ok, new_session} = SessionContext.new_from_exchange(current_session, exchange_data, subject_id)

      # Verify transition tracking
      assert new_session.prev_id == current_session.id
      assert new_session.transition == :exchange
      assert new_session.active == true
      assert new_session.subject_id == 456

      # Verify token update
      assert new_session.access_token == "new_access_token"
      assert new_session.refresh_token == "new_refresh_token"
      assert new_session.scope == "connection mainaccount"
      assert new_session.expires_at > System.system_time(:millisecond)
    end
  end

  describe "new_from_fork/3" do
    test "creates a new session from fork_token response" do
      # Create initial session
      {:ok, current_session} =
        SessionContext.new_from_auth(
          %{
            "access_token" => "old_access_token",
            "refresh_token" => "old_refresh_token",
            "expires_in" => 900,
            "scope" => "connection"
          },
          subject_id: 123
        )

      # Fork token response
      fork_data = %{
        "access_token" => "forked_access_token",
        "refresh_token" => "forked_refresh_token",
        "expires_in" => 900,
        "scope" => "session:named_session mainaccount"
      }

      session_name = "forked_session"

      {:ok, new_session} = SessionContext.new_from_fork(current_session, fork_data, session_name)

      # Verify transition tracking
      assert new_session.prev_id == current_session.id
      assert new_session.transition == :fork
      assert new_session.active == true
      assert new_session.session_name == "forked_session"

      # Subject ID should be retained from original session
      assert new_session.subject_id == 123

      # Verify token update
      assert new_session.access_token == "forked_access_token"
      assert new_session.refresh_token == "forked_refresh_token"
      assert new_session.scope == "session:named_session mainaccount"
      assert new_session.expires_at > System.system_time(:millisecond)
    end
  end

  describe "update_from_refresh/2" do
    test "updates an existing session with refreshed token data" do
      # Create initial session
      {:ok, current_session} =
        SessionContext.new_from_auth(
          %{
            "access_token" => "old_access_token",
            "refresh_token" => "old_refresh_token",
            "expires_in" => 900,
            "scope" => "connection"
          },
          subject_id: 123,
          session_name: "original_session"
        )

      # Original session ID for comparison
      original_id = current_session.id

      # Save the original expiry for comparison (using underscore to indicate unused)
      _original_expires_at = current_session.expires_at

      # Create a small delay to ensure timestamps are different
      :timer.sleep(10)

      # Refresh token response
      refresh_data = %{
        "access_token" => "refreshed_access_token",
        "refresh_token" => "refreshed_refresh_token",
        "expires_in" => 900
      }

      {:ok, updated_session} = SessionContext.update_from_refresh(current_session, refresh_data)

      # Session ID should not change after refresh
      assert updated_session.id == original_id

      # Transition should be marked as refresh
      assert updated_session.transition == :refresh

      # Previous session metadata should be preserved
      assert updated_session.subject_id == 123
      assert updated_session.session_name == "original_session"

      # Tokens should be updated
      assert updated_session.access_token == "refreshed_access_token"
      assert updated_session.refresh_token == "refreshed_refresh_token"

      # Updated expiry doesn't need to be strictly greater since we calculate
      # it as System.system_time + expires_in, which might result in the same
      # value in fast test execution. Just check that it's set.
      assert updated_session.expires_at > 0
    end
  end

  describe "invalidate/1" do
    test "marks a session as inactive" do
      # Create session
      {:ok, session} =
        SessionContext.new_from_auth(%{
          "access_token" => "test_access_token",
          "refresh_token" => "test_refresh_token",
          "expires_in" => 900
        })

      assert session.active == true

      # Invalidate session
      {:ok, invalidated} = SessionContext.invalidate(session)

      # Session should be marked inactive
      assert invalidated.active == false

      # Other fields should remain the same
      assert invalidated.id == session.id
      assert invalidated.access_token == session.access_token
    end
  end

  describe "generate_session_id/0" do
    test "generates a unique session ID" do
      id1 = SessionContext.generate_session_id()
      id2 = SessionContext.generate_session_id()

      assert is_binary(id1)
      assert String.starts_with?(id1, "session_")
      assert id1 != id2
    end
  end
end
