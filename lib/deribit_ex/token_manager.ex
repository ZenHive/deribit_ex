defmodule DeribitEx.TokenManager do
  @moduledoc """
  Integrates token management with order management.

  This module provides the central integration point for token operations and
  order management, handling session transitions, order state preservation,
  and resubscription. It coordinates:

  - Session tracking via SessionContext
  - Order state preservation via OrderContext
  - Channel resubscription via ResubscriptionHandler

  Designed to be used by Adapter to perform token operations while
  preserving application state.
  """

  alias DeribitEx.OrderContext
  alias DeribitEx.ResubscriptionHandler
  alias DeribitEx.SessionContext

  require Logger

  @typedoc """
  The complete token management state.

  - `session`: Current session context
  - `orders`: Order tracking context
  - `resubscription`: Channel resubscription handler
  """
  @type t :: %__MODULE__{
          session: SessionContext.t() | nil,
          orders: OrderContext.t(),
          resubscription: ResubscriptionHandler.t()
        }

  defstruct session: nil,
            orders: nil,
            resubscription: nil

  @doc """
  Creates a new TokenManager instance.

  ## Parameters
  - `opts`: Options for the token manager
    - `:max_retries` - Maximum resubscription retry attempts (default: 3)

  ## Returns
  - A new TokenManager instance
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      orders: OrderContext.new(),
      resubscription: ResubscriptionHandler.new(opts)
    }
  end

  @doc """
  Initializes the token manager from an authentication response.

  ## Parameters
  - `manager`: Current token manager state
  - `auth_data`: Authentication response from Deribit
  - `opts`: Additional options

  ## Returns
  - `{:ok, updated_manager}`: Updated token manager with session context
  """
  @spec init_from_auth(t(), map(), keyword()) :: {:ok, t()}
  def init_from_auth(manager, auth_data, opts \\ []) do
    {:ok, session} = SessionContext.new_from_auth(auth_data, opts)

    # No session transition on initial auth
    updated_manager = %{manager | session: session}

    # Emit telemetry for token manager initialization
    :telemetry.execute(
      [:deribit_ex, :token_manager, :initialized],
      %{timestamp: System.system_time(:millisecond)},
      %{
        session_id: session.id
      }
    )

    {:ok, updated_manager}
  end

  @doc """
  Handles a token exchange operation for switching subaccounts.

  ## Parameters
  - `manager`: Current token manager state
  - `exchange_data`: Response from exchange_token operation
  - `subject_id`: The ID of the subaccount being switched to

  ## Returns
  - `{:ok, updated_manager}`: Updated token manager with new session
  - `{:error, reason}`: If the operation fails
  """
  @spec handle_exchange_token(t(), map(), integer()) :: {:ok, t()} | {:error, any()}
  def handle_exchange_token(manager, exchange_data, subject_id) do
    if manager.session do
      # Create new session from exchange
      {:ok, new_session} =
        SessionContext.new_from_exchange(
          manager.session,
          exchange_data,
          subject_id
        )

      # Update order context with session transition
      {:ok, updated_orders} =
        OrderContext.handle_session_transition(
          manager.orders,
          manager.session,
          new_session
        )

      # Update resubscription handler with session transition
      {:ok, updated_resubscription} =
        ResubscriptionHandler.handle_session_transition(
          manager.resubscription,
          manager.session,
          new_session
        )

      # Create updated manager
      updated_manager = %{
        manager
        | session: new_session,
          orders: updated_orders,
          resubscription: updated_resubscription
      }

      # Emit telemetry for token exchange
      :telemetry.execute(
        [:deribit_ex, :token_manager, :exchange_token],
        %{timestamp: System.system_time(:millisecond)},
        %{
          previous_session_id: manager.session.id,
          new_session_id: new_session.id,
          subject_id: subject_id
        }
      )

      {:ok, updated_manager}
    else
      {:error, :no_active_session}
    end
  end

  @doc """
  Handles a token fork operation for creating a named session.

  ## Parameters
  - `manager`: Current token manager state
  - `fork_data`: Response from fork_token operation
  - `session_name`: The name of the new session being created

  ## Returns
  - `{:ok, updated_manager}`: Updated token manager with new session
  - `{:error, reason}`: If the operation fails
  """
  @spec handle_fork_token(t(), map(), String.t()) :: {:ok, t()} | {:error, any()}
  def handle_fork_token(manager, fork_data, session_name) do
    if manager.session do
      # Create new session from fork
      {:ok, new_session} =
        SessionContext.new_from_fork(
          manager.session,
          fork_data,
          session_name
        )

      # Update order context with session transition
      {:ok, updated_orders} =
        OrderContext.handle_session_transition(
          manager.orders,
          manager.session,
          new_session
        )

      # Update resubscription handler with session transition
      {:ok, updated_resubscription} =
        ResubscriptionHandler.handle_session_transition(
          manager.resubscription,
          manager.session,
          new_session
        )

      # Create updated manager
      updated_manager = %{
        manager
        | session: new_session,
          orders: updated_orders,
          resubscription: updated_resubscription
      }

      # Emit telemetry for token fork
      :telemetry.execute(
        [:deribit_ex, :token_manager, :fork_token],
        %{timestamp: System.system_time(:millisecond)},
        %{
          previous_session_id: manager.session.id,
          new_session_id: new_session.id,
          session_name: session_name
        }
      )

      {:ok, updated_manager}
    else
      {:error, :no_active_session}
    end
  end

  @doc """
  Handles a token refresh operation.

  ## Parameters
  - `manager`: Current token manager state
  - `refresh_data`: Response from token refresh operation

  ## Returns
  - `{:ok, updated_manager}`: Updated token manager with refreshed session
  - `{:error, reason}`: If the operation fails
  """
  @spec handle_token_refresh(t(), map()) :: {:ok, t()} | {:error, any()}
  def handle_token_refresh(manager, refresh_data) do
    if manager.session do
      # Update session with refreshed token data
      {:ok, updated_session} =
        SessionContext.update_from_refresh(
          manager.session,
          refresh_data
        )

      # Create updated manager
      updated_manager = %{manager | session: updated_session}

      # Emit telemetry for token refresh
      :telemetry.execute(
        [:deribit_ex, :token_manager, :token_refresh],
        %{timestamp: System.system_time(:millisecond)},
        %{
          session_id: updated_session.id
        }
      )

      {:ok, updated_manager}
    else
      {:error, :no_active_session}
    end
  end

  @doc """
  Handles logout and session invalidation.

  ## Parameters
  - `manager`: Current token manager state

  ## Returns
  - `{:ok, updated_manager}`: Updated token manager with invalidated session
  """
  @spec handle_logout(t()) :: {:ok, t()}
  def handle_logout(manager) do
    if manager.session do
      # Invalidate the session
      {:ok, invalidated_session} = SessionContext.invalidate(manager.session)

      # Create updated manager
      updated_manager = %{manager | session: invalidated_session}

      # Emit telemetry for logout
      :telemetry.execute(
        [:deribit_ex, :token_manager, :logout],
        %{timestamp: System.system_time(:millisecond)},
        %{
          session_id: invalidated_session.id
        }
      )

      {:ok, updated_manager}
    else
      # No active session to invalidate
      {:ok, manager}
    end
  end

  @doc """
  Registers a new subscription with the token manager.

  ## Parameters
  - `manager`: Current token manager state
  - `channel`: Channel name or topic
  - `params`: Subscription parameters

  ## Returns
  - `{:ok, updated_manager}`: Updated token manager with subscription registered
  - `{:error, reason}`: If the operation fails
  """
  @spec register_subscription(t(), String.t(), map()) :: {:ok, t()} | {:error, any()}
  def register_subscription(manager, channel, params) do
    if manager.session do
      # Register the subscription with the resubscription handler
      {:ok, updated_resubscription} =
        ResubscriptionHandler.register_subscription(
          manager.resubscription,
          channel,
          params,
          manager.session.id
        )

      # Create updated manager
      updated_manager = %{manager | resubscription: updated_resubscription}

      {:ok, updated_manager}
    else
      {:error, :no_active_session}
    end
  end

  @doc """
  Unregisters a subscription from the token manager.

  ## Parameters
  - `manager`: Current token manager state
  - `channel`: Channel to unregister

  ## Returns
  - `{:ok, updated_manager}`: Updated token manager with subscription removed
  """
  @spec unregister_subscription(t(), String.t()) :: {:ok, t()}
  def unregister_subscription(manager, channel) do
    # Unregister the subscription from the resubscription handler
    {:ok, updated_resubscription} =
      ResubscriptionHandler.unregister_subscription(
        manager.resubscription,
        channel
      )

    # Create updated manager
    updated_manager = %{manager | resubscription: updated_resubscription}

    {:ok, updated_manager}
  end

  @doc """
  Registers a new order with the token manager.

  ## Parameters
  - `manager`: Current token manager state
  - `order`: Order information

  ## Returns
  - `{:ok, updated_manager}`: Updated token manager with order registered
  - `{:error, reason}`: If the operation fails
  """
  @spec register_order(t(), map()) :: {:ok, t()} | {:error, any()}
  def register_order(manager, order) do
    if manager.session do
      # Register the order with the order context
      {:ok, updated_orders} =
        OrderContext.register_order(
          manager.orders,
          order,
          manager.session.id
        )

      # Create updated manager
      updated_manager = %{manager | orders: updated_orders}

      {:ok, updated_manager}
    else
      {:error, :no_active_session}
    end
  end

  @doc """
  Updates an existing order in the token manager.

  ## Parameters
  - `manager`: Current token manager state
  - `order`: Updated order information

  ## Returns
  - `{:ok, updated_manager}`: Updated token manager with order updated
  - `{:error, reason}`: If the operation fails
  """
  @spec update_order(t(), map()) :: {:ok, t()} | {:error, any()}
  def update_order(manager, order) do
    # Update the order in the order context
    case OrderContext.update_order(manager.orders, order) do
      {:ok, updated_orders} ->
        # Create updated manager
        updated_manager = %{manager | orders: updated_orders}
        {:ok, updated_manager}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Performs resubscription for all tracked channels.

  ## Parameters
  - `manager`: Current token manager state
  - `conn`: WebsockexNova client connection

  ## Returns
  - `{:ok, updated_manager, results}`: Updated manager and resubscription results
  - `{:error, reason, updated_manager}`: Error information if resubscription fails
  """
  @spec perform_resubscription(t(), pid()) ::
          {:ok, t(), map()}
          | {:error, any(), t()}
  def perform_resubscription(manager, conn) do
    # Perform resubscription using the resubscription handler
    case ResubscriptionHandler.perform_resubscription(manager.resubscription, conn) do
      {:ok, updated_resubscription, results} ->
        # Create updated manager
        updated_manager = %{manager | resubscription: updated_resubscription}
        {:ok, updated_manager, results}

      {:error, reason, updated_resubscription} ->
        # Create updated manager even on error
        updated_manager = %{manager | resubscription: updated_resubscription}
        {:error, reason, updated_manager}
    end
  end

  @doc """
  Gets the current session ID if available.

  ## Parameters
  - `manager`: Current token manager state

  ## Returns
  - `{:ok, session_id}`: The current session ID
  - `{:error, :no_active_session}`: If no active session exists
  """
  @spec get_session_id(t()) :: {:ok, String.t()} | {:error, :no_active_session}
  def get_session_id(manager) do
    if manager.session && manager.session.active do
      {:ok, manager.session.id}
    else
      {:error, :no_active_session}
    end
  end

  @doc """
  Gets all active orders for the current session.

  ## Parameters
  - `manager`: Current token manager state

  ## Returns
  - `{:ok, orders}`: List of active orders
  - `{:error, :no_active_session}`: If no active session exists
  """
  @spec get_active_orders(t()) ::
          {:ok, list(OrderContext.order_entry())} | {:error, :no_active_session}
  def get_active_orders(manager) do
    case get_session_id(manager) do
      {:ok, session_id} ->
        OrderContext.get_active_orders_for_session(manager.orders, session_id)

      {:error, _} = error ->
        error
    end
  end
end
