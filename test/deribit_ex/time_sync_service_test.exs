defmodule DeribitEx.TimeSyncServiceTest do
  use ExUnit.Case, async: true

  alias DeribitEx.TimeSyncService

  # Mock client for testing
  defmodule MockClient do
    @moduledoc false
    use GenServer

    def start_link(_) do
      GenServer.start_link(__MODULE__, %{})
    end

    def init(state) do
      {:ok, state}
    end

    # Mock get_time implementation that returns a fixed server time
    def get_time(_client_pid, _opts \\ nil) do
      # Fixed server time that's 5000ms ahead of local time
      server_time = System.system_time(:millisecond) + 5000
      {:ok, server_time}
    end

    def handle_call(_, _from, state) do
      {:reply, :ok, state}
    end
  end

  describe "Time sync service" do
    setup do
      # Start a mock client
      {:ok, client_pid} = MockClient.start_link([])

      # Override the module reference to use our mock
      original_deribit_client = Application.get_env(:market_maker, :deribit_client_module)
      Application.put_env(:market_maker, :deribit_client_module, MockClient)

      # Start the time sync service
      {:ok, service_pid} = TimeSyncService.start_link(client_pid, sync_interval: 1000)

      # Wait a bit for the initial sync to complete
      Process.sleep(100)

      on_exit(fn ->
        # Reset the original module if it was set
        if original_deribit_client do
          Application.put_env(:market_maker, :deribit_client_module, original_deribit_client)
        else
          Application.delete_env(:market_maker, :deribit_client_module)
        end
      end)

      {:ok, %{service: service_pid, client: client_pid}}
    end

    test "calculates correct time delta", %{service: service} do
      # Our mock returns server time that's 5000ms ahead
      # The delta should be approximately 5000ms, allowing for some small variation
      delta = TimeSyncService.get_time_delta(service)
      assert_in_delta delta, 5000, 100
    end

    test "converts local time to server time", %{service: service} do
      local_time = System.system_time(:millisecond)
      server_time = TimeSyncService.local_to_server(local_time, service)
      assert_in_delta server_time, local_time + 5000, 100
    end

    test "converts server time to local time", %{service: service} do
      server_time = System.system_time(:millisecond) + 5000
      local_time = TimeSyncService.server_to_local(server_time, service)
      assert_in_delta local_time, server_time - 5000, 100
    end

    test "gets current server time", %{service: service} do
      server_time = TimeSyncService.server_time(service)
      expected_time = System.system_time(:millisecond) + 5000
      assert_in_delta server_time, expected_time, 100
    end

    test "provides sync info", %{service: service} do
      info = TimeSyncService.sync_info(service)
      assert Map.has_key?(info, :delta)
      assert Map.has_key?(info, :last_sync)
      assert is_integer(info.delta)
      assert is_integer(info.last_sync)
    end

    test "forces immediate sync", %{service: service} do
      # Get initial sync info
      initial_info = TimeSyncService.sync_info(service)

      # Force a new sync
      :ok = TimeSyncService.sync_now(service)

      # Wait briefly for sync to complete
      Process.sleep(50)

      # Get updated sync info
      updated_info = TimeSyncService.sync_info(service)

      # Last sync timestamp should be updated
      assert updated_info.last_sync > initial_info.last_sync
    end
  end
end
