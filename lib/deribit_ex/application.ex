defmodule DeribitEx.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Registry for tracking connections and processes
      {Registry, keys: :unique, name: DeribitEx.Registry},

      # Time sync supervisor for managing time synchronization with Deribit
      {DeribitEx.TimeSyncSupervisor, []}
    ]

    opts = [strategy: :one_for_one, name: DeribitEx.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
