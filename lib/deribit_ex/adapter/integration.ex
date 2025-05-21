defmodule DeribitEx.AdapterIntegration do
  @moduledoc """
  Integration file to add token management to Adapter.

  This module provides a structured approach to patching Adapter with
  token management functionality. Using this approach ensures better migration
  control than directly modifying Adapter.ex.

  ## Usage

  Add the following line to the application.ex start function to apply patches:

  ```elixir
  DeribitEx.AdapterIntegration.apply_patches()
  ```
  """

  require Logger

  @doc """
  Applies all token management patches to Adapter.

  This function would set up function replacements, but for now it's just
  a placeholder since the :meck library is not included in the project.
  """
  @spec apply_patches() :: :ok
  def apply_patches do
    # Log that we need to add :meck to dependencies
    Logger.info("Adapter token management patches require :meck library")
    Logger.info("Add {:meck, \"~> 0.9.2\"} to your dependencies in mix.exs")

    # Do nothing until :meck is available
    :ok
  end

  @doc """
  Gets tracked request using response ID.

  Helper function for integration tests.
  """
  @spec get_tracked_request(String.t() | integer(), map()) :: map()
  def get_tracked_request(request_id, state) do
    get_in(state, [:requests, request_id]) || %{}
  end

  @doc """
  Checks if a message is an auth response.

  Helper function for integration tests.
  """
  @spec is_auth_response?(map() | any()) :: boolean()
  def is_auth_response?(message) when is_map(message) do
    Map.has_key?(message, "method") && message["method"] == "public/auth" &&
      Map.has_key?(message, "result") && Map.has_key?(message["result"] || %{}, "access_token")
  end

  def is_auth_response?(_), do: false
end
