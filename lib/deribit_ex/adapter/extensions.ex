defmodule DeribitEx.DeribitAdapterExtensions do
  @moduledoc """
  Extensions to the DeribitAdapter for integration with token management.

  This module contains the functions needed to modify DeribitAdapter 
  to integrate with the token management system without directly modifying
  the adapter itself.

  When MM0207 is fully integrated, these functions should be moved
  directly into the DeribitAdapter module.
  """

  alias DeribitEx.TokenManager

  require Logger

  @doc """
  Extends DeribitAdapter.init/1 to initialize the token manager.

  Call this function from DeribitAdapter.init/1 to add token manager to state.
  """
  @spec init_with_token_manager(map()) :: map()
  def init_with_token_manager(state) do
    # Create token manager instance
    token_manager = TokenManager.new()

    # Add to state
    Map.put(state, :token_manager, token_manager)
  end

  @doc """
  Extends DeribitAdapter.handle_auth_response/2 to integrate with token manager.

  Call this function from DeribitAdapter.handle_auth_response/2 after state updates.
  """
  @spec update_token_manager_from_auth(map(), map()) :: map()
  def update_token_manager_from_auth(response, state) do
    if Map.has_key?(state, :token_manager) do
      # Extract options from response and state
      result = response["result"]
      opts = []

      # Initialize token manager from auth response
      # Note: This function only returns {:ok, updated_token_manager}
      {:ok, updated_token_manager} =
        TokenManager.init_from_auth(state.token_manager, result, opts)

      # Update state with new token manager
      Map.put(state, :token_manager, updated_token_manager)
    else
      # Token manager not found in state
      state
    end
  end

  @doc """
  Extends DeribitAdapter.handle_exchange_token_response/2 to integrate with token manager.

  Call this function from DeribitAdapter.handle_exchange_token_response/2 after state updates.
  """
  @spec update_token_manager_from_exchange(map(), map(), map()) :: map()
  def update_token_manager_from_exchange(response, request, state) do
    if Map.has_key?(state, :token_manager) do
      # Extract subject_id from request
      subject_id = get_in(request, [:params, "subject_id"])

      if subject_id do
        # Update token manager from exchange token response
        case TokenManager.handle_exchange_token(
               state.token_manager,
               response["result"],
               subject_id
             ) do
          {:ok, updated_token_manager} ->
            # Update state with new token manager
            Map.put(state, :token_manager, updated_token_manager)

          {:error, reason} ->
            # Log error but continue with existing token manager
            Logger.error("Failed to update token manager from exchange: #{inspect(reason)}")
            state
        end
      else
        # subject_id not found in request
        Logger.warning("No subject_id found in exchange_token request")
        state
      end
    else
      # Token manager not found in state
      state
    end
  end

  @doc """
  Extends DeribitAdapter.handle_fork_token_response/2 to integrate with token manager.

  Call this function from DeribitAdapter.handle_fork_token_response/2 after state updates.
  """
  @spec update_token_manager_from_fork(map(), map(), map()) :: map()
  def update_token_manager_from_fork(response, request, state) do
    if Map.has_key?(state, :token_manager) do
      # Extract session_name from request
      session_name = get_in(request, [:params, "session_name"])

      if session_name do
        # Update token manager from fork token response
        case TokenManager.handle_fork_token(state.token_manager, response["result"], session_name) do
          {:ok, updated_token_manager} ->
            # Update state with new token manager
            Map.put(state, :token_manager, updated_token_manager)

          {:error, reason} ->
            # Log error but continue with existing token manager
            Logger.error("Failed to update token manager from fork: #{inspect(reason)}")
            state
        end
      else
        # session_name not found in request
        Logger.warning("No session_name found in fork_token request")
        state
      end
    else
      # Token manager not found in state
      state
    end
  end

  @doc """
  Extends DeribitAdapter.handle_logout_response/2 to integrate with token manager.

  Call this function from DeribitAdapter.handle_logout_response/2 after state updates.
  """
  @spec update_token_manager_from_logout(map()) :: map()
  def update_token_manager_from_logout(state) do
    if Map.has_key?(state, :token_manager) do
      # Update token manager for logout
      # Note: This function only returns {:ok, updated_token_manager}
      {:ok, updated_token_manager} = TokenManager.handle_logout(state.token_manager)
      # Update state with new token manager
      Map.put(state, :token_manager, updated_token_manager)
    else
      # Token manager not found in state
      state
    end
  end

  @doc """
  Registers a subscription with the token manager.

  Call this function from DeribitAdapter.handle_subscription_response/2 after state updates.
  """
  @spec register_subscription_with_token_manager(map(), String.t(), map(), map()) :: map()
  def register_subscription_with_token_manager(state, channel, params, _subscription_info) do
    if Map.has_key?(state, :token_manager) do
      # Register subscription with token manager
      case TokenManager.register_subscription(state.token_manager, channel, params) do
        {:ok, updated_token_manager} ->
          # Update state with new token manager
          Map.put(state, :token_manager, updated_token_manager)

        {:error, reason} ->
          # Log error but continue with existing token manager
          Logger.error("Failed to register subscription with token manager: #{inspect(reason)}")
          state
      end
    else
      # Token manager not found in state
      state
    end
  end

  @doc """
  Unregisters a subscription from the token manager.

  Call this function when unsubscribing from a channel.
  """
  @spec unregister_subscription_from_token_manager(map(), String.t()) :: map()
  def unregister_subscription_from_token_manager(state, channel) do
    if Map.has_key?(state, :token_manager) do
      # Unregister subscription from token manager
      # Note: This function only returns {:ok, updated_token_manager}
      {:ok, updated_token_manager} =
        TokenManager.unregister_subscription(state.token_manager, channel)

      # Update state with new token manager
      Map.put(state, :token_manager, updated_token_manager)
    else
      # Token manager not found in state
      state
    end
  end

  @doc """
  Handles resubscription after reconnection and authentication.

  Call this function after handling reconnection with authentication.
  """
  @spec handle_reconnect_authenticated(map()) :: {:ok, map()} | {:error, any(), map()}
  def handle_reconnect_authenticated(state) do
    if Map.get(state, :need_resubscribe, false) &&
         Map.has_key?(state, :token_manager) &&
         Map.has_key?(state, :client_conn) do
      client_conn = Map.get(state, :client_conn)

      # Perform resubscription using token manager
      case TokenManager.perform_resubscription(state.token_manager, client_conn) do
        {:ok, updated_token_manager, results} ->
          # Log successful resubscription
          Logger.info(
            "Successfully resubscribed to #{map_size(results)} channels after reconnect"
          )

          # Update state and clear need_resubscribe flag
          state =
            state
            |> Map.put(:token_manager, updated_token_manager)
            |> Map.put(:need_resubscribe, false)

          {:ok, state}

        {:error, reason, updated_token_manager} ->
          # Log resubscription failure
          Logger.error("Failed to resubscribe after reconnect: #{inspect(reason)}")

          # Update token manager but keep need_resubscribe flag
          state = Map.put(state, :token_manager, updated_token_manager)

          {:error, reason, state}
      end
    else
      # No resubscription needed or missing required state
      {:ok, state}
    end
  end

  @doc """
  Enhances process_method_specific_request to handle resubscription after authentication.

  This function adds resubscription handling to the existing process_method_specific_request function.
  """
  @spec enhanced_process_method_specific_request(map(), map(), map(), function()) :: map()
  def enhanced_process_method_specific_request(request, message, state, original_handler) do
    # First, call the original handler
    new_state = original_handler.(request, message, state)

    # For auth response, check if we need to resubscribe
    if request && request.method == "public/auth" && Map.get(state, :need_resubscribe, false) do
      case handle_reconnect_authenticated(new_state) do
        {:ok, updated_state} -> updated_state
        {:error, _, updated_state} -> updated_state
      end
    else
      new_state
    end
  end

  @doc """
  Registers an order with the token manager.

  Call this function when creating a new order.
  """
  @spec register_order_with_token_manager(map(), map()) :: map()
  def register_order_with_token_manager(state, order) do
    if Map.has_key?(state, :token_manager) do
      # Register order with token manager
      case TokenManager.register_order(state.token_manager, order) do
        {:ok, updated_token_manager} ->
          # Update state with new token manager
          Map.put(state, :token_manager, updated_token_manager)

        {:error, reason} ->
          # Log error but continue with existing token manager
          Logger.error("Failed to register order with token manager: #{inspect(reason)}")
          state
      end
    else
      # Token manager not found in state
      state
    end
  end

  @doc """
  Updates an order in the token manager.

  Call this function when order status changes.
  """
  @spec update_order_in_token_manager(map(), map()) :: map()
  def update_order_in_token_manager(state, order) do
    if Map.has_key?(state, :token_manager) do
      # Update order in token manager
      case TokenManager.update_order(state.token_manager, order) do
        {:ok, updated_token_manager} ->
          # Update state with new token manager
          Map.put(state, :token_manager, updated_token_manager)

        {:error, reason} ->
          # Log error but continue with existing token manager
          Logger.error("Failed to update order in token manager: #{inspect(reason)}")
          state
      end
    else
      # Token manager not found in state
      state
    end
  end

  @doc """
  Gets all active orders from the token manager.

  Use this function to access active orders.
  """
  @spec get_active_orders(map()) :: {:ok, list()} | {:error, any()}
  def get_active_orders(state) do
    if Map.has_key?(state, :token_manager) do
      TokenManager.get_active_orders(state.token_manager)
    else
      {:error, :no_token_manager}
    end
  end
end
