defmodule DeribitEx.DeribitRateLimitHandlerTest do
  use ExUnit.Case, async: true

  alias DeribitEx.DeribitRateLimitHandler

  describe "rate_limit_init/1" do
    test "initializes with default settings" do
      {:ok, state} = DeribitRateLimitHandler.rate_limit_init(%{})

      # Verify bucket configuration
      assert state.bucket.capacity == 120
      assert state.bucket.refill_rate == 10
      assert state.bucket.refill_interval == 1_000
      assert state.bucket.tokens == 120
      assert state.bucket.queue_size == 0

      # Verify adaptive configuration
      assert state.adaptive.backoff_multiplier == 1.0
      assert state.adaptive.recovery_factor == 0.9

      # Verify response_handlers is initialized
      assert state.response_handlers == %{}
    end

    test "initializes with cautious mode settings" do
      {:ok, state} = DeribitRateLimitHandler.rate_limit_init(%{mode: :cautious})

      # Verify bucket configuration for cautious mode
      assert state.bucket.capacity == 60
      assert state.bucket.refill_rate == 5
      assert state.bucket.refill_interval == 1_000
      assert state.bucket.tokens == 60
    end

    test "initializes with aggressive mode settings" do
      {:ok, state} = DeribitRateLimitHandler.rate_limit_init(%{mode: :aggressive})

      # Verify bucket configuration for aggressive mode
      assert state.bucket.capacity == 200
      assert state.bucket.refill_rate == 15
      assert state.bucket.refill_interval == 1_000
      assert state.bucket.tokens == 200
    end

    test "allows custom cost map" do
      custom_cost_map = %{
        subscription: 10,
        auth: 20
      }

      {:ok, state} = DeribitRateLimitHandler.rate_limit_init(%{cost_map: custom_cost_map})

      # Verify cost map configuration
      assert state.config.cost_map.subscription == 10
      assert state.config.cost_map.auth == 20
      # Default costs should still be present
      assert state.config.cost_map.query == 1
    end
  end

  describe "check_rate_limit/2" do
    test "allows high priority operations without consuming tokens" do
      {:ok, state} = DeribitRateLimitHandler.rate_limit_init(%{})

      # Create a high priority cancel operation (which has cost 0)
      payload = %{"method" => "private/cancel"}

      # Set cost of cancel to 0 explicitly to ensure it's high priority
      state = put_in(state.config.cost_map.cancel, 0)

      # Process the request
      {:allow, new_state} = DeribitRateLimitHandler.check_rate_limit(payload, state)

      # Tokens should not be consumed
      assert new_state.bucket.tokens == state.bucket.tokens
    end

    test "consumes tokens for normal operations" do
      {:ok, state} = DeribitRateLimitHandler.rate_limit_init(%{})
      initial_tokens = state.bucket.tokens

      # Create a regular query operation
      payload = %{"method" => "public/get_time"}

      # Process the request
      {:allow, new_state} = DeribitRateLimitHandler.check_rate_limit(payload, state)

      # Should consume 1 token (query cost)
      assert new_state.bucket.tokens == initial_tokens - 1
    end

    test "tracks requests with IDs in response_handlers" do
      {:ok, state} = DeribitRateLimitHandler.rate_limit_init(%{})

      # Create a request with an ID
      payload = %{"method" => "public/get_time", "id" => 12_345}

      # Process the request
      {:allow, new_state} = DeribitRateLimitHandler.check_rate_limit(payload, state)

      # The request should be tracked in response_handlers
      assert Map.has_key?(new_state.response_handlers, 12_345)
      assert new_state.response_handlers[12_345].op_type == :query
    end

    test "applies backoff when tokens are depleted" do
      # Initialize with empty bucket
      {:ok, state} = DeribitRateLimitHandler.rate_limit_init(%{})
      state = put_in(state.bucket.tokens, 0)

      # Request should be rejected due to rate limiting
      payload = %{"method" => "public/get_time"}
      {decision, delay, _new_state} = DeribitRateLimitHandler.check_rate_limit(payload, state)

      # Verify decision and delay
      assert decision in [:queue, :reject]
      assert is_integer(delay)
      assert delay > 0
    end
  end

  describe "handle_tick/1" do
    test "processes 429 responses and applies backoff" do
      {:ok, state} = DeribitRateLimitHandler.rate_limit_init(%{})
      initial_capacity = state.bucket.capacity
      initial_refill_rate = state.bucket.refill_rate

      # Add a 429 response to recent_responses
      responses = [%{"error" => %{"code" => 10_429, "message" => "Rate limit exceeded"}}]
      state = Map.put(state, :recent_responses, responses)

      # Process the tick
      {:ok, new_state} = DeribitRateLimitHandler.handle_tick(state)

      # Verify backoff was applied
      assert new_state.adaptive.backoff_multiplier > 1.0
      assert new_state.bucket.capacity < initial_capacity
      assert new_state.bucket.refill_rate < initial_refill_rate
      assert new_state.bucket.tokens == 0
      assert new_state.adaptive.last_429 != nil

      # Recent responses should be cleared
      assert new_state.recent_responses == []
    end

    test "refills tokens during normal operation" do
      {:ok, state} = DeribitRateLimitHandler.rate_limit_init(%{})

      # Set tokens to half capacity to test refill
      state = put_in(state.bucket.tokens, div(state.bucket.capacity, 2))

      # Set last_refill to a time in the past
      past_time = DeribitRateLimitHandler.current_time_ms() - 5000
      state = put_in(state.bucket.last_refill, past_time)

      # Initialize recent_responses as an empty list
      state = Map.put(state, :recent_responses, [])

      # Process the tick
      {:ok, new_state} = DeribitRateLimitHandler.handle_tick(state)

      # Tokens should be refilled
      assert new_state.bucket.tokens > state.bucket.tokens

      # Should not exceed capacity
      assert new_state.bucket.tokens <= state.bucket.capacity
    end
  end
end
