defmodule SymphonyElixir.GitHub.GitPush do
  @moduledoc """
  Configures GitHub App workspace identity and performs constrained host-side pushes.
  """

  alias SymphonyElixir.{Config, PathSafety, Workspace}
  alias SymphonyElixir.GitHub.Auth
  alias SymphonyElixir.Tracker.Issue

  @type push_result :: %{branch: String.t(), head_sha: String.t()}

  @spec prepare_workspace(Path.t(), map(), keyword()) :: :ok | {:error, term()}
  def prepare_workspace(workspace, tracker_settings, opts \\ []) when is_binary(workspace) do
    provider = Map.get(tracker_settings, :provider, %{})
    repository = provider["repo"]
    identity_fun = Keyword.get(opts, :identity_fun, &Auth.identity/1)

    with {:ok, auth} <- Auth.config(provider, repository) do
      configure_app_identity(workspace, auth, identity_fun)
    end
  end

  @spec push(map(), keyword()) :: {:ok, push_result()} | {:error, term()}
  def push(arguments, opts) when is_map(arguments) and is_list(opts) do
    tracker_settings = Keyword.get(opts, :tracker_settings, %{})
    provider = Map.get(tracker_settings, :provider, %{})
    repository = provider["repo"]
    workspace = Keyword.get(opts, :workspace)
    workspace_root = Keyword.get_lazy(opts, :workspace_root, &Config.local_workspace_root/0)
    issue = Keyword.get(opts, :issue)
    worker_host = Keyword.get(opts, :worker_host)
    branch = arguments["branch"]
    expected_sha = arguments["head_sha"]
    token_fun = Keyword.get(opts, :token_fun, &Auth.token/1)
    push_runner = Keyword.get(opts, :push_runner, &run_authenticated_push/3)

    with :ok <- validate_local_worker(worker_host),
         :ok <- validate_workspace(workspace, workspace_root, issue),
         :ok <- validate_branch(branch, issue),
         :ok <- validate_sha(expected_sha),
         {:ok, current_branch} <- git(workspace, ["branch", "--show-current"]),
         true <- current_branch == branch or {:error, :github_push_branch_mismatch},
         {:ok, head_sha} <- git(workspace, ["rev-parse", "HEAD"]),
         true <- head_sha == String.downcase(expected_sha) or {:error, :github_push_head_mismatch},
         {:ok, ""} <- git(workspace, ["status", "--porcelain"]),
         {:ok, remote_url} <- git(workspace, ["remote", "get-url", "origin"]),
         :ok <- validate_remote(remote_url, repository),
         {:ok, %{kind: :github_app} = auth} <- Auth.config(provider, repository),
         {:ok, token} <- token_fun.(auth),
         {:ok, _output} <- push_runner.(workspace, branch, token) do
      {:ok, %{branch: branch, head_sha: head_sha}}
    else
      {:ok, dirty} when is_binary(dirty) and dirty != "" -> {:error, :github_push_dirty_workspace}
      {:ok, %{kind: :token}} -> {:error, :github_app_required_for_push}
      {:error, _reason} = error -> error
      false -> {:error, :invalid_github_push}
      _ -> {:error, :github_push_failed}
    end
  end

  def push(_arguments, _opts), do: {:error, :invalid_github_push_arguments}

  defp configure_app_identity(_workspace, %{kind: :token}, _identity_fun), do: :ok

  defp configure_app_identity(workspace, %{kind: :github_app} = auth, identity_fun) do
    with {:ok, %{id: id, login: login}} <- identity_fun.(auth),
         true <- is_integer(id) and id > 0 and is_binary(login),
         {:ok, _} <- git(workspace, ["config", "--local", "user.name", login]),
         {:ok, _} <-
           git(workspace, [
             "config",
             "--local",
             "user.email",
             "#{id}+#{login}@users.noreply.github.com"
           ]),
         {:ok, _} <- git(workspace, ["config", "--local", "credential.helper", ""]) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_github_app_identity}
    end
  end

  defp validate_local_worker(nil), do: :ok
  defp validate_local_worker(_worker_host), do: {:error, :github_app_push_unsupported_on_ssh_worker}

  defp validate_workspace(workspace, workspace_root, %Issue{} = issue)
       when is_binary(workspace) and is_binary(workspace_root) do
    expected = Path.expand(Path.join(workspace_root, Workspace.workspace_key(issue)))

    with {:ok, real_workspace} <- PathSafety.canonicalize(workspace),
         {:ok, real_root} <- PathSafety.canonicalize(workspace_root),
         true <- real_workspace == expected,
         true <- Path.dirname(real_workspace) == real_root do
      :ok
    else
      _ -> {:error, :invalid_github_push_workspace}
    end
  end

  defp validate_workspace(_workspace, _workspace_root, _issue),
    do: {:error, :invalid_github_push_workspace}

  defp validate_branch(branch, %Issue{native_ref: %{"number" => issue_number}})
       when is_binary(branch) and is_integer(issue_number) do
    if String.match?(branch, ~r/^symphony\/gh-#{issue_number}-[a-z0-9][a-z0-9-]*$/),
      do: :ok,
      else: {:error, :invalid_github_push_branch}
  end

  defp validate_branch(_branch, _issue), do: {:error, :invalid_github_push_branch}

  defp validate_sha(sha) when is_binary(sha) do
    if String.match?(sha, ~r/^[0-9a-f]{40}$/i), do: :ok, else: {:error, :invalid_github_push_sha}
  end

  defp validate_sha(_sha), do: {:error, :invalid_github_push_sha}

  defp validate_remote(remote_url, repository) when is_binary(repository) do
    expected = "https://github.com/#{repository}"
    normalized = String.trim_trailing(remote_url, ".git")
    if normalized == expected, do: :ok, else: {:error, :github_push_remote_mismatch}
  end

  defp validate_remote(_remote_url, _repository), do: {:error, :github_push_remote_mismatch}

  defp git(workspace, arguments) do
    case System.cmd("git", arguments, cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, _status} -> {:error, :github_git_command_failed}
    end
  rescue
    _ -> {:error, :github_git_command_failed}
  end

  defp run_authenticated_push(workspace, branch, token) do
    askpass_root =
      Path.join(System.tmp_dir!(), "symphony-git-askpass-#{System.unique_integer([:positive])}")

    askpass = Path.join(askpass_root, "askpass")

    try do
      File.mkdir_p!(askpass_root)
      File.chmod!(askpass_root, 0o700)

      File.write!(
        askpass,
        "#!/usr/bin/env sh\ncase \"$1\" in *Username*) printf '%s\\n' \"$SYMPHONY_GIT_USERNAME\" ;; *) printf '%s\\n' \"$SYMPHONY_GIT_PASSWORD\" ;; esac\n"
      )

      File.chmod!(askpass, 0o700)

      env = [
        {"GIT_ASKPASS", askpass},
        {"GIT_ASKPASS_REQUIRE", "force"},
        {"GIT_TERMINAL_PROMPT", "0"},
        {"SYMPHONY_GIT_USERNAME", "x-access-token"},
        {"SYMPHONY_GIT_PASSWORD", token}
      ]

      case System.cmd(
             "git",
             ["-c", "credential.helper=", "push", "origin", "HEAD:refs/heads/#{branch}"],
             cd: workspace,
             env: env,
             stderr_to_stdout: true
           ) do
        {output, 0} -> {:ok, output}
        {_output, status} -> {:error, {:github_git_push_failed, status}}
      end
    after
      File.rm_rf(askpass_root)
    end
  rescue
    _ -> {:error, :github_git_push_failed}
  end
end
