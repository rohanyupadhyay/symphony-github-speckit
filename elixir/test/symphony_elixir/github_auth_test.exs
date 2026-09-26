defmodule SymphonyElixir.GitHub.AuthTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GitHub.{Auth, Client, WorkflowControl}

  setup do
    temp_root = Path.join(System.tmp_dir!(), "symphony-github-auth-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_root)
    key_path = Path.join(temp_root, "private-key.pem")
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])
    File.write!(key_path, pem)
    File.chmod!(key_path, 0o600)
    on_exit(fn -> File.rm_rf(temp_root) end)
    %{key_path: key_path, private_key: private_key}
  end

  test "normalizes legacy tokens and GitHub App credentials", %{key_path: key_path} do
    assert {:ok, %{kind: :token, token: "pat-token"}} =
             Auth.config(%{"token" => " pat-token "}, "octo/repo")

    provider = %{
      "auth" => %{
        "kind" => "github_app",
        "app_id" => "123",
        "installation_id" => 456,
        "private_key_path" => key_path
      }
    }

    assert {:ok,
            %{
              kind: :github_app,
              app_id: 123,
              installation_id: 456,
              private_key_path: ^key_path,
              repository: "octo/repo"
            }} = Auth.config(provider, "octo/repo")
  end

  test "rejects incomplete App credentials and insecure private-key permissions", %{key_path: key_path} do
    assert {:error, :missing_github_app_id} =
             Auth.config(
               %{
                 "auth" => %{
                   "kind" => "github_app",
                   "installation_id" => 456,
                   "private_key_path" => key_path
                 }
               },
               "octo/repo"
             )

    File.chmod!(key_path, 0o644)

    assert {:error, :insecure_github_app_private_key_permissions} =
             Auth.config(
               %{
                 "auth" => %{
                   "kind" => "github_app",
                   "app_id" => 123,
                   "installation_id" => 456,
                   "private_key_path" => key_path
                 }
               },
               "octo/repo"
             )
  end

  test "creates a verifiable short-lived RS256 App JWT", %{key_path: key_path, private_key: private_key} do
    auth = %{
      kind: :github_app,
      app_id: 123,
      installation_id: 456,
      private_key_path: key_path,
      repository: "octo/repo"
    }

    assert {:ok, jwt} = Auth.app_jwt(auth, now: 1_700_000_000)
    [header64, payload64, signature64] = String.split(jwt, ".")

    assert Jason.decode!(Base.url_decode64!(header64, padding: false)) == %{
             "alg" => "RS256",
             "typ" => "JWT"
           }

    assert Jason.decode!(Base.url_decode64!(payload64, padding: false)) == %{
             "exp" => 1_700_000_540,
             "iat" => 1_699_999_940,
             "iss" => "123"
           }

    public_key = {:RSAPublicKey, elem(private_key, 2), elem(private_key, 3)}

    assert :public_key.verify(
             header64 <> "." <> payload64,
             :sha256,
             Base.url_decode64!(signature64, padding: false),
             public_key
           )
  end

  test "declares App credential environment references as secrets" do
    provider = %{
      "auth" => %{
        "kind" => "github_app",
        "app_id" => "$MY_APP_ID",
        "installation_id" => "$MY_INSTALLATION_ID",
        "private_key_path" => "$MY_PRIVATE_KEY_PATH"
      }
    }

    assert Auth.secret_environment_names(provider) == [
             "GITHUB_APP_ID",
             "GITHUB_APP_INSTALLATION_ID",
             "GITHUB_APP_PRIVATE_KEY_PATH",
             "GITHUB_APP_PRIVATE_KEY",
             "MY_APP_ID",
             "MY_INSTALLATION_ID",
             "MY_PRIVATE_KEY_PATH"
           ]
  end

  test "exchanges and caches repository-scoped installation tokens", %{key_path: key_path} do
    auth = app_auth(key_path)
    counter = start_supervised!({Agent, fn -> 0 end})

    request_fun = fn "POST", "/app/installations/456/access_tokens", headers, body, "https://api.github.com" ->
      assert Enum.any?(headers, fn {name, value} -> name == "Authorization" and String.starts_with?(value, "Bearer ") end)
      assert body == %{"repositories" => ["repo"]}
      Agent.update(counter, &(&1 + 1))

      {:ok,
       %{
         status: 201,
         body: %{"token" => "installation-token", "expires_at" => "2026-09-26T02:00:00Z"}
       }}
    end

    opts = [request_fun: request_fun, now: ~U[2026-09-26 01:00:00Z]]
    assert {:ok, "installation-token"} = Auth.token(auth, opts)
    assert {:ok, "installation-token"} = Auth.token(auth, opts)
    assert Agent.get(counter, & &1) == 1

    assert :ok = Auth.invalidate(auth)
    assert {:ok, "installation-token"} = Auth.token(auth, opts)
    assert Agent.get(counter, & &1) == 2
  end

  test "discovers and caches the authoritative App bot identity", %{key_path: key_path} do
    auth = app_auth(key_path)
    counter = start_supervised!({Agent, fn -> 0 end})

    request_fun = fn
      "GET", "/app", _headers, nil, "https://api.github.com" ->
        Agent.update(counter, &(&1 + 1))
        {:ok, %{status: 200, body: %{"slug" => "verity-symphony"}}}

      "POST", "/app/installations/456/access_tokens", _headers, %{"repositories" => ["repo"]}, "https://api.github.com" ->
        {:ok,
         %{
           status: 201,
           body: %{"token" => "installation-token", "expires_at" => "2026-09-26T02:00:00Z"}
         }}

      "GET", "/users/verity-symphony%5Bbot%5D", headers, nil, "https://api.github.com" ->
        assert {"Authorization", "Bearer installation-token"} in headers
        {:ok, %{status: 200, body: %{"id" => 987, "login" => "verity-symphony[bot]", "type" => "Bot"}}}
    end

    opts = [request_fun: request_fun, now: ~U[2026-09-26 01:00:00Z]]

    assert {:ok, %{id: 987, login: "verity-symphony[bot]", slug: "verity-symphony"}} =
             Auth.identity(auth, opts)

    assert {:ok, %{id: 987, login: "verity-symphony[bot]", slug: "verity-symphony"}} =
             Auth.identity(auth, opts)

    assert Agent.get(counter, & &1) == 1
  end

  test "GitHub client retries one 401 with a refreshed App installation token", %{key_path: key_path} do
    tracker_settings = app_tracker_settings(key_path)
    exchanges = :counters.new(1, [])
    requests = :counters.new(1, [])

    auth_request_fun = fn "POST", "/app/installations/456/access_tokens", _headers, _body, _api_url ->
      :counters.add(exchanges, 1, 1)
      exchange = :counters.get(exchanges, 1)

      {:ok,
       %{
         status: 201,
         body: %{"token" => "installation-token-#{exchange}", "expires_at" => "2026-09-26T02:00:00Z"}
       }}
    end

    transport_fun = fn "GET", "https://api.github.com/repos/octo/repo", headers, %{}, nil ->
      :counters.add(requests, 1, 1)
      request = :counters.get(requests, 1)
      assert {"Authorization", "Bearer installation-token-#{request}"} in headers

      if request == 1,
        do: {:ok, %{status: 401, body: %{"message" => "expired"}}},
        else: {:ok, %{status: 200, body: %{"full_name" => "octo/repo"}}}
    end

    assert {:ok, %{status: 200, body: %{"full_name" => "octo/repo"}}} =
             Client.perform_request_for_test(
               "GET",
               "/repos/octo/repo",
               %{},
               nil,
               tracker_settings,
               transport_fun,
               auth_request_fun,
               ~U[2026-09-26 01:00:00Z]
             )

    assert :counters.get(exchanges, 1) == 2
    assert :counters.get(requests, 1) == 2
  end

  test "client reconstruction trusts only the configured App bot checkpoint", %{key_path: key_path} do
    issue =
      Client.normalize_issue_for_test(
        %{
          "number" => 42,
          "id" => 1_042,
          "title" => "App checkpoint",
          "body" => "Body",
          "state" => "open",
          "labels" => [%{"name" => "symphony"}]
        },
        "octo/repo"
      )

    checkpoint_body =
      WorkflowControl.render_comment(%{
        "state" => "blocked",
        "phase" => "setup",
        "summary" => "Waiting"
      })

    request_fun = fn "GET", "/repos/octo/repo/issues/42/comments", %{"page" => 1, "per_page" => 100}, nil, _settings ->
      {:ok,
       %{
         status: 200,
         body: [
           %{
             "id" => 1,
             "body" => checkpoint_body,
             "author_association" => "NONE",
             "user" => %{"login" => "verity-symphony[bot]", "type" => "Bot"}
           }
         ]
       }}
    end

    identity_fun = fn _auth ->
      {:ok, %{id: 987, login: "verity-symphony[bot]", slug: "verity-symphony"}}
    end

    settings =
      app_tracker_settings(key_path)
      |> put_in(
        [:provider, "workflow_control"],
        %{"enabled" => true, "authorized_associations" => ["OWNER"]}
      )

    assert {:ok, enriched} =
             Client.enrich_issue_for_test(issue, settings, request_fun, identity_fun: identity_fun)

    refute enriched.dispatchable
    assert get_in(enriched.native_ref, ["workflow_control", "state"]) == "blocked"
  end

  defp app_auth(key_path) do
    %{
      kind: :github_app,
      app_id: 123,
      installation_id: 456,
      private_key_path: key_path,
      repository: "octo/repo",
      api_url: "https://api.github.com"
    }
  end

  defp app_tracker_settings(key_path) do
    %{
      kind: "github",
      provider: %{
        "repo" => "octo/repo",
        "auth" => %{
          "kind" => "github_app",
          "app_id" => 123,
          "installation_id" => 456,
          "private_key_path" => key_path
        }
      },
      active_states: ["open"],
      terminal_states: ["closed"]
    }
  end
end
