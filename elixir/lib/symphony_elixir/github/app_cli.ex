defmodule SymphonyElixir.GitHub.AppCLI do
  @moduledoc """
  Operator commands for creating, validating, and loading GitHub App profiles.
  """

  alias SymphonyElixir.GitHub.AppProfile

  @type deps :: %{
          puts: (String.t() -> term()),
          gets: (String.t() -> String.t() | nil),
          open_url: (String.t() -> :ok | {:error, term()}),
          create: (String.t(), String.t(), pos_integer(), pos_integer(), Path.t() ->
                     {:ok, map()} | {:error, term()}),
          load: (String.t() -> {:ok, map()} | {:error, term()}),
          verify: (map(), String.t() -> {:ok, map()} | {:error, term()}),
          environment: (String.t() -> {:ok, [{String.t(), String.t()}]} | {:error, term()})
        }

  @spec run([String.t()], deps()) :: :ok | {:error, term()}
  def run(args, deps \\ runtime_deps()) do
    case args do
      ["setup" | rest] -> setup(rest, deps)
      ["verify" | rest] -> verify(rest, deps)
      ["env" | rest] -> environment(rest, deps)
      _ -> {:error, usage_message()}
    end
  end

  defp setup(args, deps) do
    case OptionParser.parse(args, strict: [profile: :string, name: :string]) do
      {opts, [repository], []} ->
        profile_name = Keyword.get(opts, :profile, "default")
        app_name = Keyword.get(opts, :name, default_app_name())
        registration_url = AppProfile.registration_url(repository, app_name)

        deps.puts.("Symphony Plus will open GitHub to register a private App. Download its private key, install it on #{repository}, and keep the key outside every repository.")

        deps.puts.(registration_url)
        _ = deps.open_url.(registration_url)

        with {:ok, app_id} <- prompt_positive_id(deps, "GitHub App ID: ", :invalid_github_app_id),
             {:ok, installation_id} <-
               prompt_positive_id(
                 deps,
                 "Installation ID from the App installation URL: ",
                 :invalid_github_app_installation_id
               ),
             {:ok, key_path} <- prompt_text(deps, "Downloaded private-key .pem path: "),
             {:ok, profile} <-
               deps.create.(repository, profile_name, app_id, installation_id, key_path) do
          deps.puts.("Created profile #{profile_name} for #{profile.bot_login}.")
          :ok
        end

      _ ->
        {:error, usage_message()}
    end
  end

  defp verify(args, deps) do
    case OptionParser.parse(args, strict: [profile: :string]) do
      {opts, [repository], []} ->
        profile_name = Keyword.get(opts, :profile, "default")

        with {:ok, profile} <- deps.load.(profile_name),
             {:ok, %{login: login}} <- deps.verify.(profile, repository) do
          deps.puts.("Verified #{login} for #{repository}.")
          :ok
        end

      _ ->
        {:error, usage_message()}
    end
  end

  defp environment(args, deps) do
    case OptionParser.parse(args, strict: [profile: :string]) do
      {opts, [], []} ->
        profile_name = Keyword.get(opts, :profile, "default")

        with {:ok, values} <- deps.environment.(profile_name),
             true <- Enum.all?(values, fn {name, value} -> safe_env?(name, value) end) do
          Enum.each(values, fn {name, value} -> deps.puts.("#{name}=#{value}") end)
          :ok
        else
          false -> {:error, :invalid_github_app_profile_environment}
          {:error, _reason} = error -> error
        end

      _ ->
        {:error, usage_message()}
    end
  end

  defp prompt_positive_id(deps, prompt, error) do
    with {:ok, value} <- prompt_text(deps, prompt),
         {id, ""} when id > 0 <- Integer.parse(value) do
      {:ok, id}
    else
      _ -> {:error, error}
    end
  end

  defp prompt_text(deps, prompt) do
    case deps.gets.(prompt) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :missing_github_app_setup_input}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_github_app_setup_input}
    end
  end

  defp safe_env?(name, value) do
    is_binary(name) and String.match?(name, ~r/^[A-Z][A-Z0-9_]*$/) and is_binary(value) and
      not String.contains?(value, ["\n", "\r", <<0>>])
  end

  defp default_app_name do
    user = System.get_env("USER") || "Local"
    "Symphony Plus #{user}"
  end

  defp runtime_deps do
    %{
      puts: &IO.puts/1,
      gets: &IO.gets/1,
      open_url: &open_url/1,
      create: &AppProfile.create/5,
      load: &AppProfile.load/1,
      verify: &AppProfile.verify/2,
      environment: &AppProfile.environment/1
    }
  end

  defp open_url(url) do
    case System.find_executable("gh") do
      nil ->
        {:error, :github_cli_not_found}

      _path ->
        case System.cmd("gh", ["browse", url], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {_output, status} -> {:error, {:github_browser_open_failed, status}}
        end
    end
  rescue
    _ -> {:error, :github_browser_open_failed}
  end

  defp usage_message do
    "Usage: symphony github-app setup <owner/repo> [--profile <name>] [--name <app-name>] | verify <owner/repo> [--profile <name>] | env [--profile <name>]"
  end
end
