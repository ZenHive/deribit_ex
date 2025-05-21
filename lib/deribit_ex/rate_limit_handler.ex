defmodule DeribitEx.RateLimitHandler do
  @moduledoc """
  Adaptive rate limit handler for Deribit WebSocket API.

  This module implements the WebsockexNova.Behaviors.RateLimitHandler
  behavior with adaptive rate limiting capabilities:

  - Dynamically adjusts rate limits based on 429 responses from Deribit
  - Implements exponential backoff when rate limits are hit
  - Prioritizes critical operations like order cancellation
  - Recovers rate limits gradually after backoff periods
  - Emits detailed telemetry for monitoring rate limiting behavior

  ## Configuration Options

  Three rate limit modes are supported:
  - `:cautious` - Strict limits to avoid 429s completely
  - `:normal` - Balanced approach 
  - `:aggressive` - Higher throughput, might get occasional 429s

  ## Backoff Strategy

  When a 429 response is received:
  1. The handler reduces the rate limit by the recovery_factor
  2. It applies a backoff multiplier to delay subsequent requests
  3. The backoff multiplier increases with consecutive 429s
  4. The rate limit gradually recovers over time
  """
  @behaviour WebsockexNova.Behaviors.RateLimitHandler

  alias WebsockexNova.Behaviors.RateLimitHandler

  require Logger

  @typedoc """
  Operation types that can be rate limited.
  """
  @type operation_type :: :auth | :subscription | :query | :order | :high_priority | :cancel

  @typedoc """
  Cost map specifying token costs for different operation types.
  """
  @type cost_map :: %{optional(operation_type) => non_neg_integer}

  @typedoc """
  Rate limiting modes that determine token bucket parameters.
  """
  @type rate_limit_mode :: :cautious | :normal | :aggressive

  @typedoc """
  Token bucket state for the rate limiter.
  """
  @type bucket_state :: %{
          tokens: non_neg_integer(),
          capacity: pos_integer(),
          refill_rate: pos_integer(),
          refill_interval: pos_integer(),
          last_refill: integer(),
          queue: :queue.queue(),
          queue_size: non_neg_integer(),
          queue_limit: pos_integer()
        }

  @typedoc """
  Adaptive state for the rate limiter.
  """
  @type adaptive_state :: %{
          backoff_multiplier: float(),
          backoff_initial: float(),
          backoff_max: float(),
          backoff_reset_after: pos_integer(),
          last_429: integer() | nil,
          recovery_factor: float(),
          recovery_increase: float(),
          recovery_interval: pos_integer(),
          last_recovery: integer(),
          original_capacity: pos_integer(),
          original_refill_rate: pos_integer(),
          telemetry_prefix: list(atom())
        }

  @typedoc """
  Configuration for the rate limiter.
  """
  @type config :: %{
          mode: rate_limit_mode(),
          cost_map: cost_map()
        }

  @typedoc """
  Request handler tracking information.
  """
  @type request_info :: %{
          id: String.t(),
          op_type: operation_type(),
          sent_at: integer()
        }

  @typedoc """
  Overall state for the rate limiter.
  """
  @type state :: %{
          bucket: bucket_state(),
          adaptive: adaptive_state(),
          config: config(),
          response_handlers: %{optional(String.t()) => request_info()},
          last_tick: integer() | nil,
          recent_responses: list(map()) | nil
        }

  # Default operation costs - these will be merged with any provided in config
  @default_cost_map %{
    subscription: 5,
    auth: 10,
    query: 1,
    order: 10,
    high_priority: 0,
    cancel: 3
  }

  # Token bucket params for different modes
  @bucket_params_by_mode %{
    cautious: %{
      capacity: 60,
      refill_rate: 5,
      refill_interval: 1_000
    },
    normal: %{
      capacity: 120,
      refill_rate: 10,
      refill_interval: 1_000
    },
    aggressive: %{
      capacity: 200,
      refill_rate: 15,
      refill_interval: 1_000
    }
  }

  @impl RateLimitHandler
  @doc """
  Initializes rate limit state with token bucket and adaptive parameters.

  ## Parameters
    * `opts` - Configuration options for the rate limiter:
      * `:mode` - Rate limiting mode (:cautious, :normal, :aggressive)
      * `:cost_map` - Map of operation costs
      * `:capacity` - Override token bucket capacity
      * `:refill_rate` - Override token refill rate
      * `:refill_interval` - Override token refill interval
      * `:queue_limit` - Maximum queue size for delayed requests
      * `:adaptive` - Adaptive rate limiting options:
        * `:backoff_initial` - Initial backoff multiplier when 429 is hit
        * `:backoff_max` - Maximum backoff multiplier
        * `:backoff_reset_after` - Time after which backoff resets (ms)
        * `:recovery_factor` - Factor to reduce capacity by when 429 is hit
        * `:recovery_increase` - Rate at which capacity recovers
        * `:recovery_interval` - Interval between capacity recovery attempts
        * `:telemetry_prefix` - Prefix for telemetry events

  ## Returns
    * `{:ok, state}` - Initialized rate limiter state
  """
  @spec rate_limit_init(map()) :: {:ok, state()}
  def rate_limit_init(opts) do
    # Get mode-specific bucket parameters or default to normal mode
    mode = Map.get(opts, :mode, :normal)
    bucket_params = @bucket_params_by_mode[mode] || @bucket_params_by_mode.normal

    # Merge provided cost map with defaults
    cost_map = Map.merge(@default_cost_map, Map.get(opts, :cost_map, %{}))

    # Initialize token bucket with configured capacity
    capacity = Map.get(opts, :capacity) || bucket_params.capacity
    refill_rate = Map.get(opts, :refill_rate) || bucket_params.refill_rate
    refill_interval = Map.get(opts, :refill_interval) || bucket_params.refill_interval

    # Initialize token bucket state
    bucket_state = %{
      tokens: capacity,
      capacity: capacity,
      refill_rate: refill_rate,
      refill_interval: refill_interval,
      last_refill: current_time_ms(),
      queue: :queue.new(),
      queue_size: 0,
      queue_limit: Map.get(opts, :queue_limit, 200)
    }

    # Extract adaptive rate limiting parameters with defaults
    adaptive_opts = Map.get(opts, :adaptive, %{})

    adaptive_state = %{
      # Get backoff parameters or use defaults
      backoff_multiplier: 1.0,
      backoff_initial: Map.get(adaptive_opts, :backoff_initial, 1.5),
      backoff_max: Map.get(adaptive_opts, :backoff_max, 10.0),
      backoff_reset_after: Map.get(adaptive_opts, :backoff_reset_after, 60_000),
      last_429: nil,

      # Get recovery parameters or use defaults
      recovery_factor: Map.get(adaptive_opts, :recovery_factor, 0.9),
      recovery_increase: Map.get(adaptive_opts, :recovery_increase, 0.05),
      recovery_interval: Map.get(adaptive_opts, :recovery_interval, 5_000),
      last_recovery: current_time_ms(),

      # Get original capacity settings for recovery
      original_capacity: capacity,
      original_refill_rate: refill_rate,

      # Get telemetry settings
      telemetry_prefix: Map.get(adaptive_opts, :telemetry_prefix, [:deribit_ex, :rate_limit])
    }

    # Store configuration for reference
    config = %{
      mode: mode,
      cost_map: cost_map
    }

    # Store all state components for the rate limiter
    state = %{
      bucket: bucket_state,
      adaptive: adaptive_state,
      config: config,
      response_handlers: %{}
    }

    # Emit telemetry on initialization
    :telemetry.execute(
      adaptive_state.telemetry_prefix ++ [:init],
      %{system_time: System.system_time()},
      %{
        mode: mode,
        capacity: capacity,
        refill_rate: refill_rate,
        refill_interval: refill_interval
      }
    )

    {:ok, state}
  end

  @impl RateLimitHandler
  @doc """
  Checks if a request should be rate limited.

  This is the main entry point for the rate limiting handler and is called
  for every request sent to the WebSocket API.

  ## Parameters
    * `request` - The request to be rate limited (map or JSON string)
    * `state` - Current rate limiter state

  ## Returns
    * `{:ok, state}` - Request is allowed, with updated state
    * `{:backoff, delay_ms, state}` - Request should be delayed by specified ms
  """
  @spec check_rate_limit(map() | String.t(), state()) ::
          {:allow, state()} | {:queue, state()} | {:reject, any(), state()}
  def check_rate_limit(request, state) do
    # Extract request payload and ID
    {request_payload, request_id} = extract_request_info(request)
    op_type = extract_operation_type(request_payload)
    cost = get_operation_cost(op_type, state.config.cost_map)

    # High priority operations bypass rate limiting
    if cost == 0 do
      {:allow, state}
    else
      handle_rate_limited_request(request_id, op_type, cost, state)
    end
  end

  # Handle a request that is subject to rate limiting
  @spec handle_rate_limited_request(String.t() | nil, operation_type(), non_neg_integer(), state()) ::
          {:allow, state()} | {:queue, state()} | {:reject, non_neg_integer(), state()}
  defp handle_rate_limited_request(request_id, op_type, cost, state) do
    # Update token bucket and apply recovery if needed
    bucket = refill_tokens(state.bucket)
    adaptive = state.adaptive
    {bucket, adaptive} = maybe_apply_recovery(bucket, adaptive)

    # Check if we have enough tokens to proceed
    if bucket.tokens >= cost do
      process_allowed_request(request_id, op_type, cost, bucket, adaptive, state)
    else
      process_limited_request(op_type, cost, bucket, adaptive, state)
    end
  end

  # Process a request that's allowed to proceed (enough tokens)
  @spec process_allowed_request(
          String.t() | nil,
          operation_type(),
          non_neg_integer(),
          bucket_state(),
          adaptive_state(),
          state()
        ) :: {:allow, state()}
  defp process_allowed_request(request_id, op_type, cost, bucket, adaptive, state) do
    # Consume tokens for this request
    bucket = %{bucket | tokens: bucket.tokens - cost}

    # Update response handlers if the request has an ID
    response_handlers = update_response_handlers(request_id, op_type, state.response_handlers)

    # Create updated state
    new_state = %{
      state
      | bucket: bucket,
        adaptive: adaptive,
        response_handlers: response_handlers
    }

    # Emit telemetry for allowed request
    emit_request_allowed_telemetry(op_type, cost, bucket, adaptive)

    # All requests use the same response regardless of request_id
    {:allow, new_state}
  end

  # Process a request that's being limited (not enough tokens)
  @spec process_limited_request(
          operation_type(),
          non_neg_integer(),
          bucket_state(),
          adaptive_state(),
          state()
        ) :: {:queue, state()} | {:reject, non_neg_integer(), state()}
  defp process_limited_request(op_type, cost, bucket, adaptive, state) do
    # Calculate delay based on adaptive backoff
    delay_ms = trunc(bucket.refill_interval * adaptive.backoff_multiplier)

    # Emit telemetry for rate-limited request
    emit_request_limited_telemetry(op_type, cost, delay_ms, bucket, adaptive)

    # Update state and indicate rate limiting needed
    new_state = %{state | bucket: bucket, adaptive: adaptive}

    # If the backoff is small, we'll queue the request, otherwise reject it
    if delay_ms < 1000 do
      {:queue, new_state}
    else
      {:reject, delay_ms, new_state}
    end
  end

  # Update response handlers for a request with ID
  @spec update_response_handlers(nil, operation_type(), map()) :: map()
  defp update_response_handlers(nil, _op_type, response_handlers), do: response_handlers

  @spec update_response_handlers(String.t(), operation_type(), map()) :: map()
  defp update_response_handlers(request_id, op_type, response_handlers) do
    # Store information about this request for response handling
    request_info = %{
      id: request_id,
      op_type: op_type,
      sent_at: current_time_ms()
    }

    Map.put(response_handlers, request_id, request_info)
  end

  # Emit telemetry for allowed requests
  @spec emit_request_allowed_telemetry(
          operation_type(),
          non_neg_integer(),
          bucket_state(),
          adaptive_state()
        ) :: :ok
  defp emit_request_allowed_telemetry(op_type, cost, bucket, adaptive) do
    :telemetry.execute(
      adaptive.telemetry_prefix ++ [:request_allowed],
      %{system_time: System.system_time()},
      %{
        operation: op_type,
        cost: cost,
        remaining_tokens: bucket.tokens,
        capacity: bucket.capacity
      }
    )
  end

  # Emit telemetry for limited requests
  @spec emit_request_limited_telemetry(
          operation_type(),
          non_neg_integer(),
          non_neg_integer(),
          bucket_state(),
          adaptive_state()
        ) :: :ok
  defp emit_request_limited_telemetry(op_type, cost, delay_ms, bucket, adaptive) do
    :telemetry.execute(
      adaptive.telemetry_prefix ++ [:request_limited],
      %{system_time: System.system_time()},
      %{
        operation: op_type,
        cost: cost,
        backoff_ms: delay_ms,
        capacity: bucket.capacity
      }
    )
  end

  @impl RateLimitHandler
  @doc """
  Handles the rate limiter tick (called periodically by WebsockexNova).

  This is used for processing responses and adjusting rate limits based on
  429 responses from the Deribit API.

  ## Parameters
    * `state` - Current rate limiter state
    
  ## Returns
    * `{:ok, state}` - Updated state after tick processing
  """
  @spec handle_tick(state()) :: {:ok, state()}
  def handle_tick(state) do
    # Update last_response_check time
    now = current_time_ms()
    state = Map.put(state, :last_tick, now)

    # Process any 429 responses
    json_responses = Map.get(state, :recent_responses, [])

    # Check if any of the responses are 429 errors
    has_429 = Enum.any?(json_responses, &rate_limit_error?/1)

    if has_429 do
      # We got a 429, need to apply backoff
      bucket = state.bucket
      adaptive = state.adaptive

      # Calculate new backoff multiplier (exponential backoff)
      new_backoff =
        min(
          adaptive.backoff_multiplier * adaptive.backoff_initial,
          adaptive.backoff_max
        )

      # Reduce capacity and refill rate
      reduced_capacity = trunc(bucket.capacity * adaptive.recovery_factor)
      reduced_refill_rate = trunc(bucket.refill_rate * adaptive.recovery_factor)

      # Update bucket
      bucket = %{
        bucket
        | capacity: max(reduced_capacity, 1),
          refill_rate: max(reduced_refill_rate, 1),
          # Reset tokens to zero
          tokens: 0
      }

      # Update adaptive state
      adaptive = %{adaptive | backoff_multiplier: new_backoff, last_429: now}

      # Emit telemetry for rate limit hit
      :telemetry.execute(
        adaptive.telemetry_prefix ++ [:rate_limit_hit],
        %{system_time: System.system_time()},
        %{
          backoff_multiplier: new_backoff,
          new_capacity: reduced_capacity,
          new_refill_rate: reduced_refill_rate
        }
      )

      # Log the rate limit event
      Logger.warning(
        "[DeribitRateLimitHandler] Rate limit hit, applying backoff. " <>
          "Multiplier: #{new_backoff}, Capacity: #{reduced_capacity}, " <>
          "Refill Rate: #{reduced_refill_rate}"
      )

      # Update state with new values and clear recent responses
      new_state = %{state | bucket: bucket, adaptive: adaptive, recent_responses: []}

      {:ok, new_state}
    else
      # No 429 errors, check if we need to reset backoff
      adaptive = maybe_reset_backoff(state.adaptive)

      # Refill tokens and update adaptive state
      bucket = refill_tokens(state.bucket)

      # Apply recovery if needed
      {bucket, adaptive} = maybe_apply_recovery(bucket, adaptive)

      # Update state
      new_state = %{state | bucket: bucket, adaptive: adaptive, recent_responses: []}

      {:ok, new_state}
    end
  end

  # Helper to extract request payload and ID from request
  @spec extract_request_info(map()) :: {map(), String.t() | nil}
  defp extract_request_info(request) when is_map(request) do
    # If it's already a map, return it and the ID if available
    {request, Map.get(request, "id")}
  end

  @spec extract_request_info(String.t()) :: {map() | String.t(), String.t() | nil}
  defp extract_request_info(request) when is_binary(request) do
    # Parse JSON string
    case Jason.decode(request) do
      {:ok, decoded} -> {decoded, Map.get(decoded, "id")}
      # Can't parse, return as is
      _ -> {request, nil}
    end
  end

  @spec extract_request_info(term()) :: {term(), nil}
  defp extract_request_info(request) do
    # For other types, return as is without ID
    {request, nil}
  end

  #
  # Private helper functions
  #

  # Extract operation type from request payload
  @spec extract_operation_type(map()) :: operation_type()
  defp extract_operation_type(request_payload) when is_map(request_payload) do
    # Try to get method from JSON-RPC
    method = request_payload["method"]

    if is_binary(method) do
      determine_operation_type(method)
    else
      # Default to query when no method is present
      :query
    end
  end

  # Handle string payload (parsing JSON)
  @spec extract_operation_type(String.t()) :: operation_type()
  defp extract_operation_type(request_payload) when is_binary(request_payload) do
    case Jason.decode(request_payload) do
      {:ok, decoded} -> extract_operation_type(decoded)
      # Default to query if we can't parse
      _ -> :query
    end
  end

  # Handle other payload types
  @spec extract_operation_type(term()) :: operation_type()
  defp extract_operation_type(_), do: :query

  # Determine operation type based on the method string
  @spec determine_operation_type(String.t()) :: operation_type()
  defp determine_operation_type(method) do
    cond do
      # Authentication methods
      String.starts_with?(method, "public/auth") -> :auth
      String.contains?(method, "token") -> :auth
      # Subscription methods
      String.contains?(method, "subscribe") -> :subscription
      # Order-related methods
      String.contains?(method, "order") -> :order
      # Cancellation methods (high priority)
      String.contains?(method, "cancel") -> :cancel
      # Default to query for other methods
      true -> :query
    end
  end

  # Get the cost of an operation from the cost map
  @spec get_operation_cost(operation_type(), cost_map()) :: non_neg_integer()
  defp get_operation_cost(op_type, cost_map) do
    Map.get(cost_map, op_type, 1)
  end

  # Check if a response is a rate limit error (429)
  @spec rate_limit_error?(map()) :: boolean()
  defp rate_limit_error?(%{"error" => %{"code" => code}}) when code in [10_429, 11_010], do: true
  defp rate_limit_error?(%{error: %{code: code}}) when code in [10_429, 11_010], do: true
  defp rate_limit_error?(_), do: false

  # Get current time in milliseconds
  @spec current_time_ms() :: integer()
  def current_time_ms, do: System.monotonic_time(:millisecond)

  # Refill tokens in the bucket based on elapsed time
  @spec refill_tokens(bucket_state()) :: bucket_state()
  defp refill_tokens(bucket) do
    now = current_time_ms()
    elapsed = now - bucket.last_refill

    if elapsed >= bucket.refill_interval do
      # Calculate how many intervals have passed
      intervals = div(elapsed, bucket.refill_interval)

      # Add tokens for each interval (up to capacity)
      new_tokens =
        min(
          bucket.tokens + intervals * bucket.refill_rate,
          bucket.capacity
        )

      # Update last refill time
      last_refill = bucket.last_refill + intervals * bucket.refill_interval

      %{bucket | tokens: new_tokens, last_refill: last_refill}
    else
      bucket
    end
  end

  # Maybe reset backoff multiplier if enough time has passed
  @spec maybe_reset_backoff(adaptive_state()) :: adaptive_state()
  defp maybe_reset_backoff(adaptive) do
    now = current_time_ms()

    # Check if we have a backoff multiplier and last 429 time
    if adaptive.backoff_multiplier > 1.0 && adaptive.last_429 != nil do
      # Check if enough time has passed since last 429
      if now - adaptive.last_429 >= adaptive.backoff_reset_after do
        # Reset backoff multiplier
        %{adaptive | backoff_multiplier: 1.0}
      else
        adaptive
      end
    else
      adaptive
    end
  end

  # Apply rate limit recovery if needed
  @spec maybe_apply_recovery(bucket_state(), adaptive_state()) :: {bucket_state(), adaptive_state()}
  defp maybe_apply_recovery(bucket, adaptive) do
    now = current_time_ms()

    # Check if we need to recover (capacity is reduced)
    if bucket.capacity < adaptive.original_capacity &&
         now - adaptive.last_recovery >= adaptive.recovery_interval do
      # Calculate recovery amounts
      capacity_increase = trunc(adaptive.original_capacity * adaptive.recovery_increase)
      refill_increase = trunc(adaptive.original_refill_rate * adaptive.recovery_increase)

      # Calculate new values (not exceeding originals)
      new_capacity = min(bucket.capacity + capacity_increase, adaptive.original_capacity)
      new_refill_rate = min(bucket.refill_rate + refill_increase, adaptive.original_refill_rate)

      # Update bucket with new values
      bucket = %{bucket | capacity: new_capacity, refill_rate: new_refill_rate}

      # Update adaptive state with new recovery time
      adaptive = %{adaptive | last_recovery: now}

      # Emit telemetry for recovery
      :telemetry.execute(
        adaptive.telemetry_prefix ++ [:rate_limit_recovery],
        %{system_time: System.system_time()},
        %{
          new_capacity: new_capacity,
          new_refill_rate: new_refill_rate,
          original_capacity: adaptive.original_capacity,
          original_refill_rate: adaptive.original_refill_rate
        }
      )

      {bucket, adaptive}
    else
      {bucket, adaptive}
    end
  end
end
