# DeribitEx

An Elixir library for interacting with the Deribit cryptocurrency exchange API via WebSocket.

[![Hex.pm](https://img.shields.io/hexpm/v/deribit_ex.svg)](https://hex.pm/packages/deribit_ex)
[![Documentation](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/deribit_ex)
[![License](https://img.shields.io/hexpm/l/deribit_ex.svg)](https://github.com/username/deribit_ex/blob/master/LICENSE)

## Features

- **WebSocket-based communication**: Efficient and real-time communication with Deribit API
- **Authentication management**: Automatic token refresh, exchange, and forking
- **Request/response handling**: Clean JSON-RPC implementation
- **Subscription management**: Easy subscription to public and private channels
- **Automatic resubscription**: After reconnection or authentication changes
- **Rate limiting**: Adaptive rate limiting to avoid 429 errors
- **Time synchronization**: Keeps local time in sync with server time
- **Cancel-on-disconnect**: Automatic setup of safety measures
- **Telemetry integration**: Comprehensive event instrumentation

## Installation

Add `deribit_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:deribit_ex, "~> 0.1.0"}
  ]
end
```

## Configuration

Configure your Deribit API credentials in your config:

```elixir
# config/config.exs
config :deribit_ex,
  client_id: System.get_env("DERIBIT_CLIENT_ID"),
  client_secret: System.get_env("DERIBIT_CLIENT_SECRET"),
  test_mode: true # Set to false for production API

# Optional settings
config :deribit_ex,
  rate_limit_mode: :normal, # Options: :cautious, :normal, :aggressive
  request_timeout: 5000     # Default timeout in milliseconds
```

Or provide credentials directly when connecting:

```elixir
{:ok, client} = DeribitEx.DeribitClient.connect(
  client_id: "your_client_id",
  client_secret: "your_client_secret",
  test_mode: true
)
```

## Usage Examples

### Connecting to Deribit

```elixir
# Connect with configured credentials
{:ok, client} = DeribitEx.DeribitClient.connect()

# Or connect with explicit credentials
{:ok, client} = DeribitEx.DeribitClient.connect(
  client_id: "your_client_id",
  client_secret: "your_client_secret"
)
```

### Making API Requests

```elixir
# Get available instruments
{:ok, instruments} = DeribitEx.DeribitClient.get_instruments(client, %{
  currency: "BTC",
  kind: "future"
})

# Get account summary
{:ok, summary} = DeribitEx.DeribitClient.get_account_summary(client, %{
  currency: "BTC"
})

# Place an order
{:ok, order} = DeribitEx.DeribitClient.buy(client, %{
  instrument_name: "BTC-PERPETUAL",
  amount: 100,
  type: "limit",
  price: 30000,
  post_only: true
})
```

### Subscriptions

```elixir
# Define a callback module
defmodule MyApp.DeribitHandler do
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{})
  end

  def init(state) do
    {:ok, state}
  end

  # Handle subscription notifications
  def handle_info({:deribit_notification, channel, data}, state) do
    IO.puts("Received notification from #{channel}")
    # Process the data
    {:noreply, state}
  end
end

# Start the handler
{:ok, handler_pid} = MyApp.DeribitHandler.start_link([])

# Subscribe to orderbook updates
{:ok, _sub_id} = DeribitEx.DeribitClient.subscribe_book(
  client,
  "BTC-PERPETUAL",
  handler_pid
)

# Subscribe to your account updates (requires authentication)
{:ok, _sub_id} = DeribitEx.DeribitClient.subscribe_user_orders(
  client,
  "BTC",
  handler_pid
)

# Unsubscribe when done
:ok = DeribitEx.DeribitClient.unsubscribe(client, sub_id)
```

### Token Management

```elixir
# Exchange your token to access a sub-account
{:ok, _new_client} = DeribitEx.DeribitClient.exchange_token(client, "subaccount_name")

# Create a named session
{:ok, _named_client} = DeribitEx.DeribitClient.fork_token(client, "session_name")
```

### Telemetry Events

DeribitEx emits telemetry events that you can handle in your application:

```elixir
:telemetry.attach(
  "deribit-request-handler",
  [:deribit_ex, :request, :stop],
  fn name, measurements, metadata, _config ->
    # Handle request completion event
  end,
  nil
)
```

Key events include:
- `[:deribit_ex, :request, :start]`
- `[:deribit_ex, :request, :stop]`
- `[:deribit_ex, :subscription, :notification]`
- `[:deribit_ex, :auth, :refresh]`
- `[:deribit_ex, :rate_limit, :delay]`

## Testing with Deribit Testnet

The library uses Deribit's testnet when `test_mode: true` is set. You can create a testnet account at [test.deribit.com](https://test.deribit.com/).

## Documentation

Full documentation is available at [HexDocs](https://hexdocs.pm/deribit_ex).

## License

DeribitEx is released under the MIT License. See the [LICENSE](LICENSE) file for details.