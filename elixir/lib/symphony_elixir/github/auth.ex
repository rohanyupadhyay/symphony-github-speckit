defmodule SymphonyElixir.GitHub.Auth do
  @moduledoc """
  Resolves GitHub credentials and creates short-lived GitHub App JWTs.

  Long-lived App private keys remain host-side. Installation tokens are
  obtained by `SymphonyElixir.GitHub.AuthCache` and are never included in
  tracker records or dynamic-tool payloads.
  """

  import Bitwise

  alias SymphonyElixir.GitHub.AuthCache

  @app_environment_names [
    "GITHUB_APP_ID",
    "GITHUB_APP_INSTALLATION_ID",
    "GITHUB_APP_PRIVATE_KEY_PATH",
    "GITHUB_APP_PRIVATE_KEY"
  ]

  @type token_config :: %{kind: :token, token: String.t()}
  @type app_config :: %{
          kind: :github_app,
          app_id: pos_integer(),
          installation_id: pos_integer(),
          private_key_path: Path.t(),
          repository: String.t(),
          api_url: String.t()
        }
  @type config :: token_config() | app_config()

  @spec config(map(), String.t()) :: {:ok, config()} | {:error, atom()}
  def config(provider, repository) when is_map(provider) and is_binary(repository) do
    case Map.get(provider, "auth") do
      nil ->
        token_config(provider)

      %{"kind" => "github_app"} = auth ->
        app_config(auth, repository, Map.get(provider, "api_url", "https://api.github.com"))

      _ ->
        {:error, :invalid_github_auth}
    end
  end

  @spec app_jwt(app_config(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def app_jwt(%{kind: :github_app} = auth, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)

    with {:ok, private_key} <- read_private_key(auth.private_key_path) do
      header = base64url(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}))

      payload =
        base64url(
          Jason.encode!(%{
            "iat" => now - 60,
            "exp" => now + 540,
            "iss" => Integer.to_string(auth.app_id)
          })
        )

      signing_input = header <> "." <> payload
      signature = :public_key.sign(signing_input, :sha256, private_key)
      {:ok, signing_input <> "." <> base64url(signature)}
    end
  end

  @spec token(config()) :: {:ok, String.t()} | {:error, term()}
  def token(auth), do: token(auth, [])

  @spec token(config(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def token(%{kind: :token, token: token}, _opts), do: {:ok, token}

  def token(%{kind: :github_app} = auth, opts) do
    now = now_datetime(opts)
    request_fun = Keyword.get(opts, :request_fun, &perform_request/5)

    AuthCache.fetch(token_cache_key(auth), DateTime.to_unix(now) + 300, fn ->
      exchange_installation_token(auth, request_fun, now)
    end)
  end

  @spec identity(app_config(), keyword()) ::
          {:ok, %{id: pos_integer(), login: String.t(), slug: String.t()}} | {:error, term()}
  def identity(%{kind: :github_app} = auth, opts \\ []) do
    now = now_datetime(opts)
    request_fun = Keyword.get(opts, :request_fun, &perform_request/5)

    with {:ok, installation_token} <- token(auth, opts) do
      AuthCache.fetch(identity_cache_key(auth), DateTime.to_unix(now), fn ->
        fetch_identity(auth, installation_token, request_fun, now)
      end)
    end
  end

  @spec invalidate(config()) :: :ok
  def invalidate(%{kind: :token}), do: :ok
  def invalidate(%{kind: :github_app} = auth), do: AuthCache.invalidate(token_cache_key(auth))

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(provider) when is_map(provider) do
    auth = Map.get(provider, "auth", %{})

    (@app_environment_names ++
       env_reference_names([
         auth["app_id"],
         auth["installation_id"],
         auth["private_key_path"]
       ]))
    |> Enum.uniq()
  end

  defp token_config(provider) do
    case resolve_token(provider["token"]) do
      nil -> {:error, :missing_github_token}
      token -> {:ok, %{kind: :token, token: token}}
    end
  end

  defp resolve_token(nil), do: normalize_string(System.get_env("GITHUB_TOKEN"))

  defp resolve_token("$" <> env_name) do
    if valid_env_name?(env_name) do
      normalize_string(System.get_env(env_name) || System.get_env("GITHUB_TOKEN"))
    end
  end

  defp resolve_token(value) when is_binary(value), do: normalize_string(value)
  defp resolve_token(_value), do: nil

  defp app_config(auth, repository, api_url) do
    with {:ok, app_id} <- resolve_positive_integer(auth["app_id"], "GITHUB_APP_ID", :missing_github_app_id),
         {:ok, installation_id} <-
           resolve_positive_integer(
             auth["installation_id"],
             "GITHUB_APP_INSTALLATION_ID",
             :missing_github_app_installation_id
           ),
         {:ok, private_key_path} <- resolve_private_key_path(auth["private_key_path"]) do
      {:ok,
       %{
         kind: :github_app,
         app_id: app_id,
         installation_id: installation_id,
         private_key_path: private_key_path,
         repository: repository,
         api_url: String.trim_trailing(api_url, "/")
       }}
    end
  end

  defp resolve_positive_integer(value, fallback_env, missing_error) do
    case resolve_string(value, fallback_env) do
      nil ->
        {:error, missing_error}

      candidate ->
        case Integer.parse(candidate) do
          {number, ""} when number > 0 -> {:ok, number}
          _ -> {:error, missing_error}
        end
    end
  end

  defp resolve_private_key_path(value) do
    case resolve_string(value, "GITHUB_APP_PRIVATE_KEY_PATH") do
      nil ->
        {:error, :missing_github_app_private_key_path}

      path ->
        expanded = Path.expand(path)

        case File.stat(expanded) do
          {:ok, %File.Stat{type: :regular, mode: mode}} when (mode &&& 0o077) == 0 ->
            {:ok, expanded}

          {:ok, %File.Stat{type: :regular}} ->
            {:error, :insecure_github_app_private_key_permissions}

          _ ->
            {:error, :invalid_github_app_private_key_path}
        end
    end
  end

  defp read_private_key(path) do
    with {:ok, pem} <- File.read(path),
         [entry | _] <- :public_key.pem_decode(pem) do
      {:ok, :public_key.pem_entry_decode(entry)}
    else
      _ -> {:error, :invalid_github_app_private_key}
    end
  rescue
    _ -> {:error, :invalid_github_app_private_key}
  end

  defp resolve_string(nil, fallback_env), do: normalize_string(System.get_env(fallback_env))

  defp resolve_string("$" <> env_name, fallback_env) do
    if valid_env_name?(env_name) do
      normalize_string(System.get_env(env_name) || System.get_env(fallback_env))
    end
  end

  defp resolve_string(value, _fallback_env), do: normalize_string(value)

  defp normalize_string(value) when is_integer(value), do: Integer.to_string(value)

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp env_reference_names(values) do
    Enum.flat_map(values, fn
      "$" <> env_name -> if valid_env_name?(env_name), do: [env_name], else: []
      _ -> []
    end)
  end

  defp valid_env_name?(name), do: String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
  defp base64url(value), do: Base.url_encode64(value, padding: false)

  defp exchange_installation_token(auth, request_fun, now) do
    repository = auth.repository |> String.split("/", parts: 2) |> List.last()

    with {:ok, jwt} <- app_jwt(auth, now: DateTime.to_unix(now)),
         {:ok, %{status: 201, body: %{"token" => token, "expires_at" => expires_at}}} <-
           request_fun.(
             "POST",
             "/app/installations/#{auth.installation_id}/access_tokens",
             headers(jwt),
             %{"repositories" => [repository]},
             auth.api_url
           ),
         true <- is_binary(token),
         {:ok, expiration, _offset} <- DateTime.from_iso8601(expires_at) do
      {:ok, token, DateTime.to_unix(expiration)}
    else
      {:ok, %{status: status}} -> {:error, {:github_app_token_status, status}}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_github_app_token_response}
    end
  end

  defp fetch_identity(auth, installation_token, request_fun, now) do
    with {:ok, jwt} <- app_jwt(auth, now: DateTime.to_unix(now)),
         {:ok, %{status: 200, body: %{"slug" => slug}}} <-
           request_fun.("GET", "/app", headers(jwt), nil, auth.api_url),
         login = slug <> "[bot]",
         encoded_login = URI.encode(login, &URI.char_unreserved?/1),
         {:ok, %{status: 200, body: %{"id" => id, "login" => ^login, "type" => "Bot"}}} <-
           request_fun.(
             "GET",
             "/users/#{encoded_login}",
             headers(installation_token),
             nil,
             auth.api_url
           ),
         true <- is_integer(id) and id > 0 do
      {:ok, %{id: id, login: login, slug: slug}, DateTime.to_unix(now) + 86_400}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_github_app_identity}
    end
  end

  defp perform_request(method, path, request_headers, body, api_url) do
    opts = [method: method, url: api_url <> path, headers: request_headers, connect_options: [timeout: 30_000]]
    opts = if is_nil(body), do: opts, else: Keyword.put(opts, :json, body)

    case Req.request(opts) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, reason} -> {:error, {:github_api_request, reason}}
    end
  end

  defp headers(token) do
    [
      {"Accept", "application/vnd.github+json"},
      {"Authorization", "Bearer #{token}"},
      {"X-GitHub-Api-Version", "2022-11-28"},
      {"User-Agent", "symphony-plus"}
    ]
  end

  defp now_datetime(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> now
      nil -> DateTime.utc_now()
    end
  end

  defp token_cache_key(auth),
    do: {:github_app_token, auth.api_url, auth.app_id, auth.installation_id, auth.repository, auth.private_key_path}

  defp identity_cache_key(auth),
    do: {:github_app_identity, auth.api_url, auth.app_id, auth.installation_id, auth.private_key_path}
end
