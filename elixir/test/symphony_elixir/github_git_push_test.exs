defmodule SymphonyElixir.GitHub.GitPushTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.GitPush
  alias SymphonyElixir.Tracker.Issue

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-git-push-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "GH-42")
    File.mkdir_p!(workspace)
    git!(workspace, ["init", "--initial-branch", "symphony/gh-42-add-auth"])
    git!(workspace, ["config", "user.name", "Test User"])
    git!(workspace, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(workspace, "README.md"), "initial\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", "initial"])
    git!(workspace, ["remote", "add", "origin", "https://github.com/octo/repo.git"])
    head_sha = git!(workspace, ["rev-parse", "HEAD"])

    key_path = Path.join(root, "private-key.pem")
    File.write!(key_path, "test-only")
    File.chmod!(key_path, 0o600)

    issue = %Issue{
      id: "42",
      identifier: "GH-42",
      title: "Add auth",
      state: "open",
      native_ref: %{"number" => 42, "repo" => "octo/repo"}
    }

    settings = %{
      kind: "github",
      provider: %{
        "repo" => "octo/repo",
        "auth" => %{
          "kind" => "github_app",
          "app_id" => 123,
          "installation_id" => 456,
          "private_key_path" => key_path
        }
      }
    }

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, workspace: workspace, head_sha: head_sha, issue: issue, settings: settings}
  end

  test "configures App bot commit identity and disables inherited credentials", context do
    identity_fun = fn _auth ->
      {:ok, %{id: 987, login: "verity-symphony[bot]", slug: "verity-symphony"}}
    end

    assert :ok =
             GitPush.prepare_workspace(context.workspace, context.settings, identity_fun: identity_fun)

    assert git!(context.workspace, ["config", "user.name"]) == "verity-symphony[bot]"

    assert git!(context.workspace, ["config", "user.email"]) ==
             "987+verity-symphony[bot]@users.noreply.github.com"

    assert git!(context.workspace, ["config", "credential.helper"]) == ""
  end

  test "pushes only the current clean issue branch and never returns the token", context do
    parent = self()

    runner = fn workspace, remote_url, branch, token ->
      send(parent, {:push, workspace, remote_url, branch, token})
      {:ok, "pushed"}
    end

    assert {:ok, %{branch: "symphony/gh-42-add-auth", head_sha: head_sha}} =
             GitPush.push(
               %{"branch" => "symphony/gh-42-add-auth", "head_sha" => context.head_sha},
               tracker_settings: context.settings,
               workspace: context.workspace,
               workspace_root: context.root,
               issue: context.issue,
               token_fun: fn _auth -> {:ok, "short-lived-secret"} end,
               push_runner: runner
             )

    assert head_sha == context.head_sha
    assert_received {:push, workspace, "https://github.com/octo/repo.git", "symphony/gh-42-add-auth", "short-lived-secret"}

    assert workspace == context.workspace
    refute inspect(%{branch: "symphony/gh-42-add-auth", head_sha: head_sha}) =~ "short-lived-secret"
  end

  test "rejects unsafe workspace, worker, branch, SHA, dirty tree, and remote", context do
    base_opts = [
      tracker_settings: context.settings,
      workspace: context.workspace,
      workspace_root: context.root,
      issue: context.issue,
      token_fun: fn _auth -> flunk("invalid pushes must not mint a token") end,
      push_runner: fn _, _, _, _ -> flunk("invalid pushes must not run git push") end
    ]

    arguments = %{"branch" => "symphony/gh-42-add-auth", "head_sha" => context.head_sha}

    assert {:error, :github_app_push_unsupported_on_ssh_worker} =
             GitPush.push(arguments, Keyword.put(base_opts, :worker_host, "worker.example"))

    assert {:error, :invalid_github_push_workspace} =
             GitPush.push(arguments, Keyword.put(base_opts, :workspace, Path.dirname(context.workspace)))

    assert {:error, :invalid_github_push_branch} =
             GitPush.push(%{arguments | "branch" => "main"}, base_opts)

    assert {:error, :github_push_head_mismatch} =
             GitPush.push(%{arguments | "head_sha" => String.duplicate("a", 40)}, base_opts)

    File.write!(Path.join(context.workspace, "dirty.txt"), "dirty")
    assert {:error, :github_push_dirty_workspace} = GitPush.push(arguments, base_opts)
    File.rm!(Path.join(context.workspace, "dirty.txt"))

    git!(context.workspace, ["remote", "set-url", "origin", "https://github.com/octo/other.git"])
    assert {:error, :github_push_remote_mismatch} = GitPush.push(arguments, base_opts)
  end

  test "uses the validated fetch URL even when origin has a different push URL", context do
    git!(context.workspace, [
      "remote",
      "set-url",
      "--push",
      "origin",
      "https://github.com/attacker/other.git"
    ])

    parent = self()

    assert {:ok, _result} =
             GitPush.push(
               %{"branch" => "symphony/gh-42-add-auth", "head_sha" => context.head_sha},
               tracker_settings: context.settings,
               workspace: context.workspace,
               workspace_root: context.root,
               issue: context.issue,
               token_fun: fn _auth -> {:ok, "short-lived-secret"} end,
               push_runner: fn workspace, remote_url, branch, _token ->
                 send(parent, {:push_target, workspace, remote_url, branch})
                 {:ok, "pushed"}
               end
             )

    assert_received {:push_target, workspace, "https://github.com/octo/repo.git", "symphony/gh-42-add-auth"}

    assert workspace == context.workspace
  end

  defp git!(workspace, args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end
end
