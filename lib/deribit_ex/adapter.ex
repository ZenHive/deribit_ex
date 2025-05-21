defmodule DeribitEx.DeribitAdapter do
  @moduledoc """
  WebsockexNova adapter for the Deribit WebSocket API.

  Handles connection, authentication, and message processing
  specifically for the Deribit JSON-RPC WebSocket protocol.
  """
  use WebsockexNova.Adapter

  alias DeribitEx.DeribitRPC
  alias WebsockexNova.Behaviors.AuthHandler
  alias WebsockexNova.Behaviors.ConnectionHandler
  alias WebsockexNova.Behaviors.SubscriptionHandler
  alias WebsockexNova.Defaults.DefaultMessageHandler

  require Logger

  @port 443
  @path "/ws/api/v2"

  # Determines the default host based on environment.
  # Uses test.deribit.com for dev/test environments and
  # www.deribit.com for production.
  defp default_host do
    case Application.get_env(:deribit_ex, :env, :prod) do
      :test -> "test.deribit.com"
      :dev -> "test.deribit.com"
      _ -> "www.deribit.com"
    end
  end

  # Get rate limit mode based on options, environment, or config
  defp get_rate_limit_mode(opts) do
    valid_modes = [:cautious, :normal, :aggressive]

    # Get mode from each possible source
    opts_mode = get_mode_from_opts(opts, valid_modes)
    env_mode = get_mode_from_env(valid_modes)
    config_mode = get_mode_from_config(valid_modes)

    # Return first valid mode found, or default to :normal
    opts_mode || env_mode || config_mode || :normal
  end

  # Get mode from function options
  defp get_mode_from_opts(opts, valid_modes) do
    mode = Map.get(opts, :rate_limit_mode)
    if mode in valid_modes, do: mode
  end

  # Get mode from environment variables
  defp get_mode_from_env(_valid_modes) do
    case System.get_env("DERIBIT_RATE_LIMIT_MODE") do
      "cautious" -> :cautious
      "normal" -> :normal
      "aggressive" -> :aggressive
      _ -> nil
    end
  end

  # Get mode from application config
  defp get_mode_from_config(valid_modes) do
    mode = Application.get_env(:deribit_ex, :websocket, [])[:rate_limiting][:mode]
    if mode in valid_modes, do: mode
  end

  @impl ConnectionHandler
  @doc """
  Provides connection configuration for the WebsockexNova client.

  Merges provided options with sensible defaults for Deribit connection.

  Configures optimal authentication refresh thresholds based on Deribit's
  token expiration patterns. Tokens typically last 900 seconds, and 
  refresh begins at the configured threshold before expiration.
  """
  @spec connection_info(map()) :: {:ok, map()}
  def connection_info(opts) do
    host = Map.get(opts, :host) || System.get_env("DERIBIT_HOST") || default_host()

    # Read auth_refresh_threshold from different sources with different priorities:
    # 1. Function call options (highest priority)
    # 2. Environment variable
    # 3. Application configuration
    # 4. Default value (lowest priority)
    # Default value if not specified elsewhere
    auth_refresh_seconds =
      Map.get(opts, :auth_refresh_threshold) ||
        (System.get_env("DERIBIT_AUTH_REFRESH_THRESHOLD") &&
           "DERIBIT_AUTH_REFRESH_THRESHOLD" |> System.get_env() |> String.to_integer()) ||
        Application.get_env(:deribit_ex, :websocket, [])[:auth_refresh_threshold] ||
        180

    defaults = %{
      # Connection/Transport
      host: host,
      port: @port,
      path: @path,
      headers: [],
      timeout: 10_000,
      transport: :tls,
      transport_opts: %{},
      protocols: [:http],
      retry: 10,
      backoff_type: :exponential,
      base_backoff: 2_000,
      ws_opts: %{},
      callback_pid: nil,

      # Rate Limiting
      # Using a custom adaptive rate limiting handler that responds to Deribit's 429 errors
      rate_limit_handler: DeribitEx.DeribitRateLimitHandler,
      rate_limit_opts: %{
        # Three rate limit modes:
        # - :cautious - Strict limits to avoid 429s completely
        # - :normal - Balanced approach 
        # - :aggressive - Higher throughput, might get occasional 429s
        mode: get_rate_limit_mode(opts),

        # Token bucket parameters - default rates for normal mode
        # Maximum number of tokens in the bucket
        capacity: 120,
        # Rate at which tokens are added to the bucket
        refill_rate: 10,
        # Interval in ms between token refills
        refill_interval: 1_000,
        # Maximum number of requests that can be queued
        queue_limit: 200,

        # Request costs - different operations consume different amounts of tokens
        cost_map: %{
          # Subscription operations
          subscription: 5,
          # Authentication operations
          auth: 10,
          # Simple read operations
          query: 1,
          # Order placement and modification
          order: 10,
          # Critical operations bypass rate limiting
          high_priority: 0,
          # Order cancellation
          cancel: 3
        },

        # Adaptive rate limiting parameters
        adaptive: %{
          # Backoff multipliers for 429 responses
          # Initial backoff multiplier
          backoff_initial: 1.5,
          # Maximum backoff multiplier
          backoff_max: 10.0,
          # Time in ms after which backoff is reset
          backoff_reset_after: 60_000,

          # Recovery parameters
          # Factor by which rate limit is reduced after 429
          recovery_factor: 0.9,
          # Rate at which limits recover after backoff
          recovery_increase: 0.05,
          # Time between recovery adjustments
          recovery_interval: 5_000,

          # Telemetry for monitoring rate limiting behavior
          telemetry_prefix: [:deribit_ex, :rate_limit]
        }
      },

      # Logging
      logging_handler: WebsockexNova.Defaults.DefaultLoggingHandler,
      log_level: :info,
      log_format: :plain,

      # Metrics
      metrics_collector: nil,

      # Authentication
      auth_handler: __MODULE__,
      credentials: %{
        "api_key" => System.get_env("DERIBIT_CLIENT_ID") || System.get_env("DERIBIT_API_KEY"),
        "secret" =>
          System.get_env("DERIBIT_CLIENT_SECRET") || System.get_env("DERIBIT_API_SECRET")
      },
      # Set the optimal auth refresh threshold
      # Deribit tokens typically last 900 seconds (15 minutes)
      # We want to refresh with plenty of time remaining to avoid any gaps
      # Recommended range: 180-300 seconds (3-5 minutes) before expiration
      auth_refresh_threshold: auth_refresh_seconds,

      # Emit telemetry with the configured threshold
      auth_refresh_config: %{
        threshold_seconds: auth_refresh_seconds,
        # Standard Deribit token lifetime in seconds
        target_token_lifetime: 900,
        refresh_mode: :proactive
      },

      # Subscription
      subscription_handler: __MODULE__,
      subscription_timeout: 30,

      # Message
      message_handler: __MODULE__,

      # Error Handling
      error_handler: WebsockexNova.Defaults.DefaultErrorHandler,
      max_reconnect_attempts: 5,
      reconnect_attempts: 0,
      ping_interval: 30_000
    }

    # Log the authentication refresh configuration
    :telemetry.execute(
      [:deribit_ex, :adapter, :auth_refresh_config],
      %{system_time: System.system_time()},
      %{threshold: auth_refresh_seconds}
    )

    {:ok, Map.merge(defaults, opts)}
  end

  @impl ConnectionHandler
  @doc """
  Initializes the adapter's state.
  """
  @spec init(map() | any()) :: {:ok, map()}
  def init(opts) do
    # Ensure opts is a map
    opts = if is_map(opts), do: opts, else: %{}

    state = %{
      messages: [],
      connected_at: nil,
      auth_status: :unauthenticated,
      reconnect_attempts: 0,
      max_reconnect_attempts: 5,
      subscriptions: %{},
      subscription_requests: %{},
      # Add requests tracking for JSON-RPC
      requests: %{},
      # Default request timeout in milliseconds
      request_timeout: Map.get(opts, :request_timeout, 10_000),
      auth_refresh_threshold: Map.get(opts, :auth_refresh_threshold, 60),
      credentials: Map.get(opts, :credentials, %{})
    }

    {:ok, state}
  end

  @impl AuthHandler
  @doc """
  Generates authentication data for Deribit API.

  Uses client credentials from the connection state
  to create a proper Deribit authentication request.
  """
  @spec generate_auth_data(map()) :: {:ok, String.t(), map()} | {:error, atom(), map()}
  def generate_auth_data(state) do
    # Log the state structure for debugging
    Logger.debug("State in generate_auth_data: #{inspect(state, limit: 2)}")

    # First try credentials directly on state
    state_credentials = Map.get(state, :credentials)
    # Then try connection_info.credentials
    connection_credentials = state |> Map.get(:connection_info, %{}) |> Map.get(:credentials)
    # Then try ClientConn.connection_info.credentials
    client_conn_credentials = get_in(state, [:client_conn, :connection_info, :credentials])

    # Add all credentials locations to state for validation
    state_with_all_credentials =
      state
      |> maybe_put_credentials(:direct_credentials, state_credentials)
      |> maybe_put_credentials(:conn_info_credentials, connection_credentials)
      |> maybe_put_credentials(:client_conn_credentials, client_conn_credentials)

    # Validate that credentials exist and are properly structured
    with {:ok, credentials} <- validate_credentials(state_with_all_credentials),
         client_id = Map.get(credentials, :api_key) || Map.get(credentials, "api_key"),
         client_secret = Map.get(credentials, :secret) || Map.get(credentials, "secret"),
         true <- is_binary(client_id) and client_id != "",
         true <- is_binary(client_secret) and client_secret != "" do
      auth_params = %{
        "grant_type" => "client_credentials",
        "client_id" => client_id,
        "client_secret" => client_secret
      }

      # Use the DeribitRPC module to generate the request
      {:ok, payload, request_id} = DeribitRPC.generate_request("public/auth", auth_params)

      # Track the request in state
      state = DeribitRPC.track_request(state, request_id, "public/auth", auth_params)

      # No need to put credentials back in state since they're already there
      {:ok, Jason.encode!(payload), state}
    else
      {:error, reason} ->
        # Propagate the error
        {:error, reason, state}

      false ->
        # Missing or empty API key or secret
        state = Map.put(state, :auth_status, :failed)
        state = Map.put(state, :auth_error, "Missing or invalid API credentials")

        # Emit telemetry for credential validation failure
        :telemetry.execute(
          [:deribit_ex, :adapter, :auth, :validation_failure],
          %{system_time: System.system_time()},
          %{reason: :invalid_credentials}
        )

        {:error, :invalid_credentials, state}
    end
  end

  # Helper function to extract credential value from multiple possible keys
  defp get_credential_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.reduce_while(keys, nil, fn key, _acc ->
      value = Map.get(map, key)
      if is_nil(value) or value == "", do: {:cont, nil}, else: {:halt, value}
    end)
  end

  # Helper to validate credentials in state - check multiple locations
  defp validate_credentials(%{direct_credentials: credentials}) when is_map(credentials) do
    validate_credential_map(credentials)
  end

  defp validate_credentials(%{conn_info_credentials: credentials}) when is_map(credentials) do
    validate_credential_map(credentials)
  end

  defp validate_credentials(%{client_conn_credentials: credentials}) when is_map(credentials) do
    validate_credential_map(credentials)
  end

  defp validate_credentials(%{all_credentials: credentials}) when is_map(credentials) do
    validate_credential_map(credentials)
  end

  defp validate_credentials(%{credentials: credentials}) when is_map(credentials) do
    validate_credential_map(credentials)
  end

  defp validate_credentials(_state) do
    Logger.warning("No credentials found in state. Authentication will fail.")
    {:error, :missing_credentials}
  end

  # Helper to add credentials to state if they exist
  defp maybe_put_credentials(state, _key, nil), do: state
  defp maybe_put_credentials(state, _key, ""), do: state
  defp maybe_put_credentials(state, _key, %{}), do: state
  defp maybe_put_credentials(state, key, credentials), do: Map.put(state, key, credentials)

  # Helper to validate a credentials map
  defp validate_credential_map(credentials) when is_map(credentials) do
    # Attempt to extract API key and secret from various locations and formats
    api_key = get_credential_value(credentials, ["api_key", :api_key, "client_id", :client_id])
    secret = get_credential_value(credentials, ["secret", :secret])

    # If credentials are nested, try those too
    api_key =
      api_key ||
        get_credential_value(
          get_in(credentials, ["credentials"]) ||
            get_in(credentials, [:credentials]) ||
            %{},
          ["api_key", :api_key, "client_id", :client_id]
        )

    secret =
      secret ||
        get_credential_value(
          get_in(credentials, ["credentials"]) ||
            get_in(credentials, [:credentials]) ||
            %{},
          ["secret", :secret]
        )

    cond do
      is_nil(api_key) or api_key == "" ->
        Logger.warning(
          "Missing API key in credentials. Check DERIBIT_CLIENT_ID or DERIBIT_API_KEY environment variables."
        )

        {:error, :missing_api_key}

      is_nil(secret) or secret == "" ->
        Logger.warning(
          "Missing API secret in credentials. Check DERIBIT_CLIENT_SECRET or DERIBIT_API_SECRET environment variables."
        )

        {:error, :missing_api_secret}

      true ->
        {:ok, %{"api_key" => api_key, "secret" => secret}}
    end
  end

  @impl AuthHandler
  @doc """
  Handles authentication response from Deribit.

  Processes different types of responses:
  - Success: Stores token and expiration time
  - Error: Stores error details
  - Other: Passes through

  Uses WebsockexNova's built-in authentication refresh mechanism to
  handle token renewal before expiration.
  """
  @spec handle_auth_response(map(), map()) :: {:ok, map()} | {:error, map(), map()}
  def handle_auth_response(response, state) do
    # Use the common token response handler with an operation identifier
    handle_token_response(response, state, :auth)
  end

  # Common handler for auth, exchange_token, and fork_token responses
  @spec handle_token_response(map(), map(), atom()) ::
          {:ok, map()} | {:error, map(), map()} | {:reconnect, any(), map()}
  defp handle_token_response(
         %{
           "result" =>
             %{
               "access_token" => access_token,
               "expires_in" => expires_in,
               "refresh_token" => refresh_token
             } = result
         },
         state,
         operation
       ) do
    # Calculate the expiration time for the token
    expiration_time = DateTime.add(DateTime.utc_now(), expires_in, :second)

    # Get refresh threshold from state or config - this is used by WebsockexNova to determine when to refresh
    threshold_seconds = Map.get(state, :auth_refresh_threshold, 60)

    # Set up WebsockexNova auth refresh mechanism
    # The framework will automatically call generate_auth_data when token is about to expire
    # based on this information, eliminating our need to set up a timer manually
    auth_info = %{
      access_token: access_token,
      refresh_token: refresh_token,
      expires_in: expires_in,
      expires_at: expiration_time,
      refresh_threshold: threshold_seconds
    }

    # Emit telemetry about the tokens we received
    :telemetry.execute(
      [:deribit_ex, :adapter, :token, :received],
      %{system_time: System.system_time(), expires_in: expires_in},
      %{operation: operation, scope: Map.get(result, "scope")}
    )

    state =
      state
      |> Map.put(:auth_status, :authenticated)
      |> Map.put(:access_token, access_token)
      |> Map.put(:refresh_token, refresh_token)
      |> Map.put(:auth_expires_in, expires_in)
      |> Map.put(:auth_expires_at, expiration_time)
      |> Map.put(:auth_scope, Map.get(result, "scope"))
      |> Map.put(:auth_info, auth_info)

    # Emit telemetry for successful operation
    :telemetry.execute(
      [:deribit_ex, :adapter, operation, :success],
      %{system_time: System.system_time()},
      %{expires_in: expires_in, scope: Map.get(result, "scope")}
    )

    {:ok, state}
  end

  defp handle_token_response(%{"error" => error}, state, operation) do
    # Use the DeribitRPC module to determine if we need to reconnect
    reconnect_needed = DeribitRPC.needs_reauth?(error)

    # Extract error details for telemetry
    error_code = Map.get(error, "code")
    error_message = Map.get(error, "message")

    state =
      state
      |> Map.put(:auth_status, :failed)
      |> Map.put(:auth_error, error)

    # Emit telemetry for operation failure
    :telemetry.execute(
      [:deribit_ex, :adapter, operation, :failure],
      %{system_time: System.system_time()},
      %{
        error_code: error_code,
        error_message: error_message,
        reconnect_needed: reconnect_needed
      }
    )

    if reconnect_needed do
      # Signal to WebsockexNova that we need to reconnect due to auth issue
      {:reconnect, {:auth_error, error}, state}
    else
      # Regular error that doesn't require reconnection
      {:error, error, state}
    end
  end

  defp handle_token_response(_other, state, _operation), do: {:ok, state}

  @impl SubscriptionHandler
  @doc """
  Creates a subscription request for a specific channel.

  Handles different subscription types (public vs. private)
  based on channel name and authentication status.
  """
  @spec subscribe(String.t(), map(), map()) :: {:ok, String.t(), map()}
  def subscribe(channel, params, state) do
    # Check if we need authentication for this channel
    needs_auth = String.contains?(channel, ".raw") || String.contains?(channel, "private")

    method =
      if needs_auth && state[:access_token], do: "private/subscribe", else: "public/subscribe"

    subscription_params = %{"channels" => [channel]}

    # Add authentication token if needed using DeribitRPC helper
    access_token = Map.get(state, :access_token)
    subscription_params = DeribitRPC.add_auth_params(subscription_params, method, access_token)

    # Merge any additional parameters
    subscription_params = Map.merge(subscription_params, params || %{})

    # Generate the JSON-RPC request using DeribitRPC
    {:ok, payload, request_id} = DeribitRPC.generate_request(method, subscription_params)

    # Store subscription request for tracking
    subscription_requests = Map.get(state, :subscription_requests, %{})

    subscription_requests =
      Map.put(subscription_requests, request_id, %{channel: channel, params: params})

    state = Map.put(state, :subscription_requests, subscription_requests)

    # Track the request in our general RPC request tracker as well
    state = DeribitRPC.track_request(state, request_id, method, subscription_params)

    {:ok, Jason.encode!(payload), state}
  end

  @impl SubscriptionHandler
  @doc """
  Handles subscription response from Deribit.
  """
  @spec handle_subscription_response(map(), map()) :: {:ok, map()} | {:error, any(), map()}
  def handle_subscription_response(%{"result" => %{"subscribed" => channels}} = response, state) do
    subscription_requests = Map.get(state, :subscription_requests, %{})
    id = response["id"]
    request = Map.get(subscription_requests, id)

    if request do
      subscriptions = Map.get(state, :subscriptions, %{})

      # Add each channel to our subscriptions map
      subscriptions =
        Enum.reduce(channels, subscriptions, fn channel, acc ->
          Map.put(acc, channel, %{
            subscribed_at: DateTime.utc_now(),
            id: id,
            params: request.params,
            status: :active
          })
        end)

      # Remove the request from pending
      subscription_requests = Map.delete(subscription_requests, id)

      state =
        state
        |> Map.put(:subscriptions, subscriptions)
        |> Map.put(:subscription_requests, subscription_requests)

      {:ok, state}
    else
      # If we can't find the original request, just update state
      {:ok, state}
    end
  end

  def handle_subscription_response(%{"error" => error}, state) do
    {:error, error, state}
  end

  def handle_subscription_response(_other, state), do: {:ok, state}

  @impl WebsockexNova.Behaviors.MessageHandler
  @doc """
  Handles messages from Deribit WebSocket API.

  Processes different message types:
  - Auth errors: Signals need for authentication
  - JSON-RPC responses: Matches with tracked requests and processes appropriately
  - Other messages: Delegates to DefaultMessageHandler
  """
  @spec handle_message(map(), map()) ::
          {:needs_auth, map(), map()} | {:ok, map(), map()} | {:error, any(), map()}
  def handle_message(%{"error" => %{"code" => 13_778}} = message, state) do
    # Handle "raw_subscriptions_not_available_for_unauthorized" error
    # This means we need to authenticate first
    {:needs_auth, message, state}
  end

  def handle_message(%{"method" => "test_request", "params" => params}, state) do
    # Auto-respond to test_request messages from the server by sending a public/test RPC
    handle_test_request(params, state)
  end

  def handle_message(%{"jsonrpc" => "2.0", "id" => id} = message, state) when not is_nil(id) do
    # Process JSON-RPC response with an ID
    process_jsonrpc_response(message, id, state)
  end

  def handle_message(message, state) do
    # Let the default handler process other messages
    DefaultMessageHandler.handle_message(message, state)
  end

  # Handle test request from Deribit heartbeat mechanism
  defp handle_test_request(params, state) do
    # Extract any params like expected_result that should be echoed back
    test_params = Map.take(params, ["expected_result"])

    # Generate the JSON-RPC request
    {:ok, payload, request_id} = DeribitRPC.generate_request("public/test", test_params)

    # Track the request in state
    state = DeribitRPC.track_request(state, request_id, "public/test", test_params)

    # Emit telemetry for test request handling
    :telemetry.execute(
      [:deribit_ex, :adapter, :test_request, :handled],
      %{system_time: System.system_time()},
      %{request_id: request_id}
    )

    # Return the JSON payload to be sent by WebsockexNova
    # This ensures the message is actually sent in response to test_request
    encoded_payload = Jason.encode!(payload)

    # Log the auto-response at debug level
    Logger.debug(
      "[DeribitAdapter] Auto-responding to test_request with public/test. " <>
        "Expected result: #{inspect(Map.get(test_params, "expected_result", "none"))}"
    )

    # Return special tuple that tells WebsockexNova to send the response
    {:reply, encoded_payload, state}
  end

  # Process a JSON-RPC response with an ID
  defp process_jsonrpc_response(message, id, state) do
    # Update message tracking state
    updated_state = update_message_state(message, state)

    # Get tracked request if it exists
    request = get_tracked_request(id, state)

    # Remove request from tracking if it exists
    updated_state = maybe_remove_tracked_request(request, id, updated_state)

    # Handle method-specific processing if this was a tracked request
    updated_state = process_method_specific_request(request, message, updated_state)

    # Finalize response handling based on result or error
    finalize_response(message, request, updated_state)
  end

  # Update the state with new message info
  defp update_message_state(message, state) do
    processed_count = Map.get(state, :processed_count, 0)
    messages = Map.get(state, :messages, [])

    state
    |> Map.put(:processed_count, processed_count + 1)
    |> Map.put(:messages, [message | messages])
    |> Map.put(:last_message, message)
  end

  # Get a tracked request by ID
  defp get_tracked_request(id, state) do
    requests = Map.get(state, :requests, %{})
    Map.get(requests, id)
  end

  # Remove tracked request if it exists
  defp maybe_remove_tracked_request(nil, _id, state), do: state

  defp maybe_remove_tracked_request(_request, id, state) do
    DeribitRPC.remove_tracked_request(state, id)
  end

  # Process method-specific request
  defp process_method_specific_request(nil, _message, state), do: state

  defp process_method_specific_request(request, message, state) do
    case request.method do
      # Special handling for authentication methods
      "public/auth" ->
        apply_response_handler(&handle_auth_response/2, message, state)

      "public/exchange_token" ->
        apply_response_handler(&handle_exchange_token_response/2, message, state)

      "public/fork_token" ->
        apply_response_handler(&handle_fork_token_response/2, message, state)

      "private/logout" ->
        apply_response_handler(&handle_logout_response/2, message, state)

      # Default fallback for other methods
      _ ->
        state
    end
  end

  # Apply a response handler and extract the state
  defp apply_response_handler(handler, message, state) do
    case handler.(message, state) do
      {:ok, new_state} -> new_state
      {:error, _, new_state} -> new_state
      {:reconnect, _, new_state} -> new_state
    end
  end

  # Finalize response based on result or error
  defp finalize_response(message, request, state) do
    case DeribitRPC.parse_response(message) do
      {:error, error} ->
        if request && DeribitRPC.needs_reauth?(error) do
          # This is an auth error that requires reconnection
          {:needs_auth, message, state}
        else
          # Regular error, just pass through
          {:ok, message, state}
        end

      _ ->
        # Success or other response
        {:ok, message, state}
    end
  end

  @doc """
  Handles various info messages sent to the process.

  This used to handle manual refresh_auth messages, but now we use 
  WebsockexNova's built-in auth refresh mechanism. This handler remains
  for backward compatibility with existing tests and other potential
  custom messages.
  """
  @spec handle_info(atom() | tuple(), map()) :: {:ok, map()} | {:error, any(), map()}
  def handle_info(:refresh_auth, state) do
    # For backward compatibility with tests
    # In production, WebsockexNova will now handle this automatically based on auth_info
    case state.auth_status do
      :authenticated ->
        # Log that we're using the legacy refresh mechanism
        :telemetry.execute(
          [:deribit_ex, :adapter, :legacy_refresh],
          %{system_time: System.system_time()},
          %{auth_status: state.auth_status}
        )

        # Trigger a refresh via generate_auth_data (for test compatibility)
        # In production code, this should not be reached as WebsockexNova will handle refreshes
        generate_auth_data(state)

      _ ->
        # Not authenticated, nothing to refresh
        {:ok, state}
    end
  end

  def handle_info({:timeout, request_id}, state) do
    # Handle timeout for a request
    requests = Map.get(state, :requests, %{})

    case Map.get(requests, request_id) do
      nil ->
        # Request not found or already processed
        {:ok, state}

      request ->
        # Clean up the request from state
        state = DeribitRPC.remove_tracked_request(state, request_id)

        # Emit telemetry for timeout
        :telemetry.execute(
          [:deribit_ex, :rpc, :timeout],
          %{system_time: System.system_time()},
          %{request_id: request_id, method: request.method}
        )

        {:ok, state}
    end
  end

  def handle_info(_info, state) do
    # Ignore other messages
    {:ok, state}
  end

  @doc """
  Generates data for token exchange operation.

  This function creates the payload for the public/exchange_token RPC method
  used to generate a new access token for switching subaccounts.
  """
  @spec generate_exchange_token_data(map(), map()) :: {:ok, String.t(), map()}
  def generate_exchange_token_data(params, state) do
    # Extract required parameters
    refresh_token = Map.get(params, "refresh_token") || Map.get(state, :refresh_token)
    subject_id = Map.get(params, "subject_id")

    # Ensure required parameters are present
    if !(refresh_token && subject_id) do
      raise "Missing required parameters for token exchange: refresh_token and subject_id"
    end

    exchange_params = %{
      "refresh_token" => refresh_token,
      "subject_id" => subject_id
    }

    # Use the DeribitRPC module to generate the request
    {:ok, payload, request_id} =
      DeribitRPC.generate_request("public/exchange_token", exchange_params)

    # Track the request in state
    state = DeribitRPC.track_request(state, request_id, "public/exchange_token", exchange_params)

    {:ok, Jason.encode!(payload), state}
  end

  @doc """
  Handles token exchange response from Deribit.

  Processes response from the public/exchange_token endpoint and updates
  state with new tokens and expiration information.
  """
  @spec handle_exchange_token_response(map(), map()) :: {:ok, map()} | {:error, map(), map()}
  def handle_exchange_token_response(response, state) do
    # Use the common token response handler with an operation identifier
    handle_token_response(response, state, :exchange_token)
  end

  @doc """
  Generates data for token fork operation.

  This function creates the payload for the public/fork_token RPC method
  used to create a new named session via refresh token.
  """
  @spec generate_fork_token_data(map(), map()) :: {:ok, String.t(), map()}
  def generate_fork_token_data(params, state) do
    # Extract required parameters
    refresh_token = Map.get(params, "refresh_token") || Map.get(state, :refresh_token)
    session_name = Map.get(params, "session_name")

    # Ensure required parameters are present
    if !(refresh_token && session_name) do
      raise "Missing required parameters for token fork: refresh_token and session_name"
    end

    fork_params = %{
      "refresh_token" => refresh_token,
      "session_name" => session_name
    }

    # Use the DeribitRPC module to generate the request
    {:ok, payload, request_id} = DeribitRPC.generate_request("public/fork_token", fork_params)

    # Track the request in state
    state = DeribitRPC.track_request(state, request_id, "public/fork_token", fork_params)

    {:ok, Jason.encode!(payload), state}
  end

  @doc """
  Handles token fork response from Deribit.

  Processes response from the public/fork_token endpoint and updates
  state with new tokens and expiration information.
  """
  @spec handle_fork_token_response(map(), map()) :: {:ok, map()} | {:error, map(), map()}
  def handle_fork_token_response(response, state) do
    # Use the common token response handler with an operation identifier
    handle_token_response(response, state, :fork_token)
  end

  @doc """
  Generates data for logout operation.

  This function creates the payload for the private/logout RPC method
  used to gracefully close the session and optionally invalidate tokens.

  ## Parameters
  - `params` - Parameters for the logout request:
    - `"invalidate_token"` - Whether to invalidate all tokens (defaults to true)
  - `state` - Current adapter state containing the access token

  ## Returns
  - `{:ok, payload, updated_state}` - The JSON-RPC request as a string and updated state
  - Raises an error if no access token is found in the state

  ## Examples
      # Generate payload to logout and invalidate tokens
      params = %{"invalidate_token" => true}
      {:ok, payload, updated_state} = generate_logout_data(params, state)

      # Generate payload to logout without invalidating tokens
      params = %{"invalidate_token" => false}
      {:ok, payload, updated_state} = generate_logout_data(params, state)
  """
  @spec generate_logout_data(map(), map()) :: {:ok, String.t(), map()}
  def generate_logout_data(params, state) do
    # Extract required parameters with defaults
    invalidate_token = Map.get(params, "invalidate_token", true)
    access_token = Map.get(state, :access_token)

    # Ensure we have an access token
    if !access_token do
      raise "Cannot logout: No access token in state"
    end

    logout_params = %{
      "access_token" => access_token,
      "invalidate_token" => invalidate_token
    }

    # Use the DeribitRPC module to generate the request
    {:ok, payload, request_id} = DeribitRPC.generate_request("private/logout", logout_params)

    # Track the request in state
    state = DeribitRPC.track_request(state, request_id, "private/logout", logout_params)

    # Emit telemetry for logout request
    :telemetry.execute(
      [:deribit_ex, :adapter, :logout, :request],
      %{system_time: System.system_time()},
      %{invalidate_token: invalidate_token}
    )

    {:ok, Jason.encode!(payload), state}
  end

  @doc """
  Handles logout response from Deribit.

  Updates the state to reflect the user is no longer authenticated by:
  - Setting auth_status to :unauthenticated
  - Removing access_token, refresh_token, and related fields

  This ensures that after logout, any subsequent operations requiring authentication
  will require a new authentication process.

  ## Parameters
  - `response` - The response from Deribit for the logout request
  - `state` - Current adapter state

  ## Returns
  - `{:ok, updated_state}` - On successful logout with state cleared of auth data
  - `{:error, error, updated_state}` - On error response, with error recorded in state
  - `{:ok, state}` - For unrecognized responses (fallthrough case)

  ## Examples
      # Successful logout
      response = %{"result" => "ok"}
      {:ok, updated_state} = handle_logout_response(response, state)
      # updated_state.auth_status == :unauthenticated
      
      # Error response
      response = %{"error" => %{"code" => 10011, "message" => "Error message"}}
      {:error, error, updated_state} = handle_logout_response(response, state)
  """
  @spec handle_logout_response(map(), map()) :: {:ok, map()} | {:error, map(), map()}
  def handle_logout_response(%{"result" => _result}, state) do
    # Clear authentication data from state
    state =
      state
      |> Map.put(:auth_status, :unauthenticated)
      |> Map.delete(:access_token)
      |> Map.delete(:refresh_token)
      |> Map.delete(:auth_expires_in)
      |> Map.delete(:auth_expires_at)
      |> Map.delete(:auth_scope)
      # Also remove the auth_info used by WebsockexNova for refresh
      |> Map.delete(:auth_info)

    # Emit telemetry for successful logout
    :telemetry.execute(
      [:deribit_ex, :adapter, :logout, :success],
      %{system_time: System.system_time()},
      %{}
    )

    {:ok, state}
  end

  def handle_logout_response(%{"error" => error}, state) do
    # For logout, we generally don't need to reconnect on error
    state = Map.put(state, :auth_error, error)

    # Emit telemetry for logout failure
    :telemetry.execute(
      [:deribit_ex, :adapter, :logout, :failure],
      %{system_time: System.system_time()},
      %{error: error}
    )

    {:error, error, state}
  end

  def handle_logout_response(_other, state), do: {:ok, state}

  @doc """
  Sends a JSON-RPC request to the Deribit API.

  This is a general-purpose RPC handler for sending any Deribit API request.
  It handles request generation, authentication, timeout tracking, and more.

  ## Parameters
  - `method` - The JSON-RPC method to call (e.g., "public/get_time")
  - `params` - The parameters to pass to the method (map)
  - `state` - The current adapter state
  - `options` - Optional request options

  ## Returns
  - `{:ok, encoded_request, updated_state}` - The JSON request and updated state
  """
  @spec send_rpc_request(String.t(), map(), map(), map() | nil) :: {:ok, String.t(), map()}
  def send_rpc_request(method, params, state, options \\ nil) do
    # Get access token for authentication if needed
    access_token = Map.get(state, :access_token)

    # Add auth token if this is a private method
    params = DeribitRPC.add_auth_params(params, method, access_token)

    # Generate the JSON-RPC request
    {:ok, payload, request_id} = DeribitRPC.generate_request(method, params)

    # Track the request in state
    state = DeribitRPC.track_request(state, request_id, method, params, options)

    # Set up timeout if needed
    request_timeout = Map.get(options || %{}, :timeout, state.request_timeout)

    if request_timeout > 0 do
      Process.send_after(self(), {:timeout, request_id}, request_timeout)
    end

    # Emit telemetry for request sent
    :telemetry.execute(
      [:deribit_ex, :rpc, :request],
      %{system_time: System.system_time()},
      %{request_id: request_id, method: method}
    )

    {:ok, Jason.encode!(payload), state}
  end

  @doc """
  Generates data for the set_heartbeat operation.

  This function prepares the JSON-RPC request for the public/set_heartbeat 
  endpoint, which enables server heartbeat messages for the connection.

  ## Parameters
  - `params` - Parameters containing at least the heartbeat interval in seconds (minimum 10s)
  - `state` - The current adapter state

  ## Returns
  - `{:ok, encoded_request, updated_state}` - The JSON request and updated state
  """
  @spec generate_set_heartbeat_data(map(), map()) :: {:ok, String.t(), map()}
  def generate_set_heartbeat_data(params, state) do
    # Extract interval ensuring it's at least 10 seconds (Deribit minimum)
    interval = max(Map.get(params, "interval", 30), 10)

    # Create heartbeat parameters
    heartbeat_params = %{
      "interval" => interval
    }

    # Generate the JSON-RPC request with a string ID
    request_id = to_string(System.unique_integer([:positive]))

    {:ok, payload, _} =
      DeribitRPC.generate_request("public/set_heartbeat", heartbeat_params, request_id)

    # Track the request in state
    state = DeribitRPC.track_request(state, request_id, "public/set_heartbeat", heartbeat_params)

    # Update state to record that we're enabling heartbeats
    state = Map.put(state, :heartbeat_enabled, true)
    state = Map.put(state, :heartbeat_interval, interval)

    {:ok, Jason.encode!(payload), state}
  end

  @doc """
  Handles set_heartbeat response from Deribit.

  Updates the state to reflect the heartbeat status after enabling it.
  """
  @spec handle_set_heartbeat_response(map(), map()) :: {:ok, map()} | {:error, map(), map()}
  def handle_set_heartbeat_response(%{"result" => "ok"}, state) do
    # Heartbeat successfully enabled, emit telemetry
    :telemetry.execute(
      [:deribit_ex, :adapter, :heartbeat, :enabled],
      %{system_time: System.system_time()},
      %{interval: Map.get(state, :heartbeat_interval, 30)}
    )

    {:ok, state}
  end

  def handle_set_heartbeat_response(%{"error" => error}, state) do
    # Failed to enable heartbeat
    state = Map.put(state, :heartbeat_enabled, false)

    # Emit telemetry for the failure
    :telemetry.execute(
      [:deribit_ex, :adapter, :heartbeat, :failure],
      %{system_time: System.system_time()},
      %{error: error}
    )

    {:error, error, state}
  end

  def handle_set_heartbeat_response(_other, state), do: {:ok, state}

  @doc """
  Generates data for the disable_heartbeat operation.

  This function prepares the JSON-RPC request for the public/disable_heartbeat 
  endpoint, which disables server heartbeat messages for the connection.

  ## Parameters
  - `params` - Parameters (unused but kept for consistency)
  - `state` - The current adapter state

  ## Returns
  - `{:ok, encoded_request, updated_state}` - The JSON request and updated state
  """
  @spec generate_disable_heartbeat_data(map(), map()) :: {:ok, String.t(), map()}
  def generate_disable_heartbeat_data(_params, state) do
    # No parameters needed for disable_heartbeat
    heartbeat_params = %{}

    # Generate the JSON-RPC request with a string ID
    request_id = to_string(System.unique_integer([:positive]))

    {:ok, payload, _} =
      DeribitRPC.generate_request("public/disable_heartbeat", heartbeat_params, request_id)

    # Track the request in state
    state =
      DeribitRPC.track_request(state, request_id, "public/disable_heartbeat", heartbeat_params)

    {:ok, Jason.encode!(payload), state}
  end

  @doc """
  Handles disable_heartbeat response from Deribit.

  Updates the state to reflect the heartbeat status after disabling it.
  """
  @spec handle_disable_heartbeat_response(map(), map()) :: {:ok, map()} | {:error, map(), map()}
  def handle_disable_heartbeat_response(%{"result" => "ok"}, state) do
    # Heartbeat successfully disabled, update state
    state = Map.put(state, :heartbeat_enabled, false)
    state = Map.delete(state, :heartbeat_interval)

    # Emit telemetry
    :telemetry.execute(
      [:deribit_ex, :adapter, :heartbeat, :disabled],
      %{system_time: System.system_time()},
      %{}
    )

    {:ok, state}
  end

  def handle_disable_heartbeat_response(%{"error" => error}, state) do
    # Failed to disable heartbeat, emit telemetry
    :telemetry.execute(
      [:deribit_ex, :adapter, :heartbeat, :failure],
      %{system_time: System.system_time()},
      %{error: error}
    )

    {:error, error, state}
  end

  def handle_disable_heartbeat_response(_other, state), do: {:ok, state}

  @doc """
  Generates data for the enable_cancel_on_disconnect operation.

  This function prepares the JSON-RPC request for the private/enable_cancel_on_disconnect
  endpoint, which enables automatic cancellation of orders on disconnection.

  ## Parameters
  - `params` - Parameters for COD, includes the scope (connection or account)
  - `state` - The current adapter state

  ## Returns
  - `{:ok, encoded_request, updated_state}` - The JSON request and updated state
  """
  @spec generate_enable_cod_data(map(), map()) :: {:ok, String.t(), map()}
  def generate_enable_cod_data(params, state) do
    # Extract scope (connection or account)
    scope = Map.get(params, "scope", "connection")

    # Make sure scope is valid
    if scope not in ["connection", "account"] do
      raise "Invalid scope for cancel_on_disconnect: '#{scope}'. Must be 'connection' or 'account'."
    end

    # Create enable_cancel_on_disconnect parameters
    cod_params = %{
      "scope" => scope
    }

    # Add authentication token
    access_token = Map.get(state, :access_token)

    if !access_token do
      raise "Cannot enable cancel_on_disconnect: No access token in state. Authentication required."
    end

    cod_params = Map.put(cod_params, "access_token", access_token)

    # Generate the JSON-RPC request
    {:ok, payload, request_id} =
      DeribitRPC.generate_request(
        "private/enable_cancel_on_disconnect",
        cod_params
      )

    # Track the request in state
    state =
      DeribitRPC.track_request(
        state,
        request_id,
        "private/enable_cancel_on_disconnect",
        cod_params
      )

    # Update state to record COD settings
    state = Map.put(state, :cod_enabled, true)
    state = Map.put(state, :cod_scope, scope)

    {:ok, Jason.encode!(payload), state}
  end

  @doc """
  Handles enable_cancel_on_disconnect response from Deribit.

  Updates the state to reflect the COD status after enabling it.
  """
  @spec handle_enable_cod_response(map(), map()) :: {:ok, map()} | {:error, map(), map()}
  def handle_enable_cod_response(%{"result" => "ok"}, state) do
    # COD successfully enabled, emit telemetry
    :telemetry.execute(
      [:deribit_ex, :adapter, :cod, :enabled],
      %{system_time: System.system_time()},
      %{scope: Map.get(state, :cod_scope, "connection")}
    )

    {:ok, state}
  end

  def handle_enable_cod_response(%{"error" => error}, state) do
    # Failed to enable COD
    state = Map.put(state, :cod_enabled, false)

    # Emit telemetry for the failure
    :telemetry.execute(
      [:deribit_ex, :adapter, :cod, :failure],
      %{system_time: System.system_time()},
      %{error: error}
    )

    {:error, error, state}
  end

  def handle_enable_cod_response(_other, state), do: {:ok, state}

  @doc """
  Generates data for the disable_cancel_on_disconnect operation.

  This function prepares the JSON-RPC request for the private/disable_cancel_on_disconnect
  endpoint, which disables automatic cancellation of orders on disconnection.

  ## Parameters
  - `params` - Parameters for disabling COD (optional scope)
  - `state` - The current adapter state

  ## Returns
  - `{:ok, encoded_request, updated_state}` - The JSON request and updated state
  """
  @spec generate_disable_cod_data(map(), map()) :: {:ok, String.t(), map()}
  def generate_disable_cod_data(params, state) do
    # Extract scope (connection or account)
    scope = Map.get(params, "scope", Map.get(state, :cod_scope, "connection"))

    # Create disable_cancel_on_disconnect parameters
    cod_params = %{
      "scope" => scope
    }

    # Add authentication token
    access_token = Map.get(state, :access_token)

    if !access_token do
      raise "Cannot disable cancel_on_disconnect: No access token in state. Authentication required."
    end

    cod_params = Map.put(cod_params, "access_token", access_token)

    # Generate the JSON-RPC request
    {:ok, payload, request_id} =
      DeribitRPC.generate_request(
        "private/disable_cancel_on_disconnect",
        cod_params
      )

    # Track the request in state
    state =
      DeribitRPC.track_request(
        state,
        request_id,
        "private/disable_cancel_on_disconnect",
        cod_params
      )

    {:ok, Jason.encode!(payload), state}
  end

  @doc """
  Handles disable_cancel_on_disconnect response from Deribit.

  Updates the state to reflect the COD status after disabling it.
  """
  @spec handle_disable_cod_response(map(), map()) :: {:ok, map()} | {:error, map(), map()}
  def handle_disable_cod_response(%{"result" => "ok"}, state) do
    # COD successfully disabled, update state
    state = Map.put(state, :cod_enabled, false)

    # Emit telemetry
    :telemetry.execute(
      [:deribit_ex, :adapter, :cod, :disabled],
      %{system_time: System.system_time()},
      %{scope: Map.get(state, :cod_scope, "connection")}
    )

    {:ok, state}
  end

  def handle_disable_cod_response(%{"error" => error}, state) do
    # Failed to disable COD, emit telemetry
    :telemetry.execute(
      [:deribit_ex, :adapter, :cod, :failure],
      %{system_time: System.system_time()},
      %{error: error}
    )

    {:error, error, state}
  end

  def handle_disable_cod_response(_other, state), do: {:ok, state}

  @doc """
  Generates data for the get_cancel_on_disconnect operation.

  This function prepares the JSON-RPC request for the private/get_cancel_on_disconnect
  endpoint, which gets the status of automatic order cancellation on disconnection.

  ## Parameters
  - `params` - Parameters for getting COD (no additional parameters needed)
  - `state` - The current adapter state

  ## Returns
  - `{:ok, encoded_request, updated_state}` - The JSON request and updated state
  """
  @spec generate_get_cod_data(map(), map()) :: {:ok, String.t(), map()}
  def generate_get_cod_data(_params, state) do
    # Create get_cancel_on_disconnect parameters (empty except for auth)
    cod_params = %{}

    # Add authentication token
    access_token = Map.get(state, :access_token)

    if !access_token do
      raise "Cannot get cancel_on_disconnect status: No access token in state. Authentication required."
    end

    cod_params = Map.put(cod_params, "access_token", access_token)

    # Generate the JSON-RPC request
    {:ok, payload, request_id} =
      DeribitRPC.generate_request(
        "private/get_cancel_on_disconnect",
        cod_params
      )

    # Track the request in state
    state =
      DeribitRPC.track_request(
        state,
        request_id,
        "private/get_cancel_on_disconnect",
        cod_params
      )

    {:ok, Jason.encode!(payload), state}
  end

  @doc """
  Handles get_cancel_on_disconnect response from Deribit.

  Updates the state with the current COD status from the API.
  """
  @spec handle_get_cod_response(map(), map()) :: {:ok, map()} | {:error, map(), map()}
  def handle_get_cod_response(%{"result" => result}, state) do
    # Extract status and scope from result
    is_enabled = Map.get(result, "enabled", false)
    scope = Map.get(result, "scope", "connection")

    # Update state with current status
    state = Map.put(state, :cod_enabled, is_enabled)
    state = Map.put(state, :cod_scope, scope)

    # Emit telemetry
    :telemetry.execute(
      [:deribit_ex, :adapter, :cod, :status],
      %{system_time: System.system_time()},
      %{enabled: is_enabled, scope: scope}
    )

    {:ok, state}
  end

  def handle_get_cod_response(%{"error" => error}, state) do
    # Failed to get COD status, emit telemetry
    :telemetry.execute(
      [:deribit_ex, :adapter, :cod, :failure],
      %{system_time: System.system_time()},
      %{error: error}
    )

    {:error, error, state}
  end

  def handle_get_cod_response(_other, state), do: {:ok, state}

  @doc """
  Generates data for the unsubscribe operation.

  This function prepares the JSON-RPC request for the public/unsubscribe or private/unsubscribe
  endpoint, which stops the stream for specified channels.

  ## Parameters
  - `params` - Parameters for unsubscribe, includes the channels to unsubscribe from
  - `state` - The current adapter state

  ## Returns
  - `{:ok, encoded_request, updated_state}` - The JSON request and updated state
  """
  @spec generate_unsubscribe_data(map(), map()) :: {:ok, String.t(), map()}
  def generate_unsubscribe_data(params, state) do
    # Extract channels from params, ensure it's a list
    channels = Map.get(params, "channels", [])
    channels = if is_list(channels), do: channels, else: [channels]

    # Check if any of the channels need authentication
    needs_auth =
      Enum.any?(channels, fn channel ->
        String.contains?(channel, ".raw") || String.contains?(channel, "private") ||
          String.starts_with?(channel, "user.")
      end)

    # Determine whether to use private or public unsubscribe
    method =
      if needs_auth && state[:access_token], do: "private/unsubscribe", else: "public/unsubscribe"

    # Create unsubscribe parameters
    unsubscribe_params = %{"channels" => channels}

    # Add authentication token if needed
    access_token = Map.get(state, :access_token)
    unsubscribe_params = DeribitRPC.add_auth_params(unsubscribe_params, method, access_token)

    # Generate the JSON-RPC request
    {:ok, payload, request_id} = DeribitRPC.generate_request(method, unsubscribe_params)

    # Track the request in state
    state = DeribitRPC.track_request(state, request_id, method, unsubscribe_params)

    # Emit telemetry for unsubscribe request
    :telemetry.execute(
      [:deribit_ex, :adapter, :unsubscribe, :request],
      %{system_time: System.system_time()},
      %{channels: channels, method: method}
    )

    {:ok, Jason.encode!(payload), state}
  end

  @doc """
  Handles unsubscribe response from Deribit.

  Updates the state to remove the unsubscribed channels.
  """
  @spec handle_unsubscribe_response(map(), map()) :: {:ok, map()} | {:error, map(), map()}
  def handle_unsubscribe_response(%{"result" => %{"unsubscribed" => channels}}, state) do
    subscriptions = Map.get(state, :subscriptions, %{})

    # Remove the unsubscribed channels from our state
    updated_subscriptions =
      Enum.reduce(channels, subscriptions, fn channel, acc ->
        Map.delete(acc, channel)
      end)

    # Update state with modified subscriptions
    state = Map.put(state, :subscriptions, updated_subscriptions)

    # Emit telemetry for successful unsubscribe
    :telemetry.execute(
      [:deribit_ex, :adapter, :unsubscribe, :success],
      %{system_time: System.system_time()},
      %{channels: channels, remaining_subscriptions: map_size(updated_subscriptions)}
    )

    {:ok, state}
  end

  def handle_unsubscribe_response(%{"error" => error}, state) do
    # Emit telemetry for unsubscribe failure
    :telemetry.execute(
      [:deribit_ex, :adapter, :unsubscribe, :failure],
      %{system_time: System.system_time()},
      %{error: error}
    )

    {:error, error, state}
  end

  def handle_unsubscribe_response(_other, state), do: {:ok, state}

  @doc """
  Generates data for the unsubscribe_all operation.

  This function prepares the JSON-RPC request for the public/unsubscribe_all
  endpoint, which stops all active subscriptions.

  ## Parameters
  - `params` - Parameters (unused but kept for consistency)
  - `state` - The current adapter state

  ## Returns
  - `{:ok, encoded_request, updated_state}` - The JSON request and updated state
  """
  @spec generate_unsubscribe_all_data(map(), map()) :: {:ok, String.t(), map()}
  def generate_unsubscribe_all_data(_params, state) do
    # No parameters needed for unsubscribe_all
    unsubscribe_params = %{}

    # Generate the JSON-RPC request
    {:ok, payload, request_id} =
      DeribitRPC.generate_request("public/unsubscribe_all", unsubscribe_params)

    # Track the request in state
    state =
      DeribitRPC.track_request(state, request_id, "public/unsubscribe_all", unsubscribe_params)

    # Emit telemetry for unsubscribe_all request
    :telemetry.execute(
      [:deribit_ex, :adapter, :unsubscribe_all, :request],
      %{system_time: System.system_time()},
      %{subscription_count: map_size(Map.get(state, :subscriptions, %{}))}
    )

    {:ok, Jason.encode!(payload), state}
  end

  @doc """
  Handles unsubscribe_all response from Deribit.

  Updates the state to clear all subscriptions.
  """
  @spec handle_unsubscribe_all_response(map(), map()) :: {:ok, map()} | {:error, map(), map()}
  def handle_unsubscribe_all_response(%{"result" => "ok"}, state) do
    # Get the current subscription count for telemetry
    subscription_count = map_size(Map.get(state, :subscriptions, %{}))

    # Clear all subscriptions
    state = Map.put(state, :subscriptions, %{})

    # Emit telemetry for successful unsubscribe_all
    :telemetry.execute(
      [:deribit_ex, :adapter, :unsubscribe_all, :success],
      %{system_time: System.system_time()},
      %{cleared_subscription_count: subscription_count}
    )

    {:ok, state}
  end

  def handle_unsubscribe_all_response(%{"error" => error}, state) do
    # Emit telemetry for unsubscribe_all failure
    :telemetry.execute(
      [:deribit_ex, :adapter, :unsubscribe_all, :failure],
      %{system_time: System.system_time()},
      %{error: error}
    )

    {:error, error, state}
  end

  def handle_unsubscribe_all_response(_other, state), do: {:ok, state}

  @doc """
  Handles the connection established event.

  Executes telemetry events for connection opening, updates the state, and
  handles reconnection logic by resetting reconnect_attempts counter.

  Leverages WebsockexNova's connection event callbacks to automatically
  trigger authentication and resubscription after reconnections.
  """
  @impl ConnectionHandler
  @spec handle_connect(map(), map()) :: {:ok, map()} | {:authenticate, map()}
  def handle_connect(transport, state) do
    # Emit telemetry event for connection opened
    :telemetry.execute(
      [:deribit_ex, :connection, :opened],
      %{system_time: System.system_time()},
      %{transport: transport, reconnect_attempts: Map.get(state, :reconnect_attempts, 0)}
    )

    # Check if this is a reconnection and we need to resubscribe
    was_reconnection = Map.get(state, :reconnect_attempts, 0) > 0
    subscriptions = Map.get(state, :subscriptions, %{})
    need_resubscribe = was_reconnection && map_size(subscriptions) > 0

    # Update state with connection info and reset reconnect counter
    state =
      state
      |> Map.put(:connected_at, DateTime.utc_now())
      |> Map.put(:transport, transport)
      |> Map.put(:reconnect_attempts, 0)
      |> Map.put(:need_resubscribe, need_resubscribe)

    # Check if this is a reconnection for an authenticated session
    if was_reconnection && Map.get(state, :auth_status) == :authenticated do
      # Log the reconnection with auth needed
      :telemetry.execute(
        [:deribit_ex, :connection, :reconnect_with_auth],
        %{system_time: System.system_time()},
        %{subscription_count: map_size(subscriptions)}
      )

      # WebsockexNova provides a special return value to trigger authentication
      # This eliminates our need to manually schedule refresh_auth messages
      # The framework will automatically call generate_auth_data
      {:authenticate, state}
    else
      # For initial connections or unauthenticated reconnections, just return ok
      {:ok, state}
    end
  end

  @doc """
  Handles termination of the adapter process.

  Executes telemetry events for connection closing and updates reconnection attempts.
  Handles graceful shutdowns vs. unexpected disconnections.

  Enhanced to better integrate with WebsockexNova's connection lifecycle management
  for intelligent reconnections with authentication preservation.
  """
  @spec terminate(any(), map()) ::
          {:reconnect, map()} | {:reconnect_and_authenticate, map()} | :ok
  def terminate(reason, state) do
    reconnect_attempts = Map.get(state, :reconnect_attempts, 0)
    max_reconnect_attempts = Map.get(state, :max_reconnect_attempts, 5)
    auth_status = Map.get(state, :auth_status, :unauthenticated)

    # Determine if we should reconnect
    {should_reconnect, new_reconnect_attempts} =
      determine_reconnect(reason, reconnect_attempts, max_reconnect_attempts)

    # Emit telemetry event for connection closed
    :telemetry.execute(
      [:deribit_ex, :connection, :closed],
      %{system_time: System.system_time()},
      %{
        reason: reason,
        duration: connection_duration(state),
        reconnect_attempts: reconnect_attempts,
        max_reconnect_attempts: max_reconnect_attempts,
        will_reconnect: should_reconnect,
        auth_status: auth_status
      }
    )

    # Update state with incremented reconnect counter
    updated_state = Map.put(state, :reconnect_attempts, new_reconnect_attempts)

    # Determine the appropriate return value based on auth status and reconnect decision
    cond do
      # No reconnection needed
      not should_reconnect ->
        :ok

      # Special case: Token expired or auth related errors should trigger reconnect with authentication
      # WebsockexNova will handle the reconnect and then immediately authenticate
      auth_status == :authenticated &&
          (is_tuple(reason) && elem(reason, 0) == :auth_error) ->
        :telemetry.execute(
          [:deribit_ex, :connection, :auth_error_reconnect],
          %{system_time: System.system_time()},
          %{reason: reason}
        )

        {:reconnect_and_authenticate, updated_state}

      # Normal reconnection
      true ->
        {:reconnect, updated_state}
    end
  end

  # Determine if we should reconnect based on reason and attempts
  defp determine_reconnect(reason, reconnect_attempts, max_reconnect_attempts) do
    case reason do
      # Normal closure - don't reconnect
      :normal ->
        {false, reconnect_attempts}

      :shutdown ->
        {false, reconnect_attempts}

      {:shutdown, _} ->
        {false, reconnect_attempts}

      # Authentication failure - only retry a limited number of times
      {:auth_error, _} ->
        new_attempts = reconnect_attempts + 1
        {new_attempts <= max_reconnect_attempts, new_attempts}

      # Network error - retry with backoff
      _ ->
        new_attempts = reconnect_attempts + 1
        {new_attempts <= max_reconnect_attempts, new_attempts}
    end
  end

  # Calculate the duration of the connection in milliseconds
  defp connection_duration(state) do
    case Map.get(state, :connected_at) do
      nil ->
        0

      connected_at ->
        DateTime.diff(DateTime.utc_now(), connected_at, :millisecond)
    end
  end
end
