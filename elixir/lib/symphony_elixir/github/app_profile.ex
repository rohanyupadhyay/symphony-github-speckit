defmodule SymphonyElixir.GitHub.AppProfile do
  @moduledoc """
  Creates and loads host-local GitHub App profiles for Symphony Plus.
  """

  alias SymphonyElixir.GitHub.{Auth, AuthCache, Client}

  @type profile :: %{
          app_id: pos_integer(),
          installation_id: pos_integer(),
          private_key_path: Path.t(),
          bot_login: String.t()
        }

  @spec registration_url(String.t(), String.t()) :: String.t()
  def registration_url(_repository, app_name) do
    query =
      URI.encode_query(%{
        "name" => app_name,
        "description" => "GitHub automation identity for a self-hosted Symphony Plus installation",
        "url" => "https://github.com/rohanyupadhyay/symphony-plus",
        "public" => "false",
        "webhook_active" => "false",
        "contents" => "write",
        "issues" => "write",
        "pull_requests" => "write",
        "workflows" => "write"
      })

    "https://github.com/settings/apps/new?#{query}"
  end

  @spec create(String.t(), String.t(), integer(), integer(), Path.t(), keyword()) ::
          {:ok, profile()} | {:error, term()}
  def create(repository, name, app_id, installation_id, source_key_path, opts \\ []) do
    config_root = Keyword.get_lazy(opts, :config_root, &default_config_root/0)
    verify_fun = Keyword.get(opts, :verify_fun, &verify/2)

    with :ok <- validate_repository(repository),
         :ok <- validate_name(name),
         :ok <- validate_id(app_id, :invalid_github_app_id),
         :ok <- validate_id(installation_id, :invalid_github_app_installation_id),
         :ok <- validate_source_key(source_key_path),
         {:ok, target, staging} <- prepare_staging(config_root, name) do
      create_staged_profile(
        repository,
        target,
        staging,
        app_id,
        installation_id,
        source_key_path,
        verify_fun
      )
    end
  end

  @spec load(String.t(), keyword()) :: {:ok, profile()} | {:error, term()}
  def load(name, opts \\ []) do
    config_root = Keyword.get_lazy(opts, :config_root, &default_config_root/0)

    with :ok <- validate_name(name),
         path = Path.join(profile_root(config_root, name), "profile.json"),
         {:ok, json} <- File.read(path),
         {:ok,
          %{
            "app_id" => app_id,
            "installation_id" => installation_id,
            "private_key_path" => private_key_path,
            "bot_login" => bot_login
          }} <- Jason.decode(json),
         :ok <- validate_id(app_id, :invalid_github_app_id),
         :ok <- validate_id(installation_id, :invalid_github_app_installation_id),
         true <- is_binary(private_key_path) and File.regular?(private_key_path),
         true <- is_binary(bot_login) and bot_login != "" do
      {:ok,
       %{
         app_id: app_id,
         installation_id: installation_id,
         private_key_path: private_key_path,
         bot_login: bot_login
       }}
    else
      {:error, :enoent} -> {:error, :github_app_profile_not_found}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_github_app_profile}
    end
  end

  @spec environment(String.t(), keyword()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def environment(name, opts \\ []) do
    with {:ok, profile} <- load(name, opts) do
      {:ok,
       [
         {"GITHUB_APP_ID", Integer.to_string(profile.app_id)},
         {"GITHUB_APP_INSTALLATION_ID", Integer.to_string(profile.installation_id)},
         {"GITHUB_APP_PRIVATE_KEY_PATH", profile.private_key_path}
       ]}
    end
  end

  @spec verify(profile(), String.t()) :: {:ok, %{id: pos_integer(), login: String.t(), slug: String.t()}} | {:error, term()}
  def verify(profile, repository) do
    :ok = ensure_auth_cache()

    tracker_settings = %{
      kind: "github",
      provider: %{
        "repo" => repository,
        "auth" => %{
          "kind" => "github_app",
          "app_id" => profile.app_id,
          "installation_id" => profile.installation_id,
          "private_key_path" => profile.private_key_path
        }
      },
      active_states: ["open"],
      terminal_states: ["closed"]
    }

    with {:ok, auth} <- Auth.config(tracker_settings.provider, repository),
         {:ok, identity} <- Auth.identity(auth),
         {:ok, %{status: status}} <-
           Client.request("GET", "/repos/#{encoded_repo(repository)}", %{}, nil, tracker_settings: tracker_settings),
         true <- status in 200..299 do
      {:ok, identity}
    else
      {:ok, %{status: status}} -> {:error, {:github_app_repository_status, status}}
      {:error, _reason} = error -> error
      _ -> {:error, :github_app_verification_failed}
    end
  end

  defp create_staged_profile(
         repository,
         target,
         staging,
         app_id,
         installation_id,
         source_key_path,
         verify_fun
       ) do
    final_key_path = Path.join(target, "private-key.pem")
    staged_key_path = Path.join(staging, "private-key.pem")

    try do
      File.mkdir_p!(staging)
      File.chmod!(Path.dirname(target), 0o700)
      File.chmod!(staging, 0o700)
      File.cp!(source_key_path, staged_key_path)
      File.chmod!(staged_key_path, 0o600)

      candidate = %{
        app_id: app_id,
        installation_id: installation_id,
        private_key_path: staged_key_path,
        bot_login: ""
      }

      case verify_fun.(candidate, repository) do
        {:ok, %{login: login}} when is_binary(login) and login != "" ->
          final_profile = %{candidate | private_key_path: final_key_path, bot_login: login}
          profile_json = Path.join(staging, "profile.json")
          File.write!(profile_json, Jason.encode!(final_profile, pretty: true) <> "\n")
          File.chmod!(profile_json, 0o600)
          File.rename!(staging, target)
          {:ok, final_profile}

        {:error, _reason} = error ->
          File.rm_rf(staging)
          error

        _ ->
          File.rm_rf(staging)
          {:error, :github_app_verification_failed}
      end
    rescue
      error ->
        File.rm_rf(staging)
        {:error, {:github_app_profile_write_failed, Exception.message(error)}}
    end
  end

  defp prepare_staging(config_root, name) do
    profiles_root = Path.join([config_root, "symphony-plus", "github-apps"])
    target = Path.join(profiles_root, name)

    if File.exists?(target) do
      {:error, :github_app_profile_exists}
    else
      File.mkdir_p!(profiles_root)
      File.chmod!(Path.join(config_root, "symphony-plus"), 0o700)
      File.chmod!(profiles_root, 0o700)

      staging = target <> ".tmp-#{System.unique_integer([:positive])}"
      {:ok, target, staging}
    end
  rescue
    error -> {:error, {:github_app_profile_write_failed, Exception.message(error)}}
  end

  defp ensure_auth_cache do
    case Process.whereis(AuthCache) do
      nil ->
        case AuthCache.start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "could not start GitHub App auth cache: #{inspect(reason)}"
        end

      _pid ->
        :ok
    end
  end

  defp default_config_root do
    System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")
  end

  defp profile_root(config_root, name),
    do: Path.join([config_root, "symphony-plus", "github-apps", name])

  defp validate_name(name) when is_binary(name) do
    if String.match?(name, ~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/),
      do: :ok,
      else: {:error, :invalid_github_app_profile_name}
  end

  defp validate_name(_name), do: {:error, :invalid_github_app_profile_name}

  defp validate_repository(repository) when is_binary(repository) do
    if String.match?(repository, ~r/^[^\s\/]+\/[^\s\/]+$/),
      do: :ok,
      else: {:error, :invalid_github_repo}
  end

  defp validate_repository(_repository), do: {:error, :invalid_github_repo}

  defp validate_id(value, _error) when is_integer(value) and value > 0, do: :ok
  defp validate_id(_value, error), do: {:error, error}

  defp validate_source_key(path) when is_binary(path) do
    if File.regular?(path),
      do: :ok,
      else: {:error, :invalid_github_app_private_key_path}
  end

  defp validate_source_key(_path), do: {:error, :invalid_github_app_private_key_path}

  defp encoded_repo(repository) do
    repository
    |> String.split("/", parts: 2)
    |> Enum.map_join("/", &URI.encode(&1, fn char -> URI.char_unreserved?(char) end))
  end
end
