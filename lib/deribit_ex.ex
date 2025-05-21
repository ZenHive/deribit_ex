defmodule DeribitEx do
  @moduledoc """
  DeribitEx is an Elixir library for interacting with the Deribit cryptocurrency exchange API via WebSocket.
  
  This library handles the following:
  
  - Authentication and token management
  - WebSocket communication
  - JSON-RPC request/response formatting
  - Subscriptions and notifications
  - Rate limiting
  - Time synchronization
  - Cancel-on-disconnect safety
  
  The main entry point for most users will be `DeribitEx.DeribitClient`.
  
  ## Architecture
  
  DeribitEx consists of several components:
  
  - **DeribitClient**: High-level API interface for interacting with Deribit
  - **DeribitRPC**: Manages JSON-RPC message formatting and parsing
  - **DeribitAdapter**: Implements WebsockexNova adapter for WebSocket communication
  - **TokenManager**: Handles authentication token lifecycle
  - **ResubscriptionHandler**: Manages automatic channel resubscription
  - **TimeSyncService**: Synchronizes local and server time
  - **RateLimitHandler**: Implements adaptive rate limiting
  
  ## Usage Example
  
  ```elixir
  # Connect to Deribit
  {:ok, client} = DeribitEx.DeribitClient.connect(
    client_id: "your_client_id",
    client_secret: "your_client_secret"
  )
  
  # Make requests
  {:ok, instruments} = DeribitEx.DeribitClient.get_instruments(client, %{
    currency: "BTC"
  })
  
  # Subscribe to channels
  {:ok, sub_id} = DeribitEx.DeribitClient.subscribe_book(
    client,
    "BTC-PERPETUAL",
    self()
  )
  ```
  
  See the README and module documentation for more details.
  """

  @doc """
  Returns the current version of the DeribitEx library.

  ## Examples

      iex> DeribitEx.version()
      "0.1.0"
  """
  @spec version() :: String.t()
  def version, do: "0.1.0"
end