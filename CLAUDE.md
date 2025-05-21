# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Essential Commands

### Build and Dependencies
```bash
# Install dependencies
mix deps.get

# Compile the project
mix compile
```

### Testing
```bash
# Run all tests
mix test

# Run a specific test file
mix test test/path/to/file_test.exs

# Run a specific test by line number
mix test test/path/to/file_test.exs:42

# Run tests with specific tags
mix test --only integration
mix test --only unit

# Exclude specific tags
mix test --exclude skip

# Combining tags
mix test --only integration --exclude external
```

### Code Quality
```bash
# Run code analysis
mix credo

# Run type checking
mix dialyzer

# Generate documentation
mix docs
```

## Project Architecture

DeribitEx is an Elixir library for interacting with the Deribit cryptocurrency exchange API via WebSockets. It handles authentication, request/response management, subscriptions, rate limiting, and time synchronization.

### Key Components

1. **Client (`DeribitEx.Client`)**: High-level API interface that provides user-friendly methods for interacting with Deribit.

2. **Adapter (`DeribitEx.Adapter`)**: Implements the WebsockexNova adapter protocol, handling low-level WebSocket communication and message routing.

3. **RPC (`DeribitEx.RPC`)**: Manages JSON-RPC message formatting, request generation, and response parsing.

4. **TokenManager (`DeribitEx.TokenManager`)**: Manages authentication tokens including refreshing, exchanging, and forking tokens.

5. **SessionContext (`DeribitEx.SessionContext`)**: Tracks session state throughout authentication transitions.

6. **ResubscriptionHandler (`DeribitEx.ResubscriptionHandler`)**: Automatically resubscribes to channels after reconnection or authentication changes.

7. **TimeSyncService (`DeribitEx.TimeSyncService`)**: Synchronizes local and server time to ensure accurate timestamps.

8. **RateLimitHandler (`DeribitEx.RateLimitHandler`)**: Implements adaptive rate limiting to avoid 429 errors.

9. **OrderContext (`DeribitEx.OrderContext`)**: Preserves order state during session transitions.

### Data Flow

1. User calls methods on `DeribitEx.Client`
2. Client formats parameters and delegates to WebsockexNova.Client
3. WebsockexNova.Client uses DeribitEx.Adapter for WebSocket operations
4. DeribitEx.RPC generates standardized JSON-RPC messages
5. Responses flow back through the adapter to the client
6. Subscription notifications are sent to registered callback processes

## Key Workflows

### Connection and Authentication

1. **Connection Establishment**:
   ```elixir
   {:ok, client} = DeribitEx.Client.connect(client_id, client_secret)
   ```
   - Connects to WebSocket endpoint
   - Executes bootstrap sequence (hello, get_time, set_heartbeat)
   - Performs authentication
   - Enables cancel-on-disconnect for safety

2. **Authentication Flow**:
   - Initial auth via credentials
   - Automatic token refresh before expiration
   - Support for token exchange (switching subaccounts)
   - Support for token forking (named sessions)

### Subscriptions and Requests

1. **Making Requests**:
   ```elixir
   {:ok, response} = DeribitEx.Client.get_instruments(client, %{currency: "BTC"})
   ```
   - Request is formatted by RPC module
   - Rate limiting is applied
   - Response is parsed and returned

2. **Subscriptions**:
   ```elixir
   {:ok, sub_id} = DeribitEx.Client.subscribe_book(client, "BTC-PERPETUAL", callback_pid)
   ```
   - Subscribe to public or private channels
   - Notifications sent to callback process
   - Automatic resubscription after reconnection
   - Unsubscribe operations (single, multiple, or all channels)

### Safety Features

1. **Heartbeat Management**:
   - Automatic heartbeat setup during bootstrap
   - Detects stale connections

2. **Rate Limiting**:
   - Adaptive rate limiting responding to 429 errors
   - Automatic request queuing when approaching limits

3. **Time Synchronization**:
   - Periodic time sync with server
   - Uses time offset for accurate timestamps

## Environment Configuration

The library requires Deribit API credentials for authentication:

- `DERIBIT_CLIENT_ID` - API client ID
- `DERIBIT_CLIENT_SECRET` - API client secret
- `DERIBIT_TEST_MODE` - Set to "true" to use the test API endpoint

For testing, these environment variables should be set. Many integration tests connect to Deribit's test API and have longer timeouts (30-60 seconds).

## Telemetry Events

The library emits telemetry events throughout its operation. Key events include:

- `[:deribit_ex, :request, :start]` - When a request begins
- `[:deribit_ex, :request, :stop]` - When a request completes
- `[:deribit_ex, :subscription, :notification]` - When a subscription notification is received
- `[:deribit_ex, :auth, :refresh]` - When authentication is refreshed
- `[:deribit_ex, :rate_limit, :delay]` - When a request is delayed due to rate limiting

## Common Patterns and Notes

1. **Subscription Callbacks**: When subscribing to channels, always provide a valid PID that implements `handle_info/2` to process notifications.

2. **Error Handling**: The library returns `{:ok, result}` or `{:error, reason}` tuples consistently.

3. **Session Management**: Token operations (refresh, exchange, fork) preserve subscriptions and order context.

4. **Request Timeout**: Default request timeout is 5 seconds but can be overridden per request.

5. **Testing**: Tests are categorized with tags (:unit, :integration, :external). Some tests are marked with :skip tag.

6. **Rate Limiting Modes**: The library supports three rate limiting modes:
   - `:cautious` - Strict limits to avoid 429s completely
   - `:normal` - Balanced approach (default)
   - `:aggressive` - Higher throughput, might get occasional 429s