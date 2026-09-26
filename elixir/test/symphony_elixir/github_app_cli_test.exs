defmodule SymphonyElixir.GitHub.AppCLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.AppCLI

  test "setup opens registration and creates the selected private profile" do
    parent = self()
    answers = Agent.start_link(fn -> ["123\n", "456\n", "/tmp/downloaded.pem\n"] end) |> elem(1)

    deps = %{
      puts: fn message -> send(parent, {:puts, message}) end,
      gets: fn prompt ->
        send(parent, {:prompt, prompt})
        Agent.get_and_update(answers, fn [answer | rest] -> {answer, rest} end)
      end,
      open_url: fn url ->
        send(parent, {:opened, url})
        :ok
      end,
      create: fn repo, profile, app_id, installation_id, key_path ->
        send(parent, {:created, repo, profile, app_id, installation_id, key_path})
        {:ok, %{bot_login: "verity-symphony[bot]"}}
      end,
      load: fn _profile -> flunk("setup must not load an existing profile") end,
      verify: fn _profile, _repo -> flunk("create performs setup verification") end,
      environment: fn _profile -> flunk("setup must not export environment") end
    }

    assert :ok =
             AppCLI.run(
               ["setup", "octo/repo", "--profile", "default", "--name", "Rohan Symphony Plus"],
               deps
             )

    assert_received {:opened, url}
    assert url =~ "webhook_active=false"
    assert_received {:created, "octo/repo", "default", 123, 456, "/tmp/downloaded.pem"}
    assert_received {:puts, message}
    assert message =~ "private key"
  end

  test "verify and env use an existing profile without exposing key contents" do
    parent = self()
    profile = %{app_id: 123, installation_id: 456, private_key_path: "/secure/key.pem", bot_login: "app[bot]"}

    deps = %{
      puts: fn message -> send(parent, {:puts, message}) end,
      gets: fn _prompt -> flunk("non-interactive commands must not prompt") end,
      open_url: fn _url -> flunk("non-setup commands must not open a browser") end,
      create: fn _, _, _, _, _ -> flunk("non-setup commands must not create a profile") end,
      load: fn "default" -> {:ok, profile} end,
      verify: fn ^profile, "octo/repo" -> {:ok, %{login: "app[bot]"}} end,
      environment: fn "default" ->
        {:ok,
         [
           {"GITHUB_APP_ID", "123"},
           {"GITHUB_APP_INSTALLATION_ID", "456"},
           {"GITHUB_APP_PRIVATE_KEY_PATH", "/secure/key.pem"}
         ]}
      end
    }

    assert :ok = AppCLI.run(["verify", "octo/repo", "--profile", "default"], deps)
    assert_received {:puts, "Verified app[bot] for octo/repo."}

    assert :ok = AppCLI.run(["env", "--profile", "default"], deps)
    assert_received {:puts, "GITHUB_APP_ID=123"}
    assert_received {:puts, "GITHUB_APP_INSTALLATION_ID=456"}
    assert_received {:puts, "GITHUB_APP_PRIVATE_KEY_PATH=/secure/key.pem"}
  end

  test "rejects malformed commands and setup input" do
    deps = %{
      puts: fn _message -> :ok end,
      gets: fn _prompt -> "not-an-id\n" end,
      open_url: fn _url -> :ok end,
      create: fn _, _, _, _, _ -> flunk("invalid input must not create a profile") end,
      load: fn _ -> {:error, :not_found} end,
      verify: fn _, _ -> {:error, :not_found} end,
      environment: fn _ -> {:error, :not_found} end
    }

    assert {:error, message} = AppCLI.run(["unknown"], deps)
    assert message =~ "Usage: symphony github-app"

    assert {:error, :invalid_github_app_id} =
             AppCLI.run(["setup", "octo/repo", "--profile", "default"], deps)
  end
end
