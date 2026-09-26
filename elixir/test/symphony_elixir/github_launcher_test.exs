defmodule SymphonyElixir.GitHubLauncherTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workflow

  test "GitHub Spec Kit template permits Git metadata writes in isolated workspaces" do
    template = Path.expand("../../examples/github-speckit-WORKFLOW.md", __DIR__)

    assert {:ok, workflow} = Workflow.load(template)
    assert get_in(workflow.config, ["codex", "thread_sandbox"]) == "danger-full-access"

    assert get_in(workflow.config, ["codex", "turn_sandbox_policy"]) == %{
             "type" => "dangerFullAccess"
           }
  end

  test "launcher supplies the gh token to Symphony without printing it" do
    temp_root =
      Path.join(System.tmp_dir!(), "symphony-github-launcher-#{System.unique_integer([:positive])}")

    bin_dir = Path.join(temp_root, "bin")
    output_path = Path.join(temp_root, "output")
    File.mkdir_p!(bin_dir)

    File.write!(
      Path.join(bin_dir, "gh"),
      "#!/usr/bin/env bash\nprintf '%s' 'test-secret-token'\n"
    )

    File.write!(
      Path.join(bin_dir, "symphony"),
      "#!/usr/bin/env bash\nprintf '%s\\n' \"$GITHUB_TOKEN\" \"$*\" > \"$LAUNCHER_TEST_OUTPUT\"\n"
    )

    File.chmod!(Path.join(bin_dir, "gh"), 0o755)
    File.chmod!(Path.join(bin_dir, "symphony"), 0o755)

    on_exit(fn -> File.rm_rf(temp_root) end)

    launcher = Path.expand("../../scripts/run-github", __DIR__)

    {stdout, status} =
      System.cmd(launcher, ["/tmp/WORKFLOW.md", "--port", "4000"],
        env: [
          {"PATH", bin_dir <> ":" <> System.get_env("PATH")},
          {"SYMPHONY_EXECUTABLE", Path.join(bin_dir, "symphony")},
          {"LAUNCHER_TEST_OUTPUT", output_path}
        ],
        stderr_to_stdout: true
      )

    assert status == 0
    refute stdout =~ "test-secret-token"

    assert File.read!(output_path) ==
             "test-secret-token\n--i-understand-that-this-will-be-running-without-the-usual-guardrails /tmp/WORKFLOW.md --port 4000\n"
  end

  test "launcher loads an App profile without consulting gh or printing credentials" do
    temp_root =
      Path.join(System.tmp_dir!(), "symphony-github-app-launcher-#{System.unique_integer([:positive])}")

    bin_dir = Path.join(temp_root, "bin")
    output_path = Path.join(temp_root, "output")
    File.mkdir_p!(bin_dir)

    File.write!(
      Path.join(bin_dir, "gh"),
      "#!/usr/bin/env bash\nprintf '%s' 'gh must not be called' >&2\nexit 77\n"
    )

    File.write!(
      Path.join(bin_dir, "symphony"),
      """
      #!/usr/bin/env bash
      if [[ "$1" == "github-app" && "$2" == "env" ]]; then
        printf '%s\n' 'GITHUB_APP_ID=123' 'GITHUB_APP_INSTALLATION_ID=456' 'GITHUB_APP_PRIVATE_KEY_PATH=/secure/private-key.pem'
        exit 0
      fi
      printf '%s\n%s\n%s\n%s\n' "$GITHUB_APP_ID" "$GITHUB_APP_INSTALLATION_ID" "$GITHUB_APP_PRIVATE_KEY_PATH" "$*" > "$LAUNCHER_TEST_OUTPUT"
      """
    )

    File.chmod!(Path.join(bin_dir, "gh"), 0o755)
    File.chmod!(Path.join(bin_dir, "symphony"), 0o755)
    on_exit(fn -> File.rm_rf(temp_root) end)

    launcher = Path.expand("../../scripts/run-github", __DIR__)

    {stdout, status} =
      System.cmd(
        launcher,
        ["--app-profile", "default", "/tmp/WORKFLOW.md", "--port", "4000"],
        env: [
          {"PATH", bin_dir <> ":" <> System.get_env("PATH")},
          {"SYMPHONY_EXECUTABLE", Path.join(bin_dir, "symphony")},
          {"LAUNCHER_TEST_OUTPUT", output_path}
        ],
        stderr_to_stdout: true
      )

    assert status == 0
    refute stdout =~ "123"
    refute stdout =~ "private-key"

    assert File.read!(output_path) ==
             "123\n456\n/secure/private-key.pem\n--i-understand-that-this-will-be-running-without-the-usual-guardrails /tmp/WORKFLOW.md --port 4000\n"
  end
end
