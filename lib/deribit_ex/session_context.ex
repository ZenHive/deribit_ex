defmodule DeribitEx.SessionContext do
  @moduledoc """
  Manages session context and order state preservation during Deribit token operations.

  This module tracks the state of sessions across token changes and provides 
  functionality for preserving order state during session transitions. It handles:

  - Session tracking during token exchange (switching subaccounts)
  - Session tracking during token forking (creating named sessions)
  - Order state preservation across session transitions
  - Automatic channel resubscription after token changes

  Integrates with both token management and order management to ensure
  continuity of operations during authentication changes.
  """

  require Logger

  @typedoc """
  The session transition type:
  - `:exchange` - Token exchange for switching subaccounts
  - `:fork` - Token fork for creating named sessions
  - `:refresh` - Normal token refresh within same session
  - `:initial` - Initial session creation
  """
  @type transition_type :: :exchange | :fork | :refresh | :initial

  @typedoc """
  Represents a Deribit session with tracking information.

  - `id`: Unique ID for this session
  - `prev_id`: ID of the previous session (for tracking transitions)
  - `created_at`: When this session was created
  - `access_token`: Current access token for this session
  - `refresh_token`: Current refresh token for this session
  - `expires_at`: When the current token will expire
  - `transition`: How this session was created
  - `subject_id`: Account ID for this session (from exchange_token)
  - `session_name`: Session name (from fork_token)
  - `scope`: Authentication permissions for this session
  - `active`: Whether this session is currently active
  """
  @type t :: %__MODULE__{
          id: String.t(),
          prev_id: String.t() | nil,
          created_at: integer,
          access_token: String.t(),
          refresh_token: String.t(),
          expires_at: integer,
          transition: transition_type,
          subject_id: integer | nil,
          session_name: String.t() | nil,
          scope: String.t() | nil,
          active: boolean
        }

  defstruct [
    :id,
    :prev_id,
    :created_at,
    :access_token,
    :refresh_token,
    :expires_at,
    :transition,
    :subject_id,
    :session_name,
    :scope,
    :active
  ]

  @doc """
  Creates a new SessionContext from authentication response data.

  Used when first authenticating to create the initial session context.

  ## Parameters
  - `auth_data` - Authentication response from Deribit containing access_token, etc.
  - `opts` - Additional options for session creation

  ## Returns
  - `{:ok, session}` - A new session context
  """
  @spec new_from_auth(map(), keyword()) :: {:ok, t()}
  def new_from_auth(auth_data, opts \\ []) do
    now = System.system_time(:millisecond)

    session = %__MODULE__{
      id: generate_session_id(),
      prev_id: nil,
      created_at: now,
      access_token: Map.get(auth_data, "access_token"),
      refresh_token: Map.get(auth_data, "refresh_token"),
      expires_at: now + Map.get(auth_data, "expires_in", 900) * 1000,
      transition: :initial,
      subject_id: Keyword.get(opts, :subject_id),
      session_name: Keyword.get(opts, :session_name),
      scope: Map.get(auth_data, "scope"),
      active: true
    }

    # Emit telemetry for session creation
    :telemetry.execute(
      [:deribit_ex, :session, :created],
      %{timestamp: now},
      %{
        session_id: session.id,
        transition: :initial,
        subject_id: session.subject_id,
        session_name: session.session_name
      }
    )

    {:ok, session}
  end

  @doc """
  Creates a new SessionContext from a token exchange response.

  Used when switching between subaccounts to track the session transition.

  ## Parameters
  - `current_session` - The current active session
  - `exchange_data` - Response from exchange_token operation
  - `subject_id` - The ID of the subaccount being switched to

  ## Returns
  - `{:ok, session}` - A new session context with transition tracking
  """
  @spec new_from_exchange(t(), map(), integer()) :: {:ok, t()}
  def new_from_exchange(current_session, exchange_data, subject_id) do
    now = System.system_time(:millisecond)

    new_session = %__MODULE__{
      id: generate_session_id(),
      prev_id: current_session.id,
      created_at: now,
      access_token: Map.get(exchange_data, "access_token"),
      refresh_token: Map.get(exchange_data, "refresh_token"),
      expires_at: now + Map.get(exchange_data, "expires_in", 900) * 1000,
      transition: :exchange,
      subject_id: subject_id,
      session_name: current_session.session_name,
      scope: Map.get(exchange_data, "scope"),
      active: true
    }

    # Mark the previous session as inactive
    inactive_session = %{current_session | active: false}

    # Emit telemetry for session transition
    :telemetry.execute(
      [:deribit_ex, :session, :transitioned],
      %{timestamp: now},
      %{
        previous_session_id: inactive_session.id,
        new_session_id: new_session.id,
        transition: :exchange,
        subject_id: subject_id
      }
    )

    {:ok, new_session}
  end

  @doc """
  Creates a new SessionContext from a token fork response.

  Used when creating a named session to track the session transition.

  ## Parameters
  - `current_session` - The current active session
  - `fork_data` - Response from fork_token operation
  - `session_name` - The name of the new session being created

  ## Returns
  - `{:ok, session}` - A new session context with transition tracking
  """
  @spec new_from_fork(t(), map(), String.t()) :: {:ok, t()}
  def new_from_fork(current_session, fork_data, session_name) do
    now = System.system_time(:millisecond)

    new_session = %__MODULE__{
      id: generate_session_id(),
      prev_id: current_session.id,
      created_at: now,
      access_token: Map.get(fork_data, "access_token"),
      refresh_token: Map.get(fork_data, "refresh_token"),
      expires_at: now + Map.get(fork_data, "expires_in", 900) * 1000,
      transition: :fork,
      subject_id: current_session.subject_id,
      session_name: session_name,
      scope: Map.get(fork_data, "scope"),
      active: true
    }

    # Mark the previous session as inactive
    inactive_session = %{current_session | active: false}

    # Emit telemetry for session transition
    :telemetry.execute(
      [:deribit_ex, :session, :transitioned],
      %{timestamp: now},
      %{
        previous_session_id: inactive_session.id,
        new_session_id: new_session.id,
        transition: :fork,
        session_name: session_name
      }
    )

    {:ok, new_session}
  end

  @doc """
  Updates an existing SessionContext with refreshed token data.

  Used during normal token refresh operations to maintain session continuity.

  ## Parameters
  - `current_session` - The current active session
  - `refresh_data` - Response from token refresh operation

  ## Returns
  - `{:ok, session}` - Updated session context with new token information
  """
  @spec update_from_refresh(t(), map()) :: {:ok, t()}
  def update_from_refresh(current_session, refresh_data) do
    now = System.system_time(:millisecond)

    updated_session = %{
      current_session
      | access_token: Map.get(refresh_data, "access_token"),
        refresh_token: Map.get(refresh_data, "refresh_token"),
        expires_at: now + Map.get(refresh_data, "expires_in", 900) * 1000,
        transition: :refresh
    }

    # Emit telemetry for token refresh
    :telemetry.execute(
      [:deribit_ex, :session, :refreshed],
      %{timestamp: now},
      %{
        session_id: updated_session.id
      }
    )

    {:ok, updated_session}
  end

  @doc """
  Invalidates a session during logout operations.

  ## Parameters
  - `current_session` - The session to invalidate

  ## Returns
  - `{:ok, session}` - Invalidated session
  """
  @spec invalidate(t()) :: {:ok, t()}
  def invalidate(current_session) do
    now = System.system_time(:millisecond)

    invalidated_session = %{current_session | active: false}

    # Emit telemetry for session invalidation
    :telemetry.execute(
      [:deribit_ex, :session, :invalidated],
      %{timestamp: now},
      %{
        session_id: invalidated_session.id
      }
    )

    {:ok, invalidated_session}
  end

  @doc """
  Generates a unique session ID.

  Uses a combination of timestamp and random bytes for uniqueness.
  """
  @spec generate_session_id() :: String.t()
  def generate_session_id do
    random_bytes = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    timestamp = System.system_time(:millisecond)
    "session_#{timestamp}_#{random_bytes}"
  end
end
