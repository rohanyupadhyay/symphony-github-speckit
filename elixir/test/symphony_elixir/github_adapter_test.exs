defmodule SymphonyElixir.GitHub.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Adapter, as: GitHubAdapter
  alias SymphonyElixir.GitHub.AgentTool, as: GitHubAgentTool
  alias SymphonyElixir.GitHub.Client, as: GitHubClient
  alias SymphonyElixir.GitHub.WorkflowControl
  alias SymphonyElixir.Tracker.Issue

  defmodule FakeGitHubClient do
    def fetch_issues_by_states(states) do
      send(self(), {:github_states_called, states})
      {:ok, states}
    end

    def fetch_issues_by_ids(ids) do
      send(self(), {:github_ids_called, ids})
      {:ok, ids}
    end
  end

  setup do
    github_client_module = Application.get_env(:symphony_elixir, :github_client_module)

    on_exit(fn ->
      if is_nil(github_client_module) do
        Application.delete_env(:symphony_elixir, :github_client_module)
      else
        Application.put_env(:symphony_elixir, :github_client_module, github_client_module)
      end
    end)

    :ok
  end

  test "adapter validates GitHub config, delegates reads, and advertises github_api" do
    settings = tracker_settings()

    assert :ok = GitHubAdapter.validate_config(settings)

    assert {:error, :missing_github_active_states} =
             GitHubAdapter.validate_config(%{settings | active_states: nil})

    assert {:error, :missing_github_terminal_states} =
             GitHubAdapter.validate_config(%{settings | terminal_states: nil})

    assert :ok = GitHubAdapter.validate_config(%{settings | active_states: [], terminal_states: []})

    assert {:error, :invalid_github_states} =
             GitHubAdapter.validate_config(%{settings | active_states: ["Todo"]})

    assert {:error, :invalid_github_states} =
             GitHubAdapter.validate_config(%{settings | active_states: [42]})

    assert {:error, :invalid_github_states} =
             GitHubAdapter.validate_config(%{settings | active_states: ["closed"]})

    assert {:error, :invalid_github_states} =
             GitHubAdapter.validate_config(%{settings | terminal_states: ["open"]})

    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)

    assert {:ok, ["open"]} = GitHubAdapter.fetch_issues_by_states(["open"])
    assert_receive {:github_states_called, ["open"]}

    assert {:ok, ["42"]} = GitHubAdapter.fetch_issues_by_ids(["42"])
    assert_receive {:github_ids_called, ["42"]}

    assert Enum.map(GitHubAdapter.agent_tool_specs(), & &1["name"]) == [
             "github_api",
             "github_workflow_checkpoint",
             "github_git_push"
           ]

    assert GitHubAdapter.execute_agent_tool(
             "github_api",
             %{"method" => "GET", "path" => "/user"},
             github_client: fn _method, _path, _params, _body, _opts ->
               {:ok, %{status: 200, body: %{"login" => "octocat"}}}
             end
           )["success"]
  end

  test "github_git_push returns only validated branch metadata" do
    head_sha = String.duplicate("a", 40)

    response =
      GitHubAgentTool.execute(
        "github_git_push",
        %{"branch" => "symphony/gh-42-auth", "head_sha" => head_sha},
        git_push: fn arguments, opts ->
          assert arguments == %{"branch" => "symphony/gh-42-auth", "head_sha" => head_sha}
          assert opts[:workspace] == "/tmp/GH-42"
          {:ok, %{branch: arguments["branch"], head_sha: arguments["head_sha"]}}
        end,
        workspace: "/tmp/GH-42"
      )

    assert response["success"]

    assert Jason.decode!(response["output"]) == %{
             "branch" => "symphony/gh-42-auth",
             "head_sha" => head_sha
           }

    failed =
      GitHubAgentTool.execute(
        "github_git_push",
        %{},
        git_push: fn _arguments, _opts -> {:error, :invalid_github_push_arguments} end
      )

    refute failed["success"]
    refute failed["output"] =~ "short-lived-secret"

    malformed =
      GitHubAgentTool.execute(
        "github_git_push",
        %{},
        git_push: fn _arguments, _opts -> :unexpected end
      )

    refute malformed["success"]
    assert Jason.decode!(malformed["output"])["error"]["reason"] =~ "github_push_failed"
  end

  test "client validates repository settings and declares token environments" do
    assert :ok = GitHubClient.validate_settings(tracker_settings())

    assert {:error, :missing_github_repo} =
             GitHubClient.validate_settings(tracker_settings(%{"repo" => 123}))

    assert {:error, :invalid_github_repo} =
             GitHubClient.validate_settings(tracker_settings(%{"repo" => "not-a-repo"}))

    assert {:error, :missing_github_token} =
             GitHubClient.validate_settings(tracker_settings(%{"token" => 123}))

    assert {:error, :invalid_github_api_url} =
             GitHubClient.validate_settings(tracker_settings(%{"api_url" => "not a url"}))

    assert {:error, :invalid_github_api_url} =
             GitHubClient.validate_settings(tracker_settings(%{"api_url" => "http://api.github.com"}))

    assert GitHubClient.secret_environment_names(tracker_settings(%{"token" => "$SYMPHONY_GITHUB_TOKEN"})) == [
             "GITHUB_TOKEN",
             "GH_TOKEN",
             "GITHUB_ENTERPRISE_TOKEN",
             "GH_ENTERPRISE_TOKEN",
             "SYMPHONY_GITHUB_TOKEN"
           ]
  end

  test "client normalizes GitHub issues without dropping provider details" do
    issue = GitHubClient.normalize_issue_for_test(raw_issue(42), "octo/repo")

    assert issue.id == "42"
    assert issue.identifier == "GH-42"

    assert issue.native_ref == %{
             "id" => 1_042,
             "node_id" => "I_42",
             "number" => 42,
             "repo" => "octo/repo"
           }

    assert issue.title == "Issue 42"
    assert issue.description == "Body 42"
    assert issue.state == "open"
    assert issue.url == "https://github.test/octo/repo/issues/42"
    assert issue.assignee_id == "octocat"
    assert issue.labels == ["bug", "platform"]
    assert issue.blocked_by == []
    assert issue.dispatchable
    assert %DateTime{} = issue.created_at
    assert %DateTime{} = issue.updated_at

    refute GitHubClient.normalize_issue_for_test(
             Map.put(raw_issue(43), "pull_request", %{"url" => "https://api.github.test/pulls/43"}),
             "octo/repo"
           ).dispatchable

    assert GitHubClient.normalize_issue_for_test(
             Map.put(raw_issue(44), "title", " "),
             "octo/repo"
           ) == nil
  end

  test "client pages state reads, filters requested states, and drops malformed records" do
    first_page =
      Enum.map(1..97, &raw_issue/1) ++
        [
          Map.put(raw_issue(98), "pull_request", %{"url" => "https://api.github.test/pulls/98"}),
          Map.put(raw_issue(99), "state", "closed"),
          Map.put(raw_issue(100), "title", "")
        ]

    request_fun = fn "GET", "/repos/octo/repo/issues", params, nil, settings ->
      send(self(), {:github_page, params, settings})

      body =
        case params["page"] do
          1 -> first_page
          2 -> [raw_issue(101)]
        end

      {:ok, %{status: 200, body: body}}
    end

    log =
      capture_log(fn ->
        assert {:ok, issues} =
                 GitHubClient.fetch_issues_by_states_for_test(
                   [" OPEN "],
                   tracker_settings(),
                   request_fun
                 )

        assert length(issues) == 99
        assert hd(issues).id == "1"
        assert List.last(issues).id == "101"
        refute Enum.any?(issues, &(&1.id == "99"))
        assert Enum.find(issues, &(&1.id == "98")).dispatchable == false
      end)

    assert log =~ "Dropping malformed GitHub issue records count=1"

    assert_receive {:github_page,
                    %{
                      "state" => "open",
                      "per_page" => 100,
                      "page" => 1,
                      "sort" => "created",
                      "direction" => "asc"
                    }, %{repo: "octo/repo"}}

    assert_receive {:github_page, %{"page" => 2}, %{repo: "octo/repo"}}

    assert {:ok, []} =
             GitHubClient.fetch_issues_by_states_for_test(
               ["In Progress"],
               tracker_settings(),
               fn _method, _path, _params, _body, _settings ->
                 flunk("unsupported GitHub states should not make an HTTP request")
               end
             )
  end

  test "client refreshes numeric IDs in order, omits 404s, and rejects malformed refreshes" do
    request_fun = fn "GET", path, %{}, nil, _settings ->
      send(self(), {:github_id_path, path})

      case path do
        "/repos/octo/repo/issues/2" -> {:ok, %{status: 200, body: raw_issue(2)}}
        "/repos/octo/repo/issues/1" -> {:ok, %{status: 200, body: raw_issue(1)}}
        "/repos/octo/repo/issues/404" -> {:ok, %{status: 404, body: %{"message" => "Not Found"}}}
      end
    end

    assert {:ok, issues} =
             GitHubClient.fetch_issues_by_ids_for_test(
               ["2", "1", "404", "2"],
               tracker_settings(),
               request_fun
             )

    assert Enum.map(issues, & &1.id) == ["2", "1"]
    assert_receive {:github_id_path, "/repos/octo/repo/issues/2"}
    assert_receive {:github_id_path, "/repos/octo/repo/issues/1"}
    assert_receive {:github_id_path, "/repos/octo/repo/issues/404"}
    refute_receive {:github_id_path, "/repos/octo/repo/issues/2"}

    assert {:error, :invalid_github_issue_id} =
             GitHubClient.fetch_issues_by_ids_for_test(
               ["not-a-number"],
               tracker_settings(),
               request_fun
             )

    assert {:error, :github_unknown_payload} =
             GitHubClient.fetch_issues_by_ids_for_test(
               ["3"],
               tracker_settings(),
               fn _method, _path, _params, _body, _settings ->
                 {:ok, %{status: 200, body: Map.put(raw_issue(3), "title", "")}}
               end
             )
  end

  test "github_api preserves REST status and body while rejecting unsafe arguments" do
    test_pid = self()
    tracker_settings = tracker_settings()

    response =
      GitHubAgentTool.execute(
        "github_api",
        %{
          "method" => "post",
          "path" => " /repos/octo/repo/issues/42/comments ",
          "params" => %{"per_page" => 10},
          "body" => %{"body" => "hello"}
        },
        tracker_settings: tracker_settings,
        github_client: fn method, path, params, body, opts ->
          send(test_pid, {:github_tool_called, method, path, params, body, opts})
          {:ok, %{status: 201, body: %{"id" => 9}}}
        end
      )

    assert_received {:github_tool_called, "POST", "/repos/octo/repo/issues/42/comments", %{"per_page" => 10}, %{"body" => "hello"}, [tracker_settings: ^tracker_settings]}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"status" => 201, "body" => %{"id" => 9}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]

    failure =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "GET", "path" => "/repos/octo/repo/issues/404"},
        github_client: fn _method, _path, _params, _body, _opts ->
          {:ok, %{status: 404, body: %{"message" => "Not Found"}}}
        end
      )

    assert failure["success"] == false

    assert Jason.decode!(failure["output"]) == %{
             "status" => 404,
             "body" => %{"message" => "Not Found"}
           }

    Enum.each(
      [
        %{"method" => "GET", "path" => "https://api.github.com/user"},
        %{"method" => "GET", "path" => "/user", "params" => false},
        %{"path" => "/user"}
      ],
      fn arguments ->
        invalid =
          GitHubAgentTool.execute(
            "github_api",
            arguments,
            github_client: fn _method, _path, _params, _body, _opts ->
              flunk("invalid github_api arguments should not call the client")
            end
          )

        assert invalid["success"] == false
      end
    )
  end

  test "github_api reports unsupported tools, malformed calls, and client failures" do
    unsupported = GitHubAgentTool.execute("not_github_api", %{}, [])
    assert unsupported["success"] == false

    assert Jason.decode!(unsupported["output"])["error"]["supportedTools"] == [
             "github_api",
             "github_workflow_checkpoint",
             "github_git_push"
           ]

    Enum.each(
      [
        "not-an-object",
        %{"method" => "GET", "path" => 123}
      ],
      fn arguments ->
        invalid =
          GitHubAgentTool.execute(
            "github_api",
            arguments,
            github_client: fn _method, _path, _params, _body, _opts ->
              flunk("malformed github_api arguments should not call the client")
            end
          )

        assert invalid["success"] == false
      end
    )

    malformed_response =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "GET", "path" => "/user"},
        github_client: fn _method, _path, _params, _body, _opts ->
          {:ok, %{status: "not-an-integer", body: %{}}}
        end
      )

    assert malformed_response["success"] == false

    Enum.each(
      [
        :missing_github_token,
        {:github_api_request, :timeout},
        :unexpected_failure
      ],
      fn reason ->
        failure =
          GitHubAgentTool.execute(
            "github_api",
            %{"method" => "GET", "path" => "/user"},
            github_client: fn _method, _path, _params, _body, _opts ->
              {:error, reason}
            end
          )

        assert failure["success"] == false
        assert %{"error" => %{"message" => message}} = Jason.decode!(failure["output"])
        assert is_binary(message)
      end
    )

    non_json_body =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "GET", "path" => "/user"},
        github_client: fn _method, _path, _params, _body, _opts ->
          {:ok, %{status: 200, body: self()}}
        end
      )

    assert non_json_body["success"]
    assert non_json_body["output"] =~ "#PID"
  end

  test "tracker binds GitHub tools and token env names from provider config" do
    token_env = "SYMPHONY_GITHUB_TOKEN_#{System.unique_integer([:positive])}"
    previous_token = System.get_env(token_env)
    System.put_env(token_env, "test-token")

    on_exit(fn -> restore_env(token_env, previous_token) end)

    write_github_workflow!(Workflow.workflow_file_path(), "$#{token_env}")

    binding = Tracker.bind_agent_tools()

    assert binding.adapter == GitHubAdapter

    assert binding.secret_environment_names == [
             "GITHUB_TOKEN",
             "GH_TOKEN",
             "GITHUB_ENTERPRISE_TOKEN",
             "GH_ENTERPRISE_TOKEN",
             token_env
           ]

    assert Enum.map(binding.tool_specs, & &1["name"]) == [
             "github_api",
             "github_workflow_checkpoint",
             "github_git_push"
           ]

    assert :ok = Config.validate!()
    issue = %Issue{id: "42", identifier: "GH-42", title: "Test", state: "open"}
    assert :ok = GitHubAdapter.prepare_workspace("/tmp/not-used", issue, "worker.example")
    assert :ok = SymphonyElixir.Tracker.prepare_workspace("/tmp/not-used", issue, nil)
  end

  test "workflow control enriches a labeled issue and reconstructs an authorized answer" do
    marker =
      WorkflowControl.render_comment(%{
        "state" => "awaiting_input",
        "phase" => "clarify",
        "summary" => "A decision is needed.",
        "prompt" => "Which retention period?"
      })

    requests = fn "GET", "/repos/octo/repo/issues/42/comments", params, nil, _settings ->
      page = params["page"]

      body =
        case page do
          1 -> [raw_comment(10, "OWNER", marker)]
          _ -> []
        end

      {:ok, %{status: 200, body: body}}
    end

    issue = GitHubClient.normalize_issue_for_test(raw_issue(42), "octo/repo")

    assert {:ok, waiting} =
             GitHubClient.enrich_issue_for_test(issue, workflow_tracker_settings(), requests)

    refute waiting.dispatchable
    assert waiting.native_ref["workflow_control"]["state"] == "awaiting_input"
    assert waiting.native_ref["workflow_control"]["trigger"] == nil

    answered_requests = fn "GET", "/repos/octo/repo/issues/42/comments", params, nil, _settings ->
      body =
        case params["page"] do
          1 -> [raw_comment(10, "OWNER", marker), raw_comment(11, "COLLABORATOR", "Use 30 days.")]
          _ -> []
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, answered} =
             GitHubClient.enrich_issue_for_test(issue, workflow_tracker_settings(), answered_requests)

    assert answered.dispatchable
    assert answered.native_ref["workflow_control"]["trigger"]["kind"] == "answer"
    assert answered.native_ref["workflow_control"]["trigger"]["body"] == "Use 30 days."
  end

  test "workflow control polls pull request surfaces only while awaiting review" do
    marker =
      WorkflowControl.render_comment(%{
        "state" => "awaiting_review",
        "phase" => "review",
        "summary" => "PR #7 is ready.",
        "pr_number" => 7,
        "cursor" => %{"review_id" => 100, "pr_comment_id" => 200, "review_comment_id" => 300}
      })

    request_fun = fn "GET", path, params, nil, _settings ->
      send(self(), {:workflow_request, path, params})

      body =
        case path do
          "/repos/octo/repo/issues/42/comments" -> [raw_comment(10, "OWNER", marker)]
          "/repos/octo/repo/pulls/7" -> %{"number" => 7, "state" => "open", "merged" => false}
          "/repos/octo/repo/issues/7/comments" -> []
          "/repos/octo/repo/pulls/7/comments" -> []
          "/repos/octo/repo/pulls/7/reviews" -> [raw_review(101, "reviewer", "MEMBER", "CHANGES_REQUESTED")]
        end

      {:ok, %{status: 200, body: body}}
    end

    issue = GitHubClient.normalize_issue_for_test(raw_issue(42), "octo/repo")

    assert {:ok, enriched} =
             GitHubClient.enrich_issue_for_test(issue, workflow_tracker_settings(), request_fun)

    assert enriched.dispatchable

    assert enriched.native_ref["workflow_control"]["trigger"] == %{
             "kind" => "review",
             "id" => 101,
             "body" => "Review 101",
             "author" => "reviewer",
             "state" => "changes_requested"
           }

    assert_receive {:workflow_request, "/repos/octo/repo/pulls/7", %{}}
    assert_receive {:workflow_request, "/repos/octo/repo/issues/7/comments", %{"page" => 1}}
    assert_receive {:workflow_request, "/repos/octo/repo/pulls/7/comments", %{"page" => 1}}
    assert_receive {:workflow_request, "/repos/octo/repo/pulls/7/reviews", %{"page" => 1}}
  end

  test "github_workflow_checkpoint validates a pushed approval SHA and posts to the current issue" do
    settings = workflow_tracker_settings()

    response =
      GitHubAgentTool.execute(
        "github_workflow_checkpoint",
        %{
          "state" => "awaiting_approval",
          "phase" => "specify",
          "summary" => "Specification ready.",
          "gate" => "spec",
          "branch" => "symphony/gh-42-auth",
          "head_sha" => String.duplicate("a", 40)
        },
        issue: %Issue{id: "42", native_ref: %{"number" => 42, "repo" => "octo/repo"}},
        tracker_settings: settings,
        github_client: fn method, path, params, body, _opts ->
          send(self(), {:checkpoint_request, method, path, params, body})

          response_body =
            case path do
              "/repos/octo/repo/commits/" <> _sha ->
                %{"sha" => String.duplicate("a", 40)}

              "/repos/octo/repo/branches/symphony%2Fgh-42-auth" ->
                %{"commit" => %{"sha" => String.duplicate("a", 40)}}

              "/repos/octo/repo/issues/42/comments" ->
                %{"id" => 99, "html_url" => "https://github.test/comment/99"}
            end

          {:ok, %{status: if(method == "POST", do: 201, else: 200), body: response_body}}
        end
      )

    assert response["success"]

    assert_receive {:checkpoint_request, "GET", "/repos/octo/repo/commits/" <> _, %{}, nil}

    assert_receive {:checkpoint_request, "GET", "/repos/octo/repo/branches/symphony%2Fgh-42-auth", %{}, nil}

    assert_receive {:checkpoint_request, "POST", "/repos/octo/repo/issues/42/comments", %{}, %{"body" => body}}
    assert {:ok, %{"gate" => "spec"}} = WorkflowControl.decode_checkpoint(body)
  end

  test "github_workflow_checkpoint rejects disabled control invalid context and stale branch heads" do
    issue = %Issue{id: "42", native_ref: %{"number" => 42, "repo" => "octo/repo"}}
    args = %{"state" => "blocked", "phase" => "push", "summary" => "Cannot push."}

    refute GitHubAgentTool.execute(
             "github_workflow_checkpoint",
             args,
             issue: issue,
             tracker_settings: tracker_settings(),
             github_client: fn _, _, _, _, _ -> flunk("disabled control must not call GitHub") end
           )["success"]

    stale =
      GitHubAgentTool.execute(
        "github_workflow_checkpoint",
        %{
          "state" => "awaiting_approval",
          "phase" => "plan",
          "summary" => "Plan ready.",
          "gate" => "plan",
          "branch" => "topic",
          "head_sha" => String.duplicate("a", 40)
        },
        issue: issue,
        tracker_settings: workflow_tracker_settings(),
        github_client: fn _method, path, _params, _body, _opts ->
          body =
            if String.contains?(path, "/branches/"),
              do: %{"commit" => %{"sha" => String.duplicate("b", 40)}},
              else: %{"sha" => String.duplicate("a", 40)}

          {:ok, %{status: 200, body: body}}
        end
      )

    refute stale["success"]
    assert Jason.decode!(stale["output"])["error"]["reason"] =~ "workflow_head_mismatch"
  end

  test "github_workflow_checkpoint records current pull request event cursors" do
    response =
      GitHubAgentTool.execute(
        "github_workflow_checkpoint",
        %{
          "state" => "awaiting_review",
          "phase" => "review",
          "summary" => "PR #7 is ready for review.",
          "pr_number" => 7
        },
        issue: %Issue{id: "42", native_ref: %{"number" => 42, "repo" => "octo/repo"}},
        tracker_settings: workflow_tracker_settings(),
        github_client: fn method, path, _params, body, _opts ->
          response_body =
            case path do
              "/repos/octo/repo/issues/7/comments" ->
                [%{"id" => 201}]

              "/repos/octo/repo/pulls/7/comments" ->
                [%{"id" => 301}]

              "/repos/octo/repo/pulls/7/reviews" ->
                [%{"id" => 101}]

              "/repos/octo/repo/issues/42/comments" ->
                send(self(), {:review_checkpoint_body, body["body"]})
                %{"id" => 400}
            end

          {:ok, %{status: if(method == "POST", do: 201, else: 200), body: response_body}}
        end
      )

    assert response["success"]
    assert_receive {:review_checkpoint_body, body}
    assert {:ok, checkpoint} = WorkflowControl.decode_checkpoint(body)

    assert checkpoint["cursor"] == %{
             "pr_comment_id" => 201,
             "review_comment_id" => 301,
             "review_id" => 101
           }
  end

  test "github_workflow_checkpoint rejects malformed inputs and failed API responses" do
    issue = %Issue{id: "42", native_ref: %{"number" => 42, "repo" => "octo/repo"}}
    settings = workflow_tracker_settings()

    for {arguments, opts} <- [
          {nil, [issue: issue, tracker_settings: settings]},
          {%{"state" => "blocked", "phase" => "x", "summary" => "x"}, [issue: %Issue{id: "42", native_ref: %{}}, tracker_settings: settings]},
          {%{
             "state" => "awaiting_approval",
             "phase" => "plan",
             "summary" => "Ready.",
             "gate" => "plan"
           }, [issue: issue, tracker_settings: settings]}
        ] do
      refute GitHubAgentTool.execute(
               "github_workflow_checkpoint",
               arguments,
               Keyword.put(opts, :github_client, fn _, _, _, _, _ ->
                 flunk("invalid input must not call GitHub")
               end)
             )["success"]
    end

    approval = %{
      "state" => "awaiting_approval",
      "phase" => "plan",
      "summary" => "Ready.",
      "gate" => "plan",
      "branch" => "topic",
      "head_sha" => String.duplicate("a", 40)
    }

    for response <- [
          {:ok, %{status: 404, body: %{}}},
          {:ok, %{status: 200, body: %{"sha" => String.duplicate("b", 40)}}},
          {:error, :network}
        ] do
      result =
        GitHubAgentTool.execute(
          "github_workflow_checkpoint",
          approval,
          issue: issue,
          tracker_settings: settings,
          github_client: fn _, _, _, _, _ -> response end
        )

      refute result["success"]
    end
  end

  test "github_workflow_checkpoint paginates cursor events and reports cursor failures" do
    issue = %Issue{id: "42", native_ref: %{"number" => 42, "repo" => "octo/repo"}}

    arguments = %{
      "state" => "awaiting_review",
      "phase" => "review",
      "summary" => "Review.",
      "pr_number" => 7
    }

    response =
      GitHubAgentTool.execute(
        "github_workflow_checkpoint",
        arguments,
        issue: issue,
        tracker_settings: workflow_tracker_settings(),
        github_client: fn method, path, params, _body, _opts ->
          body =
            cond do
              method == "POST" ->
                %{"id" => 500}

              path =~ "/issues/7/comments" and params["page"] == 1 ->
                [%{"id" => "bad"} | Enum.map(2..100, &%{"id" => &1})]

              true ->
                []
            end

          {:ok, %{status: if(method == "POST", do: 201, else: 200), body: body}}
        end
      )

    assert response["success"]

    failed =
      GitHubAgentTool.execute(
        "github_workflow_checkpoint",
        arguments,
        issue: issue,
        tracker_settings: workflow_tracker_settings(),
        github_client: fn _, _, _, _, _ -> {:ok, %{status: 500, body: %{}}} end
      )

    refute failed["success"]
    assert Jason.decode!(failed["output"])["error"]["reason"] =~ "github_review_cursor_failed"

    post_failed =
      GitHubAgentTool.execute(
        "github_workflow_checkpoint",
        %{"state" => "blocked", "phase" => "push", "summary" => "Blocked."},
        issue: issue,
        tracker_settings: workflow_tracker_settings(),
        github_client: fn _, _, _, _, _ -> {:ok, %{status: 500, body: %{}}} end
      )

    refute post_failed["success"]
  end

  defp tracker_settings(provider_overrides \\ %{}) do
    %{
      kind: "github",
      provider:
        Map.merge(
          %{
            "repo" => "octo/repo",
            "token" => "test-token"
          },
          provider_overrides
        ),
      active_states: ["open"],
      terminal_states: ["closed"]
    }
  end

  defp workflow_tracker_settings do
    tracker_settings(%{
      "workflow_control" => %{
        "enabled" => true,
        "authorized_associations" => ["OWNER", "MEMBER", "COLLABORATOR"]
      }
    })
  end

  defp raw_issue(number) do
    %{
      "number" => number,
      "id" => 1_000 + number,
      "node_id" => "I_#{number}",
      "title" => "Issue #{number}",
      "body" => "Body #{number}",
      "state" => "open",
      "html_url" => "https://github.test/octo/repo/issues/#{number}",
      "assignee" => %{"login" => "octocat"},
      "labels" => [%{"name" => " Bug "}, %{"name" => "bug"}, %{"name" => "Platform"}],
      "created_at" => "2026-01-01T00:00:00Z",
      "updated_at" => "2026-01-02T00:00:00Z"
    }
  end

  defp raw_comment(id, association, body) do
    %{
      "id" => id,
      "author_association" => association,
      "body" => body,
      "user" => %{"login" => "user-#{id}"},
      "created_at" => "2026-09-24T00:00:00Z"
    }
  end

  defp raw_review(id, login, association, state) do
    %{
      "id" => id,
      "state" => state,
      "author_association" => association,
      "user" => %{"login" => login},
      "body" => "Review #{id}",
      "submitted_at" => "2026-09-24T00:00:00Z"
    }
  end

  defp write_github_workflow!(path, token) do
    File.write!(
      path,
      """
      ---
      tracker:
        kind: github
        provider:
          repo: "octo/repo"
          token: #{Jason.encode!(token)}
        active_states: ["open"]
        terminal_states: ["closed"]
      ---

      You are working on {{ issue.identifier }}.
      """
    )

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      assert :ok = SymphonyElixir.WorkflowStore.force_reload()
    end
  end
end
