defmodule DeribitEx.TimeSyncService do
  @moduledoc """
  A dedicated service for maintaining and tracking the time delta between the local system
  and the Deribit server. This service periodically synchronizes with the Deribit server time
  to ensure accurate timing for operations that depend on server time.

  ## Features
    * Periodically polls the server time to calculate time drift
    * Provides functions to convert between local and server time
    * Automatically adjusts for network latency in time calculations
    * Uses a GenServer with configurable synchronization interval

  ## Usage
    ```elixir
    # Start the service
    {:ok, pid} = TimeSyncService.start_link(client_pid)

    # Get the current server time (in milliseconds)
    server_time_ms = TimeSyncService.server_time()

    # Convert local time to server time
    server_time = TimeSyncService.local_to_server(System.system_time(:millisecond))

    # Convert server time to local time
    local_time = TimeSyncService.server_to_local(server_time_ms)
    ```
  """

  use GenServer

  alias DeribitEx.DeribitClient

  # Default synchronization interval in milliseconds (5 minutes)
  @default_sync_interval 300_000

  @doc """
  Starts the TimeSyncService linked to the caller.

  ## Parameters
    * `client_pid` - The PID of the DeribitClient connection
    * `opts` - Options for the time sync service:
      * `:sync_interval` - Interval between time syncs in milliseconds (default: 300_000 ms / 5 minutes)
      * `:name` - Optional registration name for the server

  ## Returns
    * `{:ok, pid}` - The PID of the started service
    * `{:error, reason}` - If the service could not be started
  """
  def start_link(client_pid, opts \\ []) do
    interval = Keyword.get(opts, :sync_interval, @default_sync_interval)
    name = Keyword.get(opts, :name, __MODULE__)

    GenServer.start_link(
      __MODULE__,
      %{
        client_pid: client_pid,
        interval: interval,
        delta: 0,
        last_sync: nil
      },
      name: name
    )
  end

  @doc """
  Gets the current estimated server time in milliseconds since epoch.

  ## Returns
    * The current server time in milliseconds
  """
  def server_time(server \\ __MODULE__) do
    local_to_server(System.system_time(:millisecond), server)
  end

  @doc """
  Converts a local timestamp to the corresponding server timestamp.

  ## Parameters
    * `local_time_ms` - Local time in milliseconds since epoch
    * `server` - The TimeSyncService server (default: __MODULE__)

  ## Returns
    * The corresponding server time in milliseconds
  """
  def local_to_server(local_time_ms, server \\ __MODULE__) do
    delta = get_time_delta(server)
    local_time_ms + delta
  end

  @doc """
  Converts a server timestamp to the corresponding local timestamp.

  ## Parameters
    * `server_time_ms` - Server time in milliseconds since epoch
    * `server` - The TimeSyncService server (default: __MODULE__)

  ## Returns
    * The corresponding local time in milliseconds
  """
  def server_to_local(server_time_ms, server \\ __MODULE__) do
    delta = get_time_delta(server)
    server_time_ms - delta
  end

  @doc """
  Gets the current time delta between local and server time in milliseconds.

  ## Parameters
    * `server` - The TimeSyncService server (default: __MODULE__)

  ## Returns
    * The time delta in milliseconds (server_time - local_time)
    * Returns 0 if the service has not yet successfully synchronized
  """
  def get_time_delta(server \\ __MODULE__) do
    GenServer.call(server, :get_delta)
  end

  @doc """
  Forces an immediate time synchronization.

  ## Parameters
    * `server` - The TimeSyncService server (default: __MODULE__)

  ## Returns
    * `:ok` - Synchronization request was submitted
  """
  def sync_now(server \\ __MODULE__) do
    GenServer.cast(server, :sync_now)
  end

  @doc """
  Returns information about the last synchronization.

  ## Parameters
    * `server` - The TimeSyncService server (default: __MODULE__)

  ## Returns
    * A map containing `:delta` and `:last_sync` (timestamp of last successful sync)
    * Returns nil for `:last_sync` if no successful synchronization has occurred yet
  """
  def sync_info(server \\ __MODULE__) do
    GenServer.call(server, :sync_info)
  end

  # GenServer callbacks

  @impl true
  def init(state) do
    # Schedule immediate initial sync
    Process.send_after(self(), :sync_time, 0)
    # Schedule periodic sync
    schedule_sync(state.interval)
    {:ok, state}
  end

  @impl true
  def handle_call(:get_delta, _from, state) do
    {:reply, state.delta, state}
  end

  @impl true
  def handle_call(:sync_info, _from, state) do
    {:reply, %{delta: state.delta, last_sync: state.last_sync}, state}
  end

  @impl true
  def handle_cast(:sync_now, state) do
    # Perform immediate sync
    new_state = perform_sync(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:sync_time, state) do
    # Perform the sync operation
    new_state = perform_sync(state)
    # Schedule next sync
    schedule_sync(state.interval)
    {:noreply, new_state}
  end

  # Private functions

  # Schedule the next sync operation
  defp schedule_sync(interval) do
    Process.send_after(self(), :sync_time, interval)
  end

  # Perform time synchronization with the server
  defp perform_sync(state) do
    # Record the local time before request
    local_before = System.system_time(:millisecond)

    # Get the client module - either the configured one for testing or DeribitClient
    client_module = Application.get_env(:deribit_ex, :deribit_client_module, DeribitClient)

    # Skip during tests or when connection isn't valid
    if is_pid(state.client_pid) and Process.alive?(state.client_pid) do
      case client_module.get_time(state.client_pid) do
        {:ok, server_time} ->
          # Record the local time after request
          local_after = System.system_time(:millisecond)
          # Calculate network latency (assuming symmetrical latency)
          latency = div(local_after - local_before, 2)
          # Adjust server time by subtracting latency
          adjusted_server_time = server_time - latency
          # Calculate the delta (server_time - local_time)
          delta = adjusted_server_time - local_before

          # Emit telemetry for successful time sync
          :telemetry.execute(
            [:deribit_ex, :time_sync, :success],
            %{
              delta: delta,
              latency: latency,
              system_time: System.system_time(:millisecond)
            },
            %{
              client_pid: state.client_pid
            }
          )

          # Update state with new delta and last sync timestamp
          %{state | delta: delta, last_sync: System.system_time(:millisecond)}

        {:error, reason} ->
          # Emit telemetry for failed time sync
          :telemetry.execute(
            [:deribit_ex, :time_sync, :failure],
            %{system_time: System.system_time(:millisecond)},
            %{
              client_pid: state.client_pid,
              reason: reason
            }
          )

          # Keep existing delta but update failure telemetry
          state
      end
    else
      # Return existing state if connection is not valid
      state
    end
  end
end
