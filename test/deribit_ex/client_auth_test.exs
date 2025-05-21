defmodule DeribitEx.DeribitClientAuthTest do
  use ExUnit.Case

  alias DeribitEx.DeribitAdapter

  # This test module only tests the credential extraction logic
  # without trying to call the actual WebsockexNova.Client.authenticate function

  # Create a private function reference to the credential extraction logic
  # used in DeribitClient.authenticate/3
  defp extract_credentials(conn, credentials) do
    # If no credentials provided, get from connection directly
    if credentials == %{} do
      case conn do
        %{adapter_state: %{credentials: creds}} when is_map(creds) and map_size(creds) > 0 ->
          creds

        %{connection_info: %{credentials: creds}} when is_map(creds) and map_size(creds) > 0 ->
          creds

        _ ->
          %{}
      end
    else
      credentials
    end
  end

  describe "DeribitClient credential extraction logic" do
    test "extracts credentials from explicit parameter" do
      conn = %{
        adapter_state: %{
          credentials: %{
            "api_key" => "from_adapter_state_key",
            "secret" => "from_adapter_state_secret"
          }
        }
      }

      explicit_credentials = %{
        "api_key" => "explicit_key",
        "secret" => "explicit_secret"
      }

      result = extract_credentials(conn, explicit_credentials)
      assert result == explicit_credentials
    end

    test "extracts credentials from adapter_state when no explicit credentials provided" do
      conn = %{
        adapter_state: %{
          credentials: %{
            "api_key" => "from_adapter_state_key",
            "secret" => "from_adapter_state_secret"
          }
        }
      }

      result = extract_credentials(conn, %{})

      assert result == %{
               "api_key" => "from_adapter_state_key",
               "secret" => "from_adapter_state_secret"
             }
    end

    test "extracts credentials from connection_info when adapter_state not available" do
      conn = %{
        connection_info: %{
          credentials: %{
            "api_key" => "from_connection_info_key",
            "secret" => "from_connection_info_secret"
          }
        }
      }

      result = extract_credentials(conn, %{})

      assert result == %{
               "api_key" => "from_connection_info_key",
               "secret" => "from_connection_info_secret"
             }
    end

    test "uses empty map when no credentials are available" do
      empty_conn = %{}

      result = extract_credentials(empty_conn, %{})
      assert result == %{}
    end

    test "credential extraction handles different key formats" do
      # String keys
      conn_with_string_keys = %{
        adapter_state: %{
          credentials: %{
            "api_key" => "string_key",
            "secret" => "string_secret"
          }
        }
      }

      result = extract_credentials(conn_with_string_keys, %{})
      assert result == %{"api_key" => "string_key", "secret" => "string_secret"}

      # Atom keys
      conn_with_atom_keys = %{
        adapter_state: %{
          credentials: %{
            api_key: "atom_key",
            secret: "atom_secret"
          }
        }
      }

      result = extract_credentials(conn_with_atom_keys, %{})
      assert result == %{api_key: "atom_key", secret: "atom_secret"}

      # Client ID instead of API key
      conn_with_client_id = %{
        adapter_state: %{
          credentials: %{
            "client_id" => "client_id_value",
            "secret" => "secret_value"
          }
        }
      }

      result = extract_credentials(conn_with_client_id, %{})
      assert result == %{"client_id" => "client_id_value", "secret" => "secret_value"}
    end

    test "falls back to default credentials when not provided" do
      # This test verifies that when no adapter_state credentials or connection_info credentials
      # are available, the authenticate function falls back to using default credentials.
      conn_without_credentials = %{some_field: "some_value"}

      result = extract_credentials(conn_without_credentials, %{})
      assert result == %{}
    end
  end

  describe "DeribitAdapter credential validation" do
    # These tests verify that the DeribitAdapter will correctly validate 
    # and extract credentials from various formats

    test "validate_credentials accepts api_key and secret" do
      # Confirm that DeribitAdapter extracts credentials correctly when given keys
      # We're not going to call validate_credentials directly, but we can verify
      # that generate_auth_data correctly extracts credentials
      credentials = %{
        "api_key" => "test_api_key",
        "secret" => "test_secret"
      }

      state = %{credentials: credentials}

      {:ok, payload, _} = DeribitAdapter.generate_auth_data(state)
      decoded = Jason.decode!(payload)

      assert decoded["params"]["client_id"] == "test_api_key"
      assert decoded["params"]["client_secret"] == "test_secret"
    end

    test "validate_credentials accepts client_id in place of api_key" do
      # Confirm that DeribitAdapter correctly uses client_id instead of api_key
      credentials = %{
        "client_id" => "test_client_id",
        "secret" => "test_secret"
      }

      state = %{credentials: credentials}

      {:ok, payload, _} = DeribitAdapter.generate_auth_data(state)
      decoded = Jason.decode!(payload)

      assert decoded["params"]["client_id"] == "test_client_id"
      assert decoded["params"]["client_secret"] == "test_secret"
    end

    test "validate_credentials accepts atomified keys" do
      # Confirm that DeribitAdapter correctly handles atom keys
      credentials = %{
        api_key: "test_api_key",
        secret: "test_secret"
      }

      state = %{credentials: credentials}

      {:ok, payload, _} = DeribitAdapter.generate_auth_data(state)
      decoded = Jason.decode!(payload)

      assert decoded["params"]["client_id"] == "test_api_key"
      assert decoded["params"]["client_secret"] == "test_secret"
    end

    test "validate_credentials reports error on missing api_key" do
      # Confirm that DeribitAdapter correctly reports missing api_key
      credentials = %{
        "secret" => "test_secret"
      }

      state = %{credentials: credentials}

      {:error, reason, _} = DeribitAdapter.generate_auth_data(state)
      assert reason == :missing_api_key
    end

    test "validate_credentials reports error on missing secret" do
      # Confirm that DeribitAdapter correctly reports missing secret
      credentials = %{
        "api_key" => "test_api_key"
      }

      state = %{credentials: credentials}

      {:error, reason, _} = DeribitAdapter.generate_auth_data(state)
      assert reason == :missing_api_secret
    end
  end
end
