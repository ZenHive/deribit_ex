defmodule DeribitEx.TimeSyncSupervisor do
  @moduledoc """
  Supervisor for the TimeSyncService.

  This supervisor is responsible for starting and supervising TimeSyncService
  processes. It ensures that the services restart properly if they crash.
  """

  use DynamicSupervisor

  alias DeribitEx.TimeSyncService

  @doc """
  Starts the TimeSyncSupervisor.

  ## Returns
    * `{:ok, pid}` - The PID of the started supervisor
    * `{:error, reason}` - If the supervisor could not be started
  """
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Starts a new TimeSyncService for a given client connection.

  ## Parameters
    * `client_pid` - The PID of the DeribitClient connection
    * `opts` - Options for the time sync service (passed to TimeSyncService.start_link/2)

  ## Returns
    * `{:ok, pid}` - The PID of the started service
    * `{:error, reason}` - If the service could not be started
  """
  def start_service(client_pid, opts \\ []) do
    # Generate a unique name based on the client PID hash
    name = service_name(client_pid)
    opts = Keyword.put(opts, :name, name)

    # Start the service under the supervisor
    child_spec = {TimeSyncService, [client_pid, opts]}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Gets the TimeSyncService for a specific client connection.

  ## Parameters
    * `client_pid` - The PID of the DeribitClient connection

  ## Returns
    * The name of the TimeSyncService for the given client
  """
  def service_name(client_pid) do
    # We use a fixed name and register the client PIDs in a registry
    # to avoid atom table issues with long PID strings
    :"TimeSyncService_#{:erlang.phash2(client_pid)}"
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
