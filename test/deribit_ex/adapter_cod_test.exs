defmodule MarketMaker.WS.DeribitAdapterCODTest do
  use ExUnit.Case, async: true

  alias MarketMaker.WS.DeribitAdapter

  describe "generate_enable_cod_data/2" do
    setup do
      {:ok, state} = DeribitAdapter.init(%{})
      state = Map.put(state, :access_token, "test_token")
      %{state: state}
    end

    test "generates correct payload with default scope", %{state: state} do
      params = %{}
      {:ok, payload, updated_state} = DeribitAdapter.generate_enable_cod_data(params, state)

      # Decode the payload to verify its structure
      decoded = Jason.decode!(payload)

      assert decoded["method"] == "private/enable_cancel_on_disconnect"
      assert decoded["params"]["scope"] == "connection"
      assert decoded["params"]["access_token"] == "test_token"

      # Check that state was updated
      assert updated_state.cod_enabled == true
      assert updated_state.cod_scope == "connection"
    end

    test "generates correct payload with custom scope", %{state: state} do
      params = %{"scope" => "account"}
      {:ok, payload, updated_state} = DeribitAdapter.generate_enable_cod_data(params, state)

      # Decode the payload to verify its structure
      decoded = Jason.decode!(payload)

      assert decoded["method"] == "private/enable_cancel_on_disconnect"
      assert decoded["params"]["scope"] == "account"
      assert decoded["params"]["access_token"] == "test_token"

      # Check that state was updated
      assert updated_state.cod_enabled == true
      assert updated_state.cod_scope == "account"
    end

    test "raises error with invalid scope", %{state: state} do
      params = %{"scope" => "invalid_scope"}

      assert_raise RuntimeError, ~r/Invalid scope for cancel_on_disconnect/, fn ->
        DeribitAdapter.generate_enable_cod_data(params, state)
      end
    end

    test "raises error when not authenticated", %{state: state} do
      state = Map.delete(state, :access_token)
      params = %{}

      assert_raise RuntimeError, ~r/Cannot enable cancel_on_disconnect/, fn ->
        DeribitAdapter.generate_enable_cod_data(params, state)
      end
    end
  end

  describe "handle_enable_cod_response/2" do
    setup do
      {:ok, state} = DeribitAdapter.init(%{})
      state = Map.put(state, :cod_scope, "connection")
      %{state: state}
    end

    test "handles successful response", %{state: state} do
      response = %{"result" => "ok"}

      # Set up telemetry handler to catch events
      test_pid = self()

      :ok =
        :telemetry.attach(
          "test-cod-enabled",
          [:market_maker, :adapter, :cod, :enabled],
          fn event_name, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event_name, measurements, metadata})
          end,
          nil
        )

      on_exit(fn ->
        :telemetry.detach("test-cod-enabled")
      end)

      {:ok, updated_state} = DeribitAdapter.handle_enable_cod_response(response, state)

      # Check that state remains the same (cod_enabled was already set in generate_enable_cod_data)
      assert updated_state == state

      # Verify telemetry was emitted
      assert_received {:telemetry, [:market_maker, :adapter, :cod, :enabled], %{system_time: _}, metadata}
      assert metadata.scope == "connection"
    end

    test "handles error response", %{state: state} do
      error = %{"code" => 10_001, "message" => "Error enabling COD"}
      response = %{"error" => error}

      # Set up telemetry handler to catch events
      test_pid = self()

      :ok =
        :telemetry.attach(
          "test-cod-failure",
          [:market_maker, :adapter, :cod, :failure],
          fn event_name, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event_name, measurements, metadata})
          end,
          nil
        )

      on_exit(fn ->
        :telemetry.detach("test-cod-failure")
      end)

      {:error, returned_error, updated_state} = DeribitAdapter.handle_enable_cod_response(response, state)

      # Check that state was updated
      assert updated_state.cod_enabled == false
      assert returned_error == error

      # Verify telemetry was emitted
      assert_received {:telemetry, [:market_maker, :adapter, :cod, :failure], %{system_time: _}, metadata}
      assert metadata.error == error
    end
  end

  describe "generate_disable_cod_data/2" do
    setup do
      {:ok, state} = DeribitAdapter.init(%{})

      state =
        Map.merge(state, %{
          access_token: "test_token",
          cod_enabled: true,
          cod_scope: "connection"
        })

      %{state: state}
    end

    test "generates correct payload with default scope", %{state: state} do
      params = %{}
      {:ok, payload, updated_state} = DeribitAdapter.generate_disable_cod_data(params, state)

      # Decode the payload to verify its structure
      decoded = Jason.decode!(payload)

      assert decoded["method"] == "private/disable_cancel_on_disconnect"
      assert decoded["params"]["scope"] == "connection"
      assert decoded["params"]["access_token"] == "test_token"

      # State not yet changed (only on successful response)
      assert updated_state.cod_enabled == true
    end

    test "generates correct payload with custom scope", %{state: state} do
      params = %{"scope" => "account"}
      {:ok, payload, updated_state} = DeribitAdapter.generate_disable_cod_data(params, state)

      # Decode the payload to verify its structure
      decoded = Jason.decode!(payload)

      assert decoded["method"] == "private/disable_cancel_on_disconnect"
      assert decoded["params"]["scope"] == "account"
      assert decoded["params"]["access_token"] == "test_token"

      # State not yet changed (only on successful response)
      assert updated_state.cod_enabled == true
    end

    test "raises error when not authenticated", %{state: state} do
      state = Map.delete(state, :access_token)
      params = %{}

      assert_raise RuntimeError, ~r/Cannot disable cancel_on_disconnect/, fn ->
        DeribitAdapter.generate_disable_cod_data(params, state)
      end
    end
  end

  describe "handle_disable_cod_response/2" do
    setup do
      {:ok, state} = DeribitAdapter.init(%{})

      state =
        Map.merge(state, %{
          cod_enabled: true,
          cod_scope: "connection"
        })

      %{state: state}
    end

    test "handles successful response", %{state: state} do
      response = %{"result" => "ok"}

      # Set up telemetry handler to catch events
      test_pid = self()

      :ok =
        :telemetry.attach(
          "test-cod-disabled",
          [:market_maker, :adapter, :cod, :disabled],
          fn event_name, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event_name, measurements, metadata})
          end,
          nil
        )

      on_exit(fn ->
        :telemetry.detach("test-cod-disabled")
      end)

      {:ok, updated_state} = DeribitAdapter.handle_disable_cod_response(response, state)

      # Check that state was updated
      assert updated_state.cod_enabled == false

      # Verify telemetry was emitted
      assert_received {:telemetry, [:market_maker, :adapter, :cod, :disabled], %{system_time: _}, metadata}
      assert metadata.scope == "connection"
    end

    test "handles error response", %{state: state} do
      error = %{"code" => 10_001, "message" => "Error disabling COD"}
      response = %{"error" => error}

      # Set up telemetry handler to catch events
      test_pid = self()

      :ok =
        :telemetry.attach(
          "test-cod-failure",
          [:market_maker, :adapter, :cod, :failure],
          fn event_name, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event_name, measurements, metadata})
          end,
          nil
        )

      on_exit(fn ->
        :telemetry.detach("test-cod-failure")
      end)

      {:error, returned_error, updated_state} = DeribitAdapter.handle_disable_cod_response(response, state)

      # Check that state remains unchanged
      assert updated_state.cod_enabled == true
      assert returned_error == error

      # Verify telemetry was emitted
      assert_received {:telemetry, [:market_maker, :adapter, :cod, :failure], %{system_time: _}, metadata}
      assert metadata.error == error
    end
  end

  describe "generate_get_cod_data/2" do
    setup do
      {:ok, state} = DeribitAdapter.init(%{})
      state = Map.put(state, :access_token, "test_token")
      %{state: state}
    end

    test "generates correct payload", %{state: state} do
      params = %{}
      {:ok, payload, updated_state} = DeribitAdapter.generate_get_cod_data(params, state)

      # Decode the payload to verify its structure
      decoded = Jason.decode!(payload)

      assert decoded["method"] == "private/get_cancel_on_disconnect"
      assert decoded["params"]["access_token"] == "test_token"

      # The request is tracked in state, so we can't compare the whole state
      # Instead, check that specific state fields remain unchanged
      assert updated_state.access_token == state.access_token
      assert updated_state.auth_status == state.auth_status

      # Verify that a request was added to state
      assert Map.has_key?(updated_state.requests, decoded["id"])
      assert updated_state.requests[decoded["id"]].method == "private/get_cancel_on_disconnect"
    end

    test "raises error when not authenticated", %{state: state} do
      state = Map.delete(state, :access_token)
      params = %{}

      assert_raise RuntimeError, ~r/Cannot get cancel_on_disconnect status/, fn ->
        DeribitAdapter.generate_get_cod_data(params, state)
      end
    end
  end

  describe "handle_get_cod_response/2" do
    setup do
      {:ok, state} = DeribitAdapter.init(%{})
      %{state: state}
    end

    test "handles successful response with enabled COD", %{state: state} do
      response = %{"result" => %{"enabled" => true, "scope" => "connection"}}

      # Set up telemetry handler to catch events
      test_pid = self()

      :ok =
        :telemetry.attach(
          "test-cod-status",
          [:market_maker, :adapter, :cod, :status],
          fn event_name, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event_name, measurements, metadata})
          end,
          nil
        )

      on_exit(fn ->
        :telemetry.detach("test-cod-status")
      end)

      {:ok, updated_state} = DeribitAdapter.handle_get_cod_response(response, state)

      # Check that state was updated
      assert updated_state.cod_enabled == true
      assert updated_state.cod_scope == "connection"

      # Verify telemetry was emitted
      assert_received {:telemetry, [:market_maker, :adapter, :cod, :status], %{system_time: _}, metadata}
      assert metadata.enabled == true
      assert metadata.scope == "connection"
    end

    test "handles successful response with disabled COD", %{state: state} do
      response = %{"result" => %{"enabled" => false, "scope" => "account"}}

      # Set up telemetry handler to catch events
      test_pid = self()

      :ok =
        :telemetry.attach(
          "test-cod-status",
          [:market_maker, :adapter, :cod, :status],
          fn event_name, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event_name, measurements, metadata})
          end,
          nil
        )

      on_exit(fn ->
        :telemetry.detach("test-cod-status")
      end)

      {:ok, updated_state} = DeribitAdapter.handle_get_cod_response(response, state)

      # Check that state was updated
      assert updated_state.cod_enabled == false
      assert updated_state.cod_scope == "account"

      # Verify telemetry was emitted
      assert_received {:telemetry, [:market_maker, :adapter, :cod, :status], %{system_time: _}, metadata}
      assert metadata.enabled == false
      assert metadata.scope == "account"
    end

    test "handles error response", %{state: state} do
      error = %{"code" => 10_001, "message" => "Error getting COD status"}
      response = %{"error" => error}

      # Set up telemetry handler to catch events
      test_pid = self()

      :ok =
        :telemetry.attach(
          "test-cod-failure",
          [:market_maker, :adapter, :cod, :failure],
          fn event_name, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event_name, measurements, metadata})
          end,
          nil
        )

      on_exit(fn ->
        :telemetry.detach("test-cod-failure")
      end)

      {:error, returned_error, updated_state} = DeribitAdapter.handle_get_cod_response(response, state)

      # Check that state remains unchanged
      assert updated_state == state
      assert returned_error == error

      # Verify telemetry was emitted
      assert_received {:telemetry, [:market_maker, :adapter, :cod, :failure], %{system_time: _}, metadata}
      assert metadata.error == error
    end
  end
end
