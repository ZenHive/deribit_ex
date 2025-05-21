defmodule DeribitEx.DeribitRPC do
  @moduledoc """
  Core JSON-RPC handling for Deribit WebSocket API.

  This module provides infrastructure for:
  - Generating standard JSON-RPC requests
  - Parsing JSON-RPC responses
  - Handling error responses consistently
  - Tracking request IDs
  - Managing timeouts and retries
  - Extracting metadata from responses

  This module is used by the DeribitAdapter and DeribitClient to
  ensure consistent RPC handling and error management.
  """

  # Common Deribit error codes and their descriptions
  @error_codes %{
    # Authentication errors
    13_004 => {:auth, :not_authorized, "Not authorized"},
    13_009 => {:auth, :invalid_token, "Invalid token"},
    13_010 => {:auth, :token_expired, "Token expired"},
    13_011 => {:auth, :token_missing, "Access token required"},

    # Rate limiting
    10_429 => {:rate_limit, :too_many_requests, "Too many requests"},
    11_010 => {:rate_limit, :max_requests_exceeded, "Max requests exceeded"},

    # Input errors
    10_001 => {:validation, :invalid_params, "Invalid params"},
    11_050 => {:validation, :invalid_argument, "Invalid argument provided"},
    11_051 => {:validation, :bad_request, "Bad request format"},

    # System errors
    11_003 => {:system, :unknown_error, "Unknown system error"},
    10_028 => {:system, :system_maintenance, "System maintenance"},
    11_060 => {:system, :internal_server_error, "Internal server error"},

    # Order errors
    10_009 => {:order, :insufficient_funds, "Insufficient funds"},
    10_010 => {:order, :already_canceled, "Already canceled"},
    10_011 => {:order, :not_found, "Order not found"},

    # Subscription errors
    11_041 => {:subscription, :subscription_failed, "Subscription failed"}
  }

  # Default request parameters by method
  @default_params %{
    "public/get_time" => %{},
    "public/test" => %{},
    "public/hello" => %{"client_name" => "market_maker", "client_version" => "1.0.0"},
    "public/set_heartbeat" => %{"interval" => 30},
    "private/enable_cancel_on_disconnect" => %{"scope" => "connection"}
  }

  @doc """
  Generates a standard JSON-RPC 2.0 request payload.

  ## Parameters
  - `method` - The JSON-RPC method to call (e.g., "public/auth")
  - `params` - The parameters to pass to the method (map)
  - `id` - Optional request ID (defaults to a unique integer)

  ## Returns
  - `{:ok, request_payload, request_id}` - The JSON-RPC request and its ID

  ## Examples
      iex> DeribitRPC.generate_request("public/get_time", %{})
      {:ok, %{"jsonrpc" => "2.0", "id" => 123, "method" => "public/get_time", "params" => %{}}, 123}
  """
  @spec generate_request(String.t(), map(), integer() | nil) :: {:ok, map(), integer()}
  def generate_request(method, params, id \\ nil) when is_map(params) do
    request_id = id || System.unique_integer([:positive])

    # Merge with default parameters if they exist for this method
    merged_params =
      case Map.get(@default_params, method) do
        nil -> params
        defaults -> Map.merge(defaults, params)
      end

    payload = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "method" => method,
      "params" => merged_params
    }

    # Emit telemetry for request generation
    :telemetry.execute(
      [:deribit_ex, :rpc, :request_generated],
      %{system_time: System.system_time()},
      %{method: method, request_id: request_id}
    )

    {:ok, payload, request_id}
  end

  @doc """
  Parses a JSON-RPC response based on its structure.

  ## Parameters
  - `response` - The JSON-RPC response (map)

  ## Returns
  - `{:ok, result}` - For successful responses with a result field
  - `{:error, error}` - For error responses
  - `{:error, {:invalid_response, response}}` - For invalid or unexpected responses

  ## Examples
      iex> DeribitRPC.parse_response(%{"jsonrpc" => "2.0", "id" => 123, "result" => "success"})
      {:ok, "success"}
      
      iex> DeribitRPC.parse_response(%{"jsonrpc" => "2.0", "id" => 123, "error" => %{"code" => 10001, "message" => "Error"}})
      {:error, %{"code" => 10001, "message" => "Error"}}
  """
  @spec parse_response(map()) ::
          {:ok, any()} | {:error, any()} | {:error, {:invalid_response, map()}}
  def parse_response(%{"result" => result}), do: {:ok, result}

  def parse_response(%{"error" => error} = response) do
    # Emit telemetry for error responses
    :telemetry.execute(
      [:deribit_ex, :rpc, :error_response],
      %{system_time: System.system_time()},
      %{
        error: error,
        request_id: Map.get(response, "id"),
        usermsg: Map.get(error, "message")
      }
    )

    {:error, error}
  end

  def parse_response(other) do
    # Emit telemetry for invalid response structures to aid debugging
    :telemetry.execute(
      [:deribit_ex, :rpc, :invalid_response],
      %{system_time: System.system_time()},
      %{response: other}
    )

    {:error, {:invalid_response, other}}
  end

  @doc """
  Checks if an error requires connection re-authentication.

  Used to determine if authentication needs to be refreshed
  based on specific Deribit error codes.

  ## Parameters
  - `error` - The error map from the response

  ## Returns
  - `true` if authentication needs to be refreshed
  - `false` otherwise

  ## Examples
      iex> DeribitRPC.needs_reauth?(%{"code" => 13010, "message" => "Token expired"})
      true
      
      iex> DeribitRPC.needs_reauth?(%{"code" => 10001, "message" => "Invalid parameter"})
      false
  """
  @spec needs_reauth?(map()) :: boolean()
  def needs_reauth?(%{"code" => code}) when code in [13_004, 13_009, 13_010, 13_011], do: true
  def needs_reauth?(_), do: false

  @doc """
  Classifies an error based on its error code.

  ## Parameters
  - `error` - The error map from the response

  ## Returns
  - `{category, reason, message}` tuple with error classification
  - `:unknown` for unrecognized error codes

  ## Examples
      iex> DeribitRPC.classify_error(%{"code" => 13010, "message" => "Token expired"})
      {:auth, :token_expired, "Token expired"}
      
      iex> DeribitRPC.classify_error(%{"code" => 99999, "message" => "Unknown error"})
      {:unknown, :unknown_code, "Unknown error"}
  """
  @spec classify_error(map()) :: {atom(), atom(), String.t()} | :unknown
  def classify_error(%{"code" => code, "message" => message}) do
    case Map.get(@error_codes, code) do
      nil -> {:unknown, :unknown_code, message}
      {category, reason, _default_message} -> {category, reason, message}
    end
  end

  def classify_error(_), do: {:unknown, :invalid_error_format, "Invalid error format"}

  @doc """
  Classifies an RPC method as public, private, or unknown.

  This is used for properly handling authentication requirements.

  ## Parameters
  - `method` - The JSON-RPC method string

  ## Returns
  - `:public` for public methods
  - `:private` for private methods
  - `:unknown` for unclassified methods

  ## Examples
      iex> DeribitRPC.method_type("public/auth")
      :public
      
      iex> DeribitRPC.method_type("private/get_position")
      :private
  """
  @spec method_type(String.t()) :: :public | :private | :unknown
  def method_type("public/" <> _rest), do: :public
  def method_type("private/" <> _rest), do: :private
  def method_type(_), do: :unknown

  @doc """
  Determines if a method requires authentication.

  ## Parameters
  - `method` - The JSON-RPC method string

  ## Returns
  - `true` if authentication is required
  - `false` otherwise

  ## Examples
      iex> DeribitRPC.requires_auth?("private/get_position")
      true
      
      iex> DeribitRPC.requires_auth?("public/get_time")
      false
  """
  @spec requires_auth?(String.t()) :: boolean()
  def requires_auth?(method) do
    method_type(method) == :private
  end

  @doc """
  Adds authentication token to parameters if required.

  ## Parameters
  - `params` - The original parameters map
  - `method` - The JSON-RPC method string
  - `access_token` - The current access token (or nil if not authenticated)

  ## Returns
  - Updated parameters map with access_token if required
  - Original parameters map if not required or token not available

  ## Examples
      iex> DeribitRPC.add_auth_params(%{}, "private/get_position", "token123")
      %{"access_token" => "token123"}
      
      iex> DeribitRPC.add_auth_params(%{instrument: "BTC-PERPETUAL"}, "public/get_time", "token123")
      %{instrument: "BTC-PERPETUAL"}
  """
  @spec add_auth_params(map(), String.t(), String.t() | nil) :: map()
  def add_auth_params(params, method, access_token) do
    if requires_auth?(method) && access_token do
      Map.put(params, "access_token", access_token)
    else
      params
    end
  end

  @doc """
  Tracks a new request in the state for later matching with response.

  ## Parameters
  - `state` - The current adapter state
  - `id` - The request ID
  - `method` - The JSON-RPC method
  - `params` - The request parameters
  - `options` - Optional request options

  ## Returns
  - Updated state with the request tracked
  """
  @spec track_request(map(), integer(), String.t(), map(), map() | nil) :: map()
  def track_request(state, id, method, params, options \\ nil) do
    request_info = %{
      id: id,
      method: method,
      params: params,
      sent_at: DateTime.utc_now(),
      options: options,
      timeout_ref: nil
    }

    # Set up timeout tracking if needed
    request_timeout = get_timeout(method, options, state)

    request_info =
      if request_timeout > 0 do
        # The actual timeout implementation happens in the adapter's handle_info
        timeout_ref = generate_timeout_reference(id)
        Map.put(request_info, :timeout_ref, timeout_ref)
      else
        request_info
      end

    requests = Map.get(state, :requests, %{})
    updated_requests = Map.put(requests, id, request_info)

    Map.put(state, :requests, updated_requests)
  end

  @doc """
  Removes a tracked request from state once processed.

  ## Parameters
  - `state` - The current adapter state
  - `id` - The request ID to remove

  ## Returns
  - Updated state with the request removed
  """
  @spec remove_tracked_request(map(), integer()) :: map()
  def remove_tracked_request(state, id) do
    requests = Map.get(state, :requests, %{})

    # Cancel any pending timeouts
    case get_in(requests, [id, :timeout_ref]) do
      nil ->
        :ok

      timeout_ref when is_reference(timeout_ref) ->
        Process.cancel_timer(timeout_ref)

      _ ->
        :ok
    end

    updated_requests = Map.delete(requests, id)
    Map.put(state, :requests, updated_requests)
  end

  @doc """
  Generates a standardized error tuple for failed Deribit API operations.

  ## Parameters
  - `reason` - The error reason
  - `details` - Additional error details

  ## Returns
  - `{:error, map()}` with standardized error structure
  """
  @spec error(atom() | String.t(), map() | nil) :: {:error, map()}
  def error(reason, details \\ nil) do
    error_map = %{
      reason: reason,
      details: details
    }

    {:error, error_map}
  end

  @doc """
  Extracts response metadata from a JSON-RPC response.

  This is useful for handling data from notification responses like subscriptions.

  ## Parameters
  - `response` - The JSON-RPC response or notification (map)

  ## Returns
  - Map with extracted metadata (if any)
  - Empty map if no metadata is found

  ## Examples
      iex> DeribitRPC.extract_metadata(%{"jsonrpc" => "2.0", "method" => "subscription", "params" => %{"channel" => "trades.BTC-PERPETUAL.raw"}})
      %{channel: "trades.BTC-PERPETUAL.raw", type: :subscription}
  """
  @spec extract_metadata(map()) :: map()
  def extract_metadata(
        %{"method" => "subscription", "params" => %{"channel" => channel}} = _response
      ) do
    # Process subscription notifications
    %{
      channel: channel,
      type: :subscription
    }
  end

  def extract_metadata(%{"usIn" => user_in, "usOut" => user_out})
      when is_integer(user_in) and is_integer(user_out) do
    # Extract timing information when available
    processing_time = user_out - user_in

    %{
      timing: %{
        user_in: user_in,
        user_out: user_out,
        processing_time: processing_time
      }
    }
  end

  def extract_metadata(_), do: %{}

  @doc """
  Converts a timestamp from microseconds to DateTime.

  Deribit often provides timestamps in microseconds since epoch.

  ## Parameters
  - `timestamp_us` - Timestamp in microseconds

  ## Returns
  - DateTime struct representing the timestamp

  ## Examples
      iex> DeribitRPC.microseconds_to_datetime(1609459200000000)
      ~U[2021-01-01 00:00:00Z]
  """
  @spec microseconds_to_datetime(integer()) :: DateTime.t()
  def microseconds_to_datetime(timestamp_us) when is_integer(timestamp_us) do
    # Convert microseconds to seconds and nanoseconds
    seconds = div(timestamp_us, 1_000_000)
    nanoseconds = rem(timestamp_us, 1_000_000) * 1_000

    # Create DateTime with UTC time zone
    {:ok, datetime} = DateTime.from_unix(seconds, :second)
    %{datetime | microsecond: {div(nanoseconds, 1_000), 6}}
  end

  @doc """
  Gets the timeout value for a request.

  ## Parameters
  - `method` - The JSON-RPC method
  - `options` - Request options that may include timeout
  - `state` - The adapter state which may have default timeouts

  ## Returns
  - Timeout value in milliseconds
  """
  @spec get_timeout(String.t(), map() | nil, map()) :: integer()
  def get_timeout(method, options, state) do
    default_timeout = Map.get(state, :request_timeout, 10_000)

    # Method-specific timeouts
    method_timeout =
      case method do
        "public/auth" -> 30_000
        "private/logout" -> 5_000
        "public/test" -> 2_000
        "public/get_time" -> 5_000
        _ -> default_timeout
      end

    # Options can override default and method-specific timeouts
    option_timeout =
      case options do
        %{timeout: timeout} when is_integer(timeout) and timeout >= 0 -> timeout
        _ -> method_timeout
      end

    option_timeout
  end

  @doc """
  Creates a reference for the timeout process that will be canceled when the request is completed.

  ## Parameters
  - `request_id` - The JSON-RPC request ID

  ## Returns
  - Timer reference
  """
  @spec generate_timeout_reference(integer()) :: reference()
  def generate_timeout_reference(request_id) do
    Process.send_after(self(), {:timeout, request_id}, get_timeout_ms(request_id))
  end

  # Get the timeout in milliseconds based on the request ID and type
  # This is used internally by generate_timeout_reference
  defp get_timeout_ms(_request_id) do
    # For now, we use a fixed timeout
    # In a future enhancement, this could be based on request type
    10_000
  end
end
