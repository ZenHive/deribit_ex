defmodule DeribitEx.DeribitClient do
  @moduledoc """
  User-friendly client interface for interacting with the Deribit WebSocket API.

  This module provides simplified methods for:
  - Connecting and disconnecting
  - Authentication (public/auth, token exchange, token forking, and logout)
  - Utility endpoints (get_time, hello, status, test)
  - Session management (heartbeat, cancel on disconnect)
  - Subscription management for various Deribit channels

  ## Public Utility Endpoints
  ```elixir
  # Sync clocks with the server
  {:ok, timestamp} = DeribitClient.get_time(conn)

  # Introduce the client to the server
  {:ok, server_info} = DeribitClient.hello(conn, "my_bot", "1.0.0")

  # Check system status
  {:ok, status} = DeribitClient.status(conn)

  # Simple connectivity test
  {:ok, result} = DeribitClient.test(conn, "echo_me")
  ```

  ## Authentication
  ```elixir
  # Authenticate with credentials from environment variables
  {:ok, conn} = DeribitClient.authenticate(conn)

  # Exchange token for a different subaccount
  {:ok, _} = DeribitClient.exchange_token(conn, refresh_token, subject_id)

  # Create a named session
  {:ok, _} = DeribitClient.fork_token(conn, refresh_token, "analytics_session")

  # Logout
  {:ok, conn} = DeribitClient.logout(conn)
  ```

  ## Subscriptions
  ```elixir
  # Subscribe to trades for BTC-PERPETUAL
  {:ok, sub_id} = DeribitClient.subscribe_to_trades(conn, "BTC-PERPETUAL")

  # Subscribe to orderbook with depth=10
  {:ok, sub_id} = DeribitClient.subscribe_to_orderbook(conn, "BTC-PERPETUAL", "100ms", 10)
  ```
  """

  alias DeribitEx.DeribitAdapter
  alias DeribitEx.DeribitRPC
  alias DeribitEx.TimeSyncService
  alias DeribitEx.TimeSyncSupervisor
  alias WebsockexNova.Client

  @dialyzer {:nowarn_function,
             [
               authenticate: 3,
               exchange_token: 3,
               fork_token: 3,
               logout: 2,
               subscribe_to_trades: 4,
               subscribe_to_ticker: 4,
               subscribe_to_orderbook: 5,
               subscribe_to_user_orders: 4,
               subscribe_to_user_trades: 4,
               unsubscribe: 3,
               unsubscribe_all: 2,
               unsubscribe_private: 3,
               json_rpc: 4,
               disconnect: 2,
               get_time: 2,
               hello: 3,
               status: 2,
               test: 3,
               set_heartbeat: 3,
               disable_heartbeat: 2,
               enable_cancel_on_disconnect: 3,
               disable_cancel_on_disconnect: 3,
               get_cancel_on_disconnect: 2,
               initialize: 2,
               connect: 1,
               current_server_time: 1
             ]}

  # Default client options that can be overridden by user
  @default_opts %{}

  @doc """
  Connect to the Deribit WebSocket API.

  Uses environment-specific endpoints (test.deribit.com for dev/test,
  www.deribit.com for production) unless overridden.

  ## Options
  All WebsockexNova.Client options are supported, plus:
  - `:host` - Override the default host (optional)
  - `:callback_pid` - Process to receive WebSocket events (optional)
  - `:auth_refresh_threshold` - Seconds before token expiration to refresh (defaults to 180s)
    - Deribit tokens usually last 900 seconds (15 minutes)
    - Recommended refresh threshold is 180-300 seconds before expiration
    - Can also be set via DERIBIT_AUTH_REFRESH_THRESHOLD environment variable
    - Valid range: 1-899 seconds
    - Smaller values risk token expiration during high latency periods
    - Larger values cause more frequent token refreshes
    - Value of 180s balances reliability with refresh frequency
  - `:rate_limit_mode` - Rate limiting strategy (defaults to :normal)
    - `:cautious` - Strict limits to avoid 429s completely (60 req/sec)
    - `:normal` - Balanced approach (120 req/sec)
    - `:aggressive` - Higher throughput (200 req/sec), might get occasional 429s
    - Can also be set via DERIBIT_RATE_LIMIT_MODE environment variable

  ## Rate Limiting Behavior
  The connection uses a custom adaptive rate limiter that:
  - Adjusts rate limits dynamically based on Deribit API responses
  - Implements exponential backoff when 429 responses are received
  - Prioritizes critical operations like order cancellation
  - Gradually recovers request rates after backoff periods
  - Emits detailed telemetry for monitoring rate limiting behavior

  ## Examples
      # Connect with default options
      {:ok, conn} = DeribitClient.connect()

      # Connect with custom host
      {:ok, conn} = DeribitClient.connect(%{host: "custom.deribit.com"})

      # Connect with callback process
      {:ok, conn} = DeribitClient.connect(%{callback_pid: self()})

      # Connect with custom auth refresh threshold (5 minutes)
      {:ok, conn} = DeribitClient.connect(%{auth_refresh_threshold: 300})

      # Connect with cautious rate limiting
      {:ok, conn} = DeribitClient.connect(%{rate_limit_mode: :cautious})
  """
  @spec connect(map()) :: {:ok, pid()} | {:error, any()}
  def connect(opts \\ %{}) when is_map(opts) do
    start_time = System.monotonic_time()

    # Extract or determine auth_refresh_threshold
    auth_refresh_threshold = get_auth_refresh_threshold(opts)

    # 1. Get adapter protocol defaults
    {:ok, adapter_defaults} = DeribitAdapter.connection_info(%{})

    # 2. Merge with app-level defaults
    merged = Map.merge(adapter_defaults, @default_opts)

    # 3. Apply user options (highest priority)
    merged_opts = Map.merge(merged, opts)

    # 4. Extract or determine rate_limit_mode
    rate_limit_mode = get_rate_limit_mode(opts)

    # 5. Ensure auth_refresh_threshold and rate_limit_mode are properly set if provided
    merged_opts =
      if is_nil(auth_refresh_threshold) do
        merged_opts
      else
        Map.put(merged_opts, :auth_refresh_threshold, auth_refresh_threshold)
      end

    # 6. Set rate limit mode if provided
    merged_opts =
      if is_nil(rate_limit_mode) do
        merged_opts
      else
        Map.put(merged_opts, :rate_limit_mode, rate_limit_mode)
      end

    # 7. Connect using the WebsockexNova client
    case Client.connect(DeribitAdapter, merged_opts) do
      {:ok, conn} = result ->
        # Emit telemetry event for successful connection
        :telemetry.execute(
          [:deribit_ex, :client, :connect, :success],
          %{duration: System.monotonic_time() - start_time},
          %{
            host: Map.get(merged_opts, :host),
            auth_refresh_threshold: Map.get(merged_opts, :auth_refresh_threshold)
          }
        )

        # Start time sync service if enabled in config
        time_sync_config = Application.get_env(:deribit_ex, :websocket, [])[:time_sync] || []
        auto_sync = Keyword.get(time_sync_config, :auto_sync_on_connect, true)
        time_sync_enabled = Keyword.get(time_sync_config, :enabled, true)

        if time_sync_enabled && auto_sync do
          sync_interval = Keyword.get(time_sync_config, :sync_interval, 300_000)

          # Start time sync service
          # Extract client_pid from conn if it's not already a pid
          client_pid = if is_pid(conn), do: conn, else: conn.transport_pid

          {:ok, _sync_pid} =
            TimeSyncSupervisor.start_service(client_pid,
              sync_interval: sync_interval
            )

          # Log time sync service start
          :telemetry.execute(
            [:deribit_ex, :time_sync, :start],
            %{system_time: System.system_time()},
            %{client_pid: conn, sync_interval: sync_interval}
          )
        end

        result

      {:error, reason} = error ->
        # Emit telemetry event for connection failure
        :telemetry.execute(
          [:deribit_ex, :client, :connect, :failure],
          %{duration: System.monotonic_time() - start_time},
          %{reason: reason, host: Map.get(merged_opts, :host)}
        )

        error
    end
  end

  # Helper to extract and validate auth_refresh_threshold from options
  defp get_auth_refresh_threshold(opts) do
    # Read auth_refresh_threshold from different sources with different priorities:
    # 1. Function call options (highest priority)
    # 2. Environment variable
    # 3. Application configuration
    # 4. Default value (lowest priority)

    # Try function options first
    from_opts = get_threshold_from_opts(opts)

    # If not valid, try environment variable
    from_env = if is_nil(from_opts), do: get_threshold_from_env()

    # If not valid, try application config
    from_config =
      if is_nil(from_opts) && is_nil(from_env),
        do: get_threshold_from_config()

    # Use the first valid value found or default to 180
    from_opts || from_env || from_config || 180
  end

  # Helper to get the configured client name
  defp get_client_name(opts) do
    # Check sources in order of precedence:
    # 1. Function options
    # 2. Environment variable
    # 3. Application config
    # 4. Default value

    # From options
    name_from_opts = Map.get(opts, :client_name)

    # From environment variable
    name_from_env =
      if is_nil(name_from_opts),
        do: System.get_env("DERIBIT_CLIENT_NAME")

    # From application config
    name_from_config =
      if is_nil(name_from_opts) && is_nil(name_from_env),
        do: Application.get_env(:deribit_ex, :websocket, [])[:client_name]

    # Use the first valid value or default
    name_from_opts || name_from_env || name_from_config || "market_maker"
  end

  # Helper to get the configured client version
  defp get_client_version(opts) do
    # Check sources in order of precedence:
    # 1. Function options
    # 2. Environment variable
    # 3. Application config
    # 4. Default value

    # From options
    version_from_opts = Map.get(opts, :client_version)

    # From environment variable
    version_from_env =
      if is_nil(version_from_opts),
        do: System.get_env("DERIBIT_CLIENT_VERSION")

    # From application config
    version_from_config =
      if is_nil(version_from_opts) && is_nil(version_from_env),
        do: Application.get_env(:deribit_ex, :websocket, [])[:client_version]

    # Use the first valid value or default
    version_from_opts || version_from_env || version_from_config || "1.0.0"
  end

  # Get threshold from function options
  defp get_threshold_from_opts(opts) do
    case Map.get(opts, :auth_refresh_threshold) do
      nil ->
        nil

      val when is_integer(val) and val > 0 and val < 900 ->
        val

      invalid ->
        # Log warning about invalid value
        :telemetry.execute(
          [:deribit_ex, :client, :invalid_auth_refresh],
          %{system_time: System.system_time()},
          %{invalid_value: invalid}
        )

        nil
    end
  end

  # Get threshold from environment variable
  defp get_threshold_from_env do
    case System.get_env("DERIBIT_AUTH_REFRESH_THRESHOLD") do
      nil ->
        nil

      env_value ->
        case Integer.parse(env_value) do
          {num, ""} when num > 0 and num < 900 ->
            num

          _ ->
            # Log warning about invalid value
            :telemetry.execute(
              [:deribit_ex, :client, :invalid_env_auth_refresh],
              %{system_time: System.system_time()},
              %{invalid_value: env_value}
            )

            nil
        end
    end
  end

  # Get threshold from application config
  defp get_threshold_from_config do
    config_value = Application.get_env(:deribit_ex, :websocket, [])[:auth_refresh_threshold]

    case config_value do
      nil ->
        nil

      val when is_integer(val) and val > 0 and val < 900 ->
        val

      invalid ->
        # Log warning about invalid value
        :telemetry.execute(
          [:deribit_ex, :client, :invalid_config_auth_refresh],
          %{system_time: System.system_time()},
          %{invalid_value: invalid}
        )

        nil
    end
  end

  # Helper to extract and validate rate_limit_mode from options
  defp get_rate_limit_mode(opts) do
    # Valid rate limit modes
    valid_modes = [:cautious, :normal, :aggressive]

    # Try sources in order of precedence
    mode_from_opts = get_mode_from_opts(opts, valid_modes)
    mode_from_env = if is_nil(mode_from_opts), do: get_mode_from_env(valid_modes)

    mode_from_config =
      if is_nil(mode_from_opts) && is_nil(mode_from_env),
        do: get_mode_from_config(valid_modes)

    # Return the first valid value found or nil
    mode_from_opts || mode_from_env || mode_from_config || nil
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

  @doc """
  Authenticate with the Deribit API using client credentials.

  Uses credentials from the environment variables DERIBIT_CLIENT_ID and
  DERIBIT_CLIENT_SECRET if not provided.

  ## Options
  - `:api_key` - Deribit API key (optional if in environment)
  - `:secret` - Deribit API secret (optional if in environment)
  - `opts` - Additional options passed to the authentication request (e.g., timeout settings)

  ## Examples
      # Authenticate using environment variables
      {:ok, conn} = DeribitClient.authenticate(conn)

      # Authenticate with explicit credentials
      {:ok, conn} = DeribitClient.authenticate(conn, %{
        api_key: "your_api_key",
        secret: "your_secret"
      })
  """
  @spec authenticate(pid(), map(), map() | nil) :: {:ok, any()} | {:error, any()}
  def authenticate(conn, credentials \\ %{}, opts \\ nil) do
    start_time = System.monotonic_time()
    uses_env_credentials = credentials == %{}

    # If no credentials provided, get from connection directly
    actual_credentials =
      if credentials == %{} do
        case conn do
          %{adapter_state: %{credentials: creds}} when is_map(creds) and map_size(creds) > 0 ->
            creds

          %{connection_info: %{credentials: creds}} when is_map(creds) and map_size(creds) > 0 ->
            creds

          _ ->
            %{}
        end
      else
        credentials
      end

    case Client.authenticate(conn, actual_credentials, opts) do
      {:ok, new_conn, _result} ->
        # Emit telemetry event for successful authentication
        :telemetry.execute(
          [:deribit_ex, :client, :authenticate, :success],
          %{duration: System.monotonic_time() - start_time},
          %{uses_env_credentials: uses_env_credentials}
        )

        {:ok, new_conn}

      # Handle both error cases with the same telemetry
      {:error, reason} = error ->
        emit_auth_failure_telemetry(start_time, reason, uses_env_credentials)
        error

      {:error, reason, _new_conn} ->
        emit_auth_failure_telemetry(start_time, reason, uses_env_credentials)
        {:error, reason}
    end
  end

  # Private helper to emit telemetry for auth failures
  defp emit_auth_failure_telemetry(start_time, reason, uses_env_credentials) do
    :telemetry.execute(
      [:deribit_ex, :client, :authenticate, :failure],
      %{duration: System.monotonic_time() - start_time},
      %{reason: reason, uses_env_credentials: uses_env_credentials}
    )
  end

  @doc """
  Generate a new access token for switching between subaccounts.

  Uses the refresh token to create a new authentication session for a different subject ID.

  ## Parameters
  - `conn` - Connection process PID
  - `refresh_token` - Valid refresh token (optional, uses stored token if available)
  - `subject_id` - ID of the subaccount to switch to
  - `opts` - Additional options for the request (optional)

  ## Examples
      # Exchange token to switch to subaccount with ID 10
      {:ok, response} = DeribitClient.exchange_token(conn, "refresh_token_value", 10)

      # Exchange token using a stored refresh token
      {:ok, response} = DeribitClient.exchange_token(conn, nil, 10)
  """
  @spec exchange_token(pid(), String.t() | nil, integer() | String.t() | nil, map() | nil) ::
          {:ok, any()} | {:error, any()}
  def exchange_token(conn, refresh_token, subject_id, opts \\ nil) do
    start_time = System.monotonic_time()

    # Direct JSON-RPC call
    method = "public/exchange_token"

    exchange_params = %{
      "refresh_token" => refresh_token,
      "subject_id" => subject_id
    }

    case json_rpc(conn, method, exchange_params, opts) do
      {:ok, response} ->
        # Emit telemetry for successful token exchange
        :telemetry.execute(
          [:deribit_ex, :client, :exchange_token, :success],
          %{duration: System.monotonic_time() - start_time},
          %{subject_id: subject_id}
        )

        # The adapter will automatically handle the token update through handle_message
        {:ok, response}

      {:error, reason} = error ->
        # Emit telemetry for token exchange failure
        :telemetry.execute(
          [:deribit_ex, :client, :exchange_token, :failure],
          %{duration: System.monotonic_time() - start_time},
          %{subject_id: subject_id, reason: reason}
        )

        error
    end
  end

  @doc """
  Generate a token for a new named session.

  Uses the refresh token to create a new authentication session with the specified name.

  ## Parameters
  - `conn` - Connection process PID
  - `refresh_token` - Valid refresh token (optional, uses stored token if available)
  - `session_name` - Name for the new session
  - `opts` - Additional options for the request (optional)

  ## Examples
      # Fork token to create a new named session
      {:ok, response} = DeribitClient.fork_token(conn, "refresh_token_value", "trading_session")

      # Fork token using a stored refresh token
      {:ok, response} = DeribitClient.fork_token(conn, nil, "analytics_session")
  """
  @spec fork_token(pid(), String.t() | nil, String.t() | atom() | nil, map() | nil) ::
          {:ok, any()} | {:error, any()}
  def fork_token(conn, refresh_token, session_name, opts \\ nil) do
    start_time = System.monotonic_time()

    # Direct JSON-RPC call
    method = "public/fork_token"

    fork_params = %{
      "refresh_token" => refresh_token,
      "session_name" => session_name
    }

    case json_rpc(conn, method, fork_params, opts) do
      {:ok, response} ->
        # Emit telemetry for successful token fork
        :telemetry.execute(
          [:deribit_ex, :client, :fork_token, :success],
          %{duration: System.monotonic_time() - start_time},
          %{session_name: session_name}
        )

        # The adapter will automatically handle the token update through handle_message
        {:ok, response}

      {:error, reason} = error ->
        # Emit telemetry for token fork failure
        :telemetry.execute(
          [:deribit_ex, :client, :fork_token, :failure],
          %{duration: System.monotonic_time() - start_time},
          %{session_name: session_name, reason: reason}
        )

        error
    end
  end

  @doc """
  Logout and optionally invalidate tokens.

  Gracefully closes the session with the Deribit API and optionally
  invalidates all tokens created in the current session. This is important
  for secure session management.

  This function:
  1. Sends the private/logout RPC request
  2. Cleans up authentication state in the adapter
  3. Automatically closes the WebSocket connection afterwards

  The invalidate_token parameter determines whether to invalidate all tokens:
  - When set to true (default), all access and refresh tokens become invalid
  - When set to false, tokens remain valid but the current session ends

  ## Parameters
  - `conn` - Connection process PID
  - `invalidate_token` - Whether to invalidate all tokens (default: true)
  - `opts` - Additional options for the request (optional):
    - `:timeout` - Request timeout in milliseconds (default: 10000)

  ## Returns
  - `{:ok, conn}` - On successful logout, even though the connection is closed
  - `{:error, reason}` - If the logout request fails

  ## Notes
  - The WebSocket connection is automatically closed after logout
  - The adapter state is updated to remove authentication data
  - In high-latency environments, the request may timeout

  ## Examples
      # Logout and invalidate all tokens
      {:ok, conn} = DeribitClient.logout(conn)

      # Logout without invalidating tokens
      {:ok, conn} = DeribitClient.logout(conn, false)
      
      # Logout with custom timeout
      {:ok, conn} = DeribitClient.logout(conn, true, %{timeout: 30000})
  """
  @spec logout(pid(), boolean(), map() | nil) :: {:ok, pid()} | {:error, any()}
  def logout(conn, invalidate_token \\ true, opts \\ nil) do
    start_time = System.monotonic_time()

    # Direct JSON-RPC call
    method = "private/logout"
    logout_params = %{"invalidate_token" => invalidate_token}

    # Apply default timeout if not provided
    opts = if opts, do: opts, else: %{}
    opts = if Map.has_key?(opts, :timeout), do: opts, else: Map.put(opts, :timeout, 10_000)

    case json_rpc(conn, method, logout_params, opts) do
      {:ok, _response} ->
        # Emit telemetry for successful logout
        :telemetry.execute(
          [:deribit_ex, :client, :logout, :success],
          %{duration: System.monotonic_time() - start_time},
          %{invalidate_token: invalidate_token}
        )

        # The adapter will handle cleaning up authentication state via handle_message
        # Close the connection after logout
        disconnect(conn)

        # Return {:ok, conn} for consistency with other functions
        {:ok, conn}

      {:error, reason} = error ->
        # Emit telemetry for logout failure
        :telemetry.execute(
          [:deribit_ex, :client, :logout, :failure],
          %{duration: System.monotonic_time() - start_time},
          %{invalidate_token: invalidate_token, reason: reason}
        )

        error
    end
  end

  # Private helper function for tracking subscriptions with telemetry
  defp subscribe_with_telemetry(conn, channel, opts, type) do
    start_time = System.monotonic_time()

    case Client.subscribe(conn, channel, opts) do
      {:ok, subscription} ->
        # Emit telemetry event for successful subscription
        :telemetry.execute(
          [:deribit_ex, :client, :subscribe, :success],
          %{duration: System.monotonic_time() - start_time},
          %{channel: channel, type: type}
        )

        {:ok, subscription}

      {:error, reason} = error ->
        # Emit telemetry event for subscription failure
        :telemetry.execute(
          [:deribit_ex, :client, :subscribe, :failure],
          %{duration: System.monotonic_time() - start_time},
          %{channel: channel, type: type, reason: reason}
        )

        error
    end
  end

  # Private helper function for tracking unsubscriptions with telemetry
  defp unsubscribe_with_telemetry(conn, channels, opts, type) do
    start_time = System.monotonic_time()

    # Ensure channels is a list
    channels = if is_list(channels), do: channels, else: [channels]

    # Create unsubscribe parameters
    unsubscribe_params = %{"channels" => channels}

    # Determine appropriate method (public/unsubscribe or private/unsubscribe)
    needs_auth =
      Enum.any?(channels, fn channel ->
        String.contains?(channel, ".raw") ||
          String.contains?(channel, "private") ||
          String.starts_with?(channel, "user.")
      end)

    method = if needs_auth, do: "private/unsubscribe", else: "public/unsubscribe"

    # Call JSON-RPC for unsubscribe
    case json_rpc(conn, method, unsubscribe_params, opts) do
      {:ok, response} ->
        # Emit telemetry event for successful unsubscription
        :telemetry.execute(
          [:deribit_ex, :client, :unsubscribe, :success],
          %{duration: System.monotonic_time() - start_time},
          %{channels: channels, type: type}
        )

        # Parse the response
        case parse_response(response) do
          {:ok, result} -> {:ok, result}
          error -> error
        end

      {:error, reason} = error ->
        # Emit telemetry event for unsubscription failure
        :telemetry.execute(
          [:deribit_ex, :client, :unsubscribe, :failure],
          %{duration: System.monotonic_time() - start_time},
          %{channels: channels, type: type, reason: reason}
        )

        error
    end
  end

  @doc """
  Subscribe to a Deribit trades channel for a specific instrument.

  ## Parameters
  - `conn` - Connection process PID
  - `instrument` - Instrument name (e.g., "BTC-PERPETUAL")
  - `interval` - Update interval (optional, e.g., "100ms", "raw")

  ## Example
      {:ok, sub_id} = DeribitClient.subscribe_to_trades(conn, "BTC-PERPETUAL", "100ms")
  """
  @spec subscribe_to_trades(pid(), String.t(), String.t(), map() | nil) ::
          {:ok, any()} | {:error, any()}
  def subscribe_to_trades(conn, instrument, interval \\ "raw", opts \\ nil) do
    channel = "trades.#{instrument}.#{interval}"
    subscribe_with_telemetry(conn, channel, opts, :trades)
  end

  @doc """
  Subscribe to a Deribit ticker channel for a specific instrument.

  ## Parameters
  - `conn` - Connection process PID
  - `instrument` - Instrument name (e.g., "BTC-PERPETUAL")
  - `interval` - Update interval (optional, e.g., "100ms", "raw")

  ## Example
      {:ok, sub_id} = DeribitClient.subscribe_to_ticker(conn, "BTC-PERPETUAL", "100ms")
  """
  @spec subscribe_to_ticker(pid(), String.t(), String.t(), map() | nil) ::
          {:ok, any()} | {:error, any()}
  def subscribe_to_ticker(conn, instrument, interval \\ "raw", opts \\ nil) do
    channel = "ticker.#{instrument}.#{interval}"
    subscribe_with_telemetry(conn, channel, opts, :ticker)
  end

  @doc """
  Subscribe to a Deribit orderbook channel for a specific instrument.

  ## Parameters
  - `conn` - Connection process PID
  - `instrument` - Instrument name (e.g., "BTC-PERPETUAL")
  - `interval` - Update interval (optional, e.g., "100ms", "raw")
  - `depth` - Orderbook depth (optional, default is full orderbook)

  ## Example
      {:ok, sub_id} = DeribitClient.subscribe_to_orderbook(conn, "BTC-PERPETUAL", "100ms", 10)
  """
  @spec subscribe_to_orderbook(pid(), String.t(), String.t(), integer() | nil, map() | nil) ::
          {:ok, any()} | {:error, any()}
  def subscribe_to_orderbook(conn, instrument, interval \\ "raw", depth \\ nil, opts \\ nil) do
    channel =
      if depth do
        "book.#{instrument}.#{interval}.#{depth}"
      else
        "book.#{instrument}.#{interval}"
      end

    subscribe_with_telemetry(conn, channel, opts, :orderbook)
  end

  @doc """
  Subscribe to user's orders for a specific instrument.
  Requires authentication.

  ## Parameters
  - `conn` - Connection process PID
  - `instrument` - Instrument name (e.g., "BTC-PERPETUAL")
  - `interval` - Update interval (optional, defaults to "raw")

  ## Example
      {:ok, sub_id} = DeribitClient.subscribe_to_user_orders(conn, "BTC-PERPETUAL")
  """
  @spec subscribe_to_user_orders(pid(), String.t(), String.t(), map() | nil) ::
          {:ok, any()} | {:error, any()}
  def subscribe_to_user_orders(conn, instrument, interval \\ "raw", opts \\ nil) do
    channel = "user.orders.#{instrument}.#{interval}"
    subscribe_with_telemetry(conn, channel, opts, :user_orders)
  end

  @doc """
  Subscribe to user's trades for a specific instrument.
  Requires authentication.

  ## Parameters
  - `conn` - Connection process PID
  - `instrument` - Instrument name (e.g., "BTC-PERPETUAL")
  - `interval` - Update interval (optional, defaults to "raw")

  ## Example
      {:ok, sub_id} = DeribitClient.subscribe_to_user_trades(conn, "BTC-PERPETUAL")
  """
  @spec subscribe_to_user_trades(pid(), String.t(), String.t(), map() | nil) ::
          {:ok, any()} | {:error, any()}
  def subscribe_to_user_trades(conn, instrument, interval \\ "raw", opts \\ nil) do
    channel = "user.trades.#{instrument}.#{interval}"
    subscribe_with_telemetry(conn, channel, opts, :user_trades)
  end

  @doc """
  Send a custom JSON-RPC request to the Deribit API.

  ## Parameters
  - `conn` - Connection process PID
  - `method` - RPC method name (e.g., "public/get_instruments")
  - `params` - Method parameters (map)
  - `opts` - Optional request options

  ## Examples
      # Get available instruments for BTC
      {:ok, response} = DeribitClient.json_rpc(conn, "public/get_instruments", %{
        currency: "BTC",
        kind: "future"
      })
  """
  @spec json_rpc(pid(), String.t(), map(), map() | nil) :: {:ok, any()} | {:error, any()}
  def json_rpc(conn, method, params, opts \\ nil) do
    start_time = System.monotonic_time()

    # Use DeribitRPC to generate a standardized request
    {:ok, payload, request_id} = DeribitRPC.generate_request(method, params)

    case Client.send_json(conn, payload, opts) do
      {:ok, response} ->
        # Emit telemetry event for successful RPC call
        :telemetry.execute(
          [:deribit_ex, :client, :json_rpc, :success],
          %{duration: System.monotonic_time() - start_time},
          %{method: method, request_id: request_id}
        )

        # For backward compatibility with existing tests, just return the raw response
        # The parsing is handled by higher-level functions
        {:ok, response}

      {:error, reason} = error ->
        # Emit telemetry event for RPC call failure
        :telemetry.execute(
          [:deribit_ex, :client, :json_rpc, :failure],
          %{duration: System.monotonic_time() - start_time},
          %{method: method, request_id: request_id, reason: reason}
        )

        error
    end
  end

  @doc """
  Parse a JSON-RPC response and extract the result or error.

  This helper function provides consistent handling of JSON-RPC responses,
  extracting the relevant result or error from the response envelope.

  ## Parameters
  - `response` - The raw response from a JSON-RPC call

  ## Returns
  - `{:ok, result}` - On successful responses
  - `{:error, error}` - On error responses

  ## Examples
      iex> DeribitClient.parse_response(%{"jsonrpc" => "2.0", "id" => 1, "result" => 123})
      {:ok, 123}

      iex> DeribitClient.parse_response(%{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => 10001, "message" => "Error"}})
      {:error, %{"code" => 10001, "message" => "Error"}}
  """
  @spec parse_response(map()) :: {:ok, any()} | {:error, any()}
  def parse_response(response) do
    DeribitRPC.parse_response(response)
  end

  # @doc """
  # Get the server time from Deribit.

  # Used to sync client and server clocks. The returned value is
  # a Unix timestamp in milliseconds.

  # ## Parameters
  # - `conn` - Connection process PID
  # - `opts` - Optional request options

  # ## Returns
  # - `{:ok, timestamp}` - The server time as Unix timestamp in milliseconds
  # - `{:error, reason}` - If the request fails

  # ## Examples
  #     # Get the current server time
  #     {:ok, server_time} = DeribitClient.get_time(conn)

  #     # Convert to DateTime
  #     datetime = DateTime.from_unix!(div(server_time, 1000))
  # """
  # # Private helper to process API responses with consistent handling of maps and strings
  # # and emitting appropriate telemetry events
  defp process_response(response, operation, start_time, metadata) do
    case response do
      {:ok, response_data} when is_map(response_data) ->
        result = parse_response(response_data)

        # Emit telemetry for the specific operation
        :telemetry.execute(
          [:deribit_ex, :client, operation, :success],
          %{duration: System.monotonic_time() - start_time},
          metadata
        )

        result

      {:ok, response_data} when is_binary(response_data) ->
        # Parse the JSON string into a map
        case Jason.decode(response_data) do
          {:ok, decoded} ->
            result = parse_response(decoded)

            # Emit telemetry for the specific operation
            :telemetry.execute(
              [:deribit_ex, :client, operation, :success],
              %{duration: System.monotonic_time() - start_time},
              metadata
            )

            result

          {:error, _} = decode_error ->
            # Emit telemetry for JSON parsing failure
            :telemetry.execute(
              [:deribit_ex, :client, operation, :failure],
              %{duration: System.monotonic_time() - start_time},
              Map.put(metadata, :reason, :json_parse_error)
            )

            decode_error
        end

      {:error, reason} = error ->
        # Emit telemetry for the specific operation failure
        :telemetry.execute(
          [:deribit_ex, :client, operation, :failure],
          %{duration: System.monotonic_time() - start_time},
          Map.put(metadata, :reason, reason)
        )

        error
    end
  end

  @doc """
  Fetch Deribit's current server time (ms since epoch).

  ## Parameters
  - `conn` – the WebSocket client PID
  - `opts` – optional JSON-RPC options

  ## Returns
  - `{:ok, timestamp}` on success
  - `{:error, reason}` on failure
  """
  @spec get_time(pid(), map() | nil) :: {:ok, integer()} | {:error, any()}
  def get_time(conn, opts \\ nil) do
    start_time = System.monotonic_time()
    opts = opts || %{}
    result = json_rpc(conn, "public/get_time", %{}, opts)
    process_response(result, :get_time, start_time, %{})
  end

  @doc """
  Send a hello message to introduce the client to Deribit.

  Used to identify the client to the server and establish the initial session.

  ## Parameters
  - `conn` - Connection process PID
  - `client_name` - The name of the client (defaults to "market_maker")
  - `client_version` - The version of the client (defaults to "1.0.0")
  - `opts` - Optional request options

  ## Returns
  - `{:ok, result}` - Success response with server version
  - `{:error, reason}` - If the request fails

  ## Examples
      # Send hello with default client info
      {:ok, server_info} = DeribitClient.hello(conn)

      # Send hello with custom client info
      {:ok, server_info} = DeribitClient.hello(conn, "my_trading_bot", "2.1.0")
  """
  @spec hello(pid(), String.t() | nil, String.t() | nil, map() | nil) ::
          {:ok, any()} | {:error, any()}
  def hello(conn, client_name \\ nil, client_version \\ nil, opts \\ nil) do
    start_time = System.monotonic_time()
    opts = opts || %{}

    # Get client name and version from parameters, config, or defaults
    effective_client_name = client_name || get_client_name(opts)
    effective_client_version = client_version || get_client_version(opts)

    params = %{
      "client_name" => effective_client_name,
      "client_version" => effective_client_version
    }

    result = json_rpc(conn, "public/hello", params, opts)
    metadata = %{client_name: effective_client_name, client_version: effective_client_version}
    process_response(result, :hello, start_time, metadata)
  end

  @doc """
  Get the system status from Deribit.

  Returns information about the status of the API, including any service
  disruptions, scheduled maintenance, or important announcements.

  ## Parameters
  - `conn` - Connection process PID
  - `opts` - Optional request options

  ## Returns
  - `{:ok, status}` - The system status information
  - `{:error, reason}` - If the request fails

  ## Examples
      # Check if the system is operational
      {:ok, status} = DeribitClient.status(conn)

      # Handle possible maintenance mode
      case DeribitClient.status(conn) do
        {:ok, %{"status" => "ok"}} -> # System is operational
        {:ok, %{"status" => "maintenance"}} -> # System is in maintenance mode
        {:error, reason} -> # Request failed
      end
  """
  @spec status(pid(), map() | nil) :: {:ok, map()} | {:error, any()}
  def status(conn, opts \\ nil) do
    start_time = System.monotonic_time()
    opts = opts || %{}
    result = json_rpc(conn, "public/status", %{}, opts)
    process_response(result, :status, start_time, %{})
  end

  @doc """
  Send a test request to Deribit.

  This endpoint is primarily used to respond to test_request messages sent by the server
  as part of the heartbeat mechanism. It can also be used as a simple connectivity check.

  ## Parameters
  - `conn` - Connection process PID
  - `expected_result` - The expected result to be echoed back (optional)
  - `opts` - Optional request options

  ## Returns
  - `{:ok, result}` - Success response, echoing back the expected_result if provided
  - `{:error, reason}` - If the request fails

  ## Examples
      # Simple connectivity test
      {:ok, _} = DeribitClient.test(conn)

      # Test with expected result echo
      {:ok, "hello"} = DeribitClient.test(conn, "hello")
  """
  @spec test(pid(), String.t() | nil, map() | nil) :: {:ok, any()} | {:error, any()}
  def test(conn, expected_result \\ nil, opts \\ nil) do
    start_time = System.monotonic_time()
    opts = opts || %{}
    params = if expected_result, do: %{"expected_result" => expected_result}, else: %{}
    result = json_rpc(conn, "public/test", params, opts)
    process_response(result, :test, start_time, %{expected_result: expected_result})
  end

  @doc """
  Close the WebSocket connection to the Deribit API.

  ## Parameters
  - `conn` - Connection process PID
  - `reason` - Reason for disconnection (optional)

  ## Examples
      # Close with normal reason
      :ok = DeribitClient.disconnect(conn)

      # Close with custom reason
      :ok = DeribitClient.disconnect(conn, :shutdown)
  """
  @spec disconnect(pid(), any()) :: :ok
  def disconnect(conn, reason \\ :normal) do
    # Emit telemetry event for disconnection
    :telemetry.execute(
      [:deribit_ex, :client, :disconnect],
      %{system_time: System.system_time()},
      %{reason: reason}
    )

    # Check if there's a time sync service for this connection
    # We need to extract the client pid from the conn structure if it's not already a pid
    client_pid = if is_pid(conn), do: conn, else: conn.transport_pid
    # Ensure we're passing a pid to service_name/1
    service_name = TimeSyncSupervisor.service_name(client_pid)

    if Process.whereis(service_name) do
      # Stop the time sync service
      DynamicSupervisor.terminate_child(
        TimeSyncSupervisor,
        Process.whereis(service_name)
      )

      # Emit telemetry for time sync service stop
      :telemetry.execute(
        [:deribit_ex, :time_sync, :stop],
        %{system_time: System.system_time()},
        %{client_pid: conn, reason: reason}
      )
    end

    # Note: WebsockexNova.Client.close/1 doesn't accept a reason parameter
    # We log the reason via telemetry but can only use the basic close
    Client.close(conn)
  end

  @doc """
  Enable heartbeat messages from the Deribit server.

  Heartbeats are used to detect stale connections. When enabled, the server will send
  test_request messages periodically, and the adapter will automatically respond to them.

  ## Parameters
  - `conn` - Connection process PID
  - `interval` - Heartbeat interval in seconds (min: 10, defaults to 30)
  - `opts` - Optional request options

  ## Returns
  - `{:ok, "ok"}` - Success response indicating heartbeat is enabled
  - `{:error, reason}` - If the request fails

  ## Examples
      # Enable heartbeat with default 30 second interval
      {:ok, _} = DeribitClient.set_heartbeat(conn)

      # Enable heartbeat with custom interval
      {:ok, _} = DeribitClient.set_heartbeat(conn, 15)
  """
  @spec set_heartbeat(pid(), pos_integer(), map() | nil) :: {:ok, String.t()} | {:error, any()}
  def set_heartbeat(conn, interval \\ 30, opts \\ nil) do
    start_time = System.monotonic_time()
    opts = opts || %{}

    # Ensure interval is at least 10 seconds (Deribit minimum)
    interval = max(interval, 10)

    params = %{
      "interval" => interval
    }

    result = json_rpc(conn, "public/set_heartbeat", params, opts)
    metadata = %{interval: interval}
    process_response(result, :set_heartbeat, start_time, metadata)
  end

  @doc """
  Disable heartbeat messages from the Deribit server.

  ## Parameters
  - `conn` - Connection process PID
  - `opts` - Optional request options

  ## Returns
  - `{:ok, "ok"}` - Success response indicating heartbeat is disabled
  - `{:error, reason}` - If the request fails

  ## Examples
      # Disable heartbeat
      {:ok, _} = DeribitClient.disable_heartbeat(conn)
  """
  @spec disable_heartbeat(pid(), map() | nil) :: {:ok, String.t()} | {:error, any()}
  def disable_heartbeat(conn, opts \\ nil) do
    start_time = System.monotonic_time()
    opts = opts || %{}

    result = json_rpc(conn, "public/disable_heartbeat", %{}, opts)
    process_response(result, :disable_heartbeat, start_time, %{})
  end

  @doc """
  Enable Cancel on Disconnect (COD) for the current session.

  When enabled, all orders created during the connection will be automatically
  cancelled if the connection is closed or interrupted. This is a safety feature
  to prevent orphaned orders in case of connection issues.

  ## Parameters
  - `conn` - Connection process PID
  - `scope` - Scope of the COD setting ("connection" or "account", defaults to "connection")
  - `opts` - Optional request options

  ## Returns
  - `{:ok, "ok"}` - Success response indicating COD is enabled
  - `{:error, reason}` - If the request fails

  ## Examples
      # Enable COD for current connection only
      {:ok, _} = DeribitClient.enable_cancel_on_disconnect(conn)

      # Enable COD for the entire account
      {:ok, _} = DeribitClient.enable_cancel_on_disconnect(conn, "account")
  """
  @spec enable_cancel_on_disconnect(pid(), String.t(), map() | nil) ::
          {:ok, String.t()} | {:error, any()}
  def enable_cancel_on_disconnect(conn, scope \\ "connection", opts \\ nil) do
    start_time = System.monotonic_time()
    opts = opts || %{}

    # Validate scope parameter
    if scope not in ["connection", "account"] do
      raise "Invalid scope for cancel_on_disconnect: '#{scope}'. Must be 'connection' or 'account'."
    end

    params = %{
      "scope" => scope
    }

    result = json_rpc(conn, "private/enable_cancel_on_disconnect", params, opts)
    metadata = %{scope: scope}
    process_response(result, :enable_cod, start_time, metadata)
  end

  @doc """
  Disable Cancel on Disconnect (COD) for the specified scope.

  ## Parameters
  - `conn` - Connection process PID
  - `scope` - Scope of the COD setting ("connection" or "account", defaults to "connection")
  - `opts` - Optional request options

  ## Returns
  - `{:ok, "ok"}` - Success response indicating COD is disabled
  - `{:error, reason}` - If the request fails

  ## Examples
      # Disable COD for current connection
      {:ok, _} = DeribitClient.disable_cancel_on_disconnect(conn)

      # Disable COD for the entire account
      {:ok, _} = DeribitClient.disable_cancel_on_disconnect(conn, "account")
  """
  @spec disable_cancel_on_disconnect(pid(), String.t(), map() | nil) ::
          {:ok, String.t()} | {:error, any()}
  def disable_cancel_on_disconnect(conn, scope \\ "connection", opts \\ nil) do
    start_time = System.monotonic_time()
    opts = opts || %{}

    # Validate scope parameter
    if scope not in ["connection", "account"] do
      raise "Invalid scope for cancel_on_disconnect: '#{scope}'. Must be 'connection' or 'account'."
    end

    params = %{
      "scope" => scope
    }

    result = json_rpc(conn, "private/disable_cancel_on_disconnect", params, opts)
    metadata = %{scope: scope}
    process_response(result, :disable_cod, start_time, metadata)
  end

  @doc """
  Get the current Cancel on Disconnect (COD) configuration.

  ## Parameters
  - `conn` - Connection process PID
  - `opts` - Optional request options

  ## Returns
  - `{:ok, %{"scope" => scope, "enabled" => enabled}}` - The current COD configuration
  - `{:error, reason}` - If the request fails

  ## Examples
      # Check if COD is enabled for the connection
      {:ok, %{"enabled" => true, "scope" => "connection"}} = DeribitClient.get_cancel_on_disconnect(conn)
  """
  @spec get_cancel_on_disconnect(pid(), map() | nil) :: {:ok, map()} | {:error, any()}
  def get_cancel_on_disconnect(conn, opts \\ nil) do
    start_time = System.monotonic_time()
    opts = opts || %{}

    result = json_rpc(conn, "private/get_cancel_on_disconnect", %{}, opts)
    process_response(result, :get_cod, start_time, %{})
  end

  @doc """
  Initialize the Deribit connection with a bootstrap sequence.

  After connecting to Deribit via WebSocket, this function performs a bootstrap
  sequence to properly initialize the session:

  1. `/public/hello` to introduce client name & version
  2. `/public/get_time` to sync clocks
  3. `/public/status` to check account status
  4. `/public/set_heartbeat` to enable heartbeats (minimum 10s)
  5. `/private/enable_cancel_on_disconnect` with default scope for COD safety
     (requires authentication first)

  The adapter is also set up to automatically handle incoming `test_request`
  messages by responding with `/public/test`.

  ## Parameters
  - `conn` - Connection process PID
  - `opts` - Optional bootstrap configuration:
    - `:client_name` - Custom client name (defaults to "market_maker")
    - `:client_version` - Custom client version (defaults to "1.0.0")
    - `:heartbeat_interval` - Heartbeat interval in seconds (defaults to 30, minimum 10)
    - `:cod_scope` - Scope for cancel-on-disconnect (defaults to "connection")
    - `:authenticate` - Whether to authenticate before other steps (defaults to true)

  ## Returns
  - `{:ok, bootstrap_results}` - Success with a map of all bootstrap operation results
  - `{:error, step, reason}` - First failed operation with the reason

  ## Examples
      # Initialize with default settings
      {:ok, results} = DeribitClient.initialize(conn)

      # Custom initialization
      {:ok, results} = DeribitClient.initialize(conn, %{
        client_name: "trading_bot",
        client_version: "2.0.0",
        heartbeat_interval: 15,
        cod_scope: "account"
      })

      # Skip authentication
      {:ok, results} = DeribitClient.initialize(conn, %{authenticate: false})
  """
  @spec initialize(pid(), map() | nil) :: {:ok, map()} | {:error, atom(), any()}
  def initialize(conn, opts \\ %{}) do
    start_time = System.monotonic_time()
    opts = opts || %{}

    # Initialize with config and options
    config = initialize_config(opts)
    bootstrap_results = %{}

    # Emit telemetry for bootstrap start
    :telemetry.execute(
      [:deribit_ex, :client, :bootstrap, :start],
      %{system_time: System.system_time()},
      %{client_name: config.client_name, client_version: config.client_version}
    )

    # Perform the basic connection setup
    case perform_basic_setup(conn, config, bootstrap_results) do
      {:ok, updated_results} ->
        # Handle authentication if needed
        if config.should_authenticate do
          handle_authentication(conn, config, updated_results, start_time)
        else
          # Skip authentication and COD, report success
          emit_bootstrap_success(config, updated_results, start_time, authenticated: false)
          {:ok, updated_results}
        end

      {:error, step, reason, _results} ->
        # Report bootstrap failure
        emit_bootstrap_failure(step, reason, start_time)
        {:error, step, reason}
    end
  end

  # Initialize configuration from options and application config
  defp initialize_config(opts) do
    # Get the configuration defaults
    config_cod_enabled =
      Application.get_env(:deribit_ex, :websocket, [])[:cancel_on_disconnect][:enabled] || true

    config_cod_scope =
      Application.get_env(:deribit_ex, :websocket, [])[:cancel_on_disconnect][:scope] ||
        "connection"

    # Build config struct with all options
    %{
      client_name: get_client_name(opts),
      client_version: get_client_version(opts),
      # minimum 10 seconds
      heartbeat_interval: max(Map.get(opts, :heartbeat_interval, 30), 10),
      cod_scope: Map.get(opts, :cod_scope, config_cod_scope),
      cod_enabled: Map.get(opts, :cod_enabled, config_cod_enabled),
      should_authenticate: Map.get(opts, :authenticate, true),
      # Time synchronization options
      time_sync_enabled:
        Map.get(
          opts,
          :time_sync_enabled,
          Application.get_env(:deribit_ex, :websocket, [])[:time_sync][:enabled] || true
        )
    }
  end

  # Perform the basic connection setup steps
  defp perform_basic_setup(conn, config, bootstrap_results) do
    # Step 1: Hello
    with {:ok, hello_result} <- hello(conn, config.client_name, config.client_version),
         results = Map.put(bootstrap_results, :hello, hello_result),

         # Step 2: Get time and potentially initialize time sync service
         {:ok, time_result} <- get_time(conn),
         results = Map.put(results, :get_time, time_result),
         results = maybe_initialize_time_sync(conn, config, results),

         # Step 3: Status
         {:ok, status_result} <- status(conn),
         results = Map.put(results, :status, status_result),

         # Step 4: Set heartbeat
         {:ok, heartbeat_result} <- set_heartbeat(conn, config.heartbeat_interval) do
      # All steps succeeded
      {:ok, Map.put(results, :set_heartbeat, heartbeat_result)}
    else
      {:error, reason} = _error ->
        # Determine which step failed
        step = identify_failed_step(bootstrap_results)
        {:error, step, reason, bootstrap_results}
    end
  end

  # Initialize time sync service during bootstrap if enabled
  defp maybe_initialize_time_sync(conn, config, results) do
    if config.time_sync_enabled do
      # Check if there's already a time sync service running for this client
      # Extract the client pid from the conn structure if it's not already a pid
      client_pid = if is_pid(conn), do: conn, else: conn.transport_pid
      service_name = TimeSyncSupervisor.service_name(client_pid)

      if Process.whereis(service_name) do
        # Time sync service is already running
        results
        # Get time sync config

        # Start time sync service

        # Log time sync service start during initialization
      else
        time_sync_config = Application.get_env(:deribit_ex, :websocket, [])[:time_sync] || []
        sync_interval = Keyword.get(time_sync_config, :sync_interval, 300_000)

        # Make sure we're passing a pid
        client_pid = if is_pid(conn), do: conn, else: conn.transport_pid

        {:ok, sync_pid} =
          TimeSyncSupervisor.start_service(client_pid,
            sync_interval: sync_interval
          )

        :telemetry.execute(
          [:deribit_ex, :time_sync, :start],
          %{system_time: System.system_time()},
          %{client_pid: conn, sync_interval: sync_interval, during_bootstrap: true}
        )

        # Add the time sync service PID to results
        Map.put(results, :time_sync_service, sync_pid)
      end
    else
      # Time sync not enabled
      results
    end
  end

  # Handle authentication and COD if needed
  defp handle_authentication(conn, config, bootstrap_results, start_time) do
    case authenticate(conn) do
      {:ok, auth_conn} ->
        # Authentication successful
        results = Map.put(bootstrap_results, :authenticate, true)

        # Handle COD if enabled
        if config.cod_enabled do
          handle_cod_setup(auth_conn, config, results, start_time)
        else
          # Skip COD but authentication was successful
          emit_bootstrap_success(
            config,
            results,
            start_time,
            authenticated: true,
            cod_enabled: false
          )

          {:ok, results}
        end

      {:error, reason} ->
        # Authentication failed
        emit_bootstrap_failure(:authenticate, reason, start_time)
        {:error, :authenticate, reason}
    end
  end

  # Handle COD (Cancel-on-Disconnect) setup
  defp handle_cod_setup(conn, config, bootstrap_results, start_time) do
    case enable_cancel_on_disconnect(conn, config.cod_scope) do
      {:ok, cod_result} ->
        # COD setup successful
        results = Map.put(bootstrap_results, :enable_cod, cod_result)

        emit_bootstrap_success(
          config,
          results,
          start_time,
          cod_enabled: true,
          cod_scope: config.cod_scope
        )

        {:ok, results}

      {:error, reason} ->
        # COD failed
        emit_bootstrap_failure(:enable_cod, reason, start_time)
        {:error, :enable_cod, reason}
    end
  end

  # Identify which step failed in the bootstrap process
  defp identify_failed_step(bootstrap_results) do
    cond do
      not Map.has_key?(bootstrap_results, :hello) -> :hello
      not Map.has_key?(bootstrap_results, :get_time) -> :get_time
      not Map.has_key?(bootstrap_results, :status) -> :status
      not Map.has_key?(bootstrap_results, :set_heartbeat) -> :set_heartbeat
      true -> :unknown
    end
  end

  # Emit telemetry for bootstrap success
  defp emit_bootstrap_success(config, results, start_time, opts) do
    authenticated = Keyword.get(opts, :authenticated, true)
    cod_enabled = Keyword.get(opts, :cod_enabled, false)
    cod_scope = Keyword.get(opts, :cod_scope, "connection")

    telemetry_data = %{
      client_name: config.client_name,
      client_version: config.client_version,
      heartbeat_interval: config.heartbeat_interval,
      authenticated: authenticated
    }

    # Add COD info if relevant
    telemetry_data =
      if authenticated && cod_enabled,
        do: Map.merge(telemetry_data, %{cod_enabled: true, cod_scope: cod_scope}),
        else: Map.put(telemetry_data, :cod_enabled, false)

    # Add time sync info if available
    telemetry_data =
      if Map.has_key?(results, :time_sync_service),
        do: Map.put(telemetry_data, :time_sync_enabled, true),
        else: Map.put(telemetry_data, :time_sync_enabled, config.time_sync_enabled)

    :telemetry.execute(
      [:deribit_ex, :client, :bootstrap, :success],
      %{duration: System.monotonic_time() - start_time},
      telemetry_data
    )
  end

  # Emit telemetry for bootstrap failure
  defp emit_bootstrap_failure(step, reason, start_time) do
    :telemetry.execute(
      [:deribit_ex, :client, :bootstrap, :failure],
      %{duration: System.monotonic_time() - start_time},
      %{step: step, reason: reason}
    )
  end

  @doc """
  Unsubscribe from specific channels.

  ## Parameters
  - `conn` - Connection process PID
  - `channels` - Single channel string or list of channels to unsubscribe from
  - `opts` - Optional request options

  ## Returns
  - `{:ok, result}` - Success response with list of unsubscribed channels
  - `{:error, reason}` - If the request fails

  ## Examples
      # Unsubscribe from a trades channel
      {:ok, _} = DeribitClient.unsubscribe(conn, "trades.BTC-PERPETUAL.100ms")

      # Unsubscribe from multiple channels at once
      {:ok, _} = DeribitClient.unsubscribe(conn, [
        "trades.BTC-PERPETUAL.100ms",
        "ticker.BTC-PERPETUAL.raw"
      ])
  """
  @spec unsubscribe(pid(), String.t() | [String.t()], map() | nil) ::
          {:ok, map()} | {:error, any()}
  def unsubscribe(conn, channels, opts \\ nil) do
    unsubscribe_with_telemetry(conn, channels, opts, :public)
  end

  @doc """
  Unsubscribe from private channels.

  A convenience function that ensures the private/unsubscribe method is used,
  which is required for channels that need authentication.

  ## Parameters
  - `conn` - Connection process PID
  - `channels` - Single channel string or list of channels to unsubscribe from
  - `opts` - Optional request options

  ## Returns
  - `{:ok, result}` - Success response with list of unsubscribed channels
  - `{:error, reason}` - If the request fails

  ## Examples
      # Unsubscribe from a user orders channel
      {:ok, _} = DeribitClient.unsubscribe_private(conn, "user.orders.BTC-PERPETUAL.raw")

      # Unsubscribe from multiple private channels
      {:ok, _} = DeribitClient.unsubscribe_private(conn, [
        "user.orders.BTC-PERPETUAL.raw",
        "user.trades.BTC-PERPETUAL.raw"
      ])
  """
  @spec unsubscribe_private(pid(), String.t() | [String.t()], map() | nil) ::
          {:ok, map()} | {:error, any()}
  def unsubscribe_private(conn, channels, opts \\ nil) do
    # Force use of the private/unsubscribe method regardless of channel type
    start_time = System.monotonic_time()

    # Ensure channels is a list
    channels = if is_list(channels), do: channels, else: [channels]

    # Create unsubscribe parameters with auth token
    unsubscribe_params = %{"channels" => channels}

    # Call JSON-RPC specifically with private/unsubscribe
    case json_rpc(conn, "private/unsubscribe", unsubscribe_params, opts) do
      {:ok, response} ->
        # Emit telemetry event for successful unsubscription
        :telemetry.execute(
          [:deribit_ex, :client, :unsubscribe, :success],
          %{duration: System.monotonic_time() - start_time},
          %{channels: channels, type: :private}
        )

        # Parse the response
        case parse_response(response) do
          {:ok, result} -> {:ok, result}
          error -> error
        end

      {:error, reason} = error ->
        # Emit telemetry event for unsubscription failure
        :telemetry.execute(
          [:deribit_ex, :client, :unsubscribe, :failure],
          %{duration: System.monotonic_time() - start_time},
          %{channels: channels, type: :private, reason: reason}
        )

        error
    end
  end

  @doc """
  Unsubscribe from all channels.

  ## Parameters
  - `conn` - Connection process PID
  - `opts` - Optional request options

  ## Returns
  - `{:ok, "ok"}` - Success response
  - `{:error, reason}` - If the request fails

  ## Examples
      # Unsubscribe from all active channels
      {:ok, _} = DeribitClient.unsubscribe_all(conn)
  """
  @spec unsubscribe_all(pid(), map() | nil) :: {:ok, String.t()} | {:error, any()}
  def unsubscribe_all(conn, opts \\ nil) do
    start_time = System.monotonic_time()

    # Call JSON-RPC for unsubscribe_all (no parameters needed)
    case json_rpc(conn, "public/unsubscribe_all", %{}, opts) do
      {:ok, response} ->
        # Emit telemetry event for successful unsubscribe_all
        :telemetry.execute(
          [:deribit_ex, :client, :unsubscribe_all, :success],
          %{duration: System.monotonic_time() - start_time},
          %{}
        )

        # Parse the response
        case parse_response(response) do
          {:ok, result} -> {:ok, result}
          error -> error
        end

      {:error, reason} = error ->
        # Emit telemetry event for unsubscribe_all failure
        :telemetry.execute(
          [:deribit_ex, :client, :unsubscribe_all, :failure],
          %{duration: System.monotonic_time() - start_time},
          %{reason: reason}
        )

        error
    end
  end

  @doc """
  Get the current server time from the TimeSyncService without making a request.

  This function returns the estimated server time based on the local time and the
  time delta maintained by the TimeSyncService. It is useful when you need to know
  the server time without making an additional request to the server.

  ## Parameters
    * `conn` - Connection process PID
    
  ## Returns
    * `{:ok, server_time_ms}` - The current server time in milliseconds
    * `{:error, :no_time_sync}` - If time sync service is not running for this connection
    
  ## Examples
      # Get the current estimated server time
      {:ok, server_time} = DeribitClient.current_server_time(conn)
  """
  @spec current_server_time(pid()) :: {:ok, integer()} | {:error, any()}
  def current_server_time(conn) do
    # Check if time sync is enabled in config
    time_sync_config = Application.get_env(:deribit_ex, :websocket, [])[:time_sync] || []
    time_sync_enabled = Keyword.get(time_sync_config, :enabled, true)

    if time_sync_enabled do
      service_name = TimeSyncSupervisor.service_name(conn)

      if Process.whereis(service_name) do
        # Time sync service is running, get the server time
        server_time = TimeSyncService.server_time(service_name)
        {:ok, server_time}
      else
        # Time sync service is not running, fallback to direct get_time
        get_time(conn)
      end
    else
      # Time sync is disabled, use direct get_time
      get_time(conn)
    end
  end
end
