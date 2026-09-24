defmodule SymphonyElixir.GitHub.AgentTool do
  @moduledoc """
  Provider-native GitHub REST tool exposed to Codex app-server turns.
  """

  alias SymphonyElixir.GitHub.{Client, WorkflowControl}
  alias SymphonyElixir.Tracker.Issue

  @github_api_tool "github_api"
  @workflow_checkpoint_tool "github_workflow_checkpoint"
  @allowed_methods ["GET", "POST", "PATCH", "PUT", "DELETE"]
  @github_api_description """
  Execute a GitHub REST API request using Symphony's configured auth.
  """
  @github_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "enum" => @allowed_methods,
        "description" => "GitHub REST method."
      },
      "path" => %{
        "type" => "string",
        "description" => "GitHub REST path such as /repos/owner/repo/issues/1/comments."
      },
      "params" => %{
        "type" => ["object", "null"],
        "description" => "Optional query parameters.",
        "additionalProperties" => true
      },
      "body" => %{
        "description" => "Optional JSON request body."
      }
    }
  }
  @workflow_checkpoint_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["state", "phase", "summary"],
    "properties" => %{
      "state" => %{
        "type" => "string",
        "enum" => ["awaiting_input", "awaiting_approval", "awaiting_review", "blocked"]
      },
      "phase" => %{"type" => "string"},
      "summary" => %{"type" => "string"},
      "prompt" => %{"type" => ["string", "null"]},
      "gate" => %{"type" => ["string", "null"], "enum" => ["spec", "plan", "implementation", nil]},
      "branch" => %{"type" => ["string", "null"]},
      "head_sha" => %{"type" => ["string", "null"]},
      "pr_number" => %{"type" => ["integer", "null"]}
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts) do
    case tool do
      @github_api_tool -> execute_github_api(arguments, opts)
      @workflow_checkpoint_tool -> execute_workflow_checkpoint(arguments, opts)
      other -> unsupported_tool_response(other)
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @github_api_tool,
        "description" => @github_api_description,
        "inputSchema" => @github_api_input_schema
      },
      %{
        "name" => @workflow_checkpoint_tool,
        "description" => "Post a durable Symphony workflow checkpoint to the current GitHub issue using host authentication.",
        "inputSchema" => @workflow_checkpoint_schema
      }
    ]
  end

  defp execute_workflow_checkpoint(arguments, opts) do
    tracker_settings = Keyword.get(opts, :tracker_settings, %{})
    provider = Map.get(tracker_settings, :provider, %{})
    github_client = Keyword.get(opts, :github_client, &Client.request/5)
    client_opts = Keyword.take(opts, [:tracker_settings])

    with true <- WorkflowControl.enabled?(provider) or {:error, :github_workflow_control_disabled},
         {:ok, issue_number, repo} <- checkpoint_issue_context(Keyword.get(opts, :issue)),
         {:ok, checkpoint} <- normalize_checkpoint(arguments),
         :ok <- verify_checkpoint_head(checkpoint, repo, github_client, client_opts),
         {:ok, checkpoint} <- add_review_cursor(checkpoint, repo, github_client, client_opts),
         body <- WorkflowControl.render_comment(checkpoint),
         {:ok, %{status: status, body: response_body}} <-
           github_client.(
             "POST",
             "/repos/#{encoded_repo(repo)}/issues/#{issue_number}/comments",
             %{},
             %{"body" => body},
             client_opts
           ),
         true <- status in 200..299 do
      rest_response(status, response_body)
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
      _ -> failure_response(tool_error_payload(:github_unknown_payload))
    end
  end

  defp checkpoint_issue_context(%Issue{native_ref: %{"number" => number, "repo" => repo}})
       when is_integer(number) and number > 0 and is_binary(repo) do
    {:ok, number, repo}
  end

  defp checkpoint_issue_context(_issue), do: {:error, :missing_github_issue_context}

  defp normalize_checkpoint(arguments) when is_map(arguments) do
    checkpoint = Map.take(arguments, ~w(state phase summary prompt gate branch head_sha pr_number))

    with :ok <- WorkflowControl.valid_checkpoint(checkpoint),
         :ok <- validate_approval_ref(checkpoint) do
      {:ok, checkpoint}
    end
  end

  defp normalize_checkpoint(_arguments), do: {:error, :invalid_workflow_checkpoint}

  defp validate_approval_ref(%{"state" => "awaiting_approval"} = checkpoint) do
    if present?(checkpoint["branch"]) and valid_sha?(checkpoint["head_sha"]) do
      :ok
    else
      {:error, :invalid_workflow_approval_ref}
    end
  end

  defp validate_approval_ref(_checkpoint), do: :ok

  defp verify_checkpoint_head(%{"state" => "awaiting_approval"} = checkpoint, repo, client, opts) do
    sha = checkpoint["head_sha"]
    branch = checkpoint["branch"]

    with {:ok, %{status: commit_status, body: %{"sha" => ^sha}}} <-
           client.("GET", "/repos/#{encoded_repo(repo)}/commits/#{sha}", %{}, nil, opts),
         true <- commit_status in 200..299 or {:error, :workflow_commit_not_found},
         {:ok, %{status: branch_status, body: %{"commit" => %{"sha" => branch_sha}}}} <-
           client.(
             "GET",
             "/repos/#{encoded_repo(repo)}/branches/#{encode_segment(branch)}",
             %{},
             nil,
             opts
           ),
         true <- branch_status in 200..299 or {:error, :workflow_branch_not_found},
         true <- branch_sha == sha or {:error, {:workflow_head_mismatch, branch_sha, sha}} do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, :workflow_commit_not_found}
    end
  end

  defp verify_checkpoint_head(_checkpoint, _repo, _client, _opts), do: :ok

  defp add_review_cursor(%{"state" => "awaiting_review", "pr_number" => pr_number} = checkpoint, repo, client, opts) do
    paths = [
      {"pr_comment_id", "/repos/#{encoded_repo(repo)}/issues/#{pr_number}/comments"},
      {"review_comment_id", "/repos/#{encoded_repo(repo)}/pulls/#{pr_number}/comments"},
      {"review_id", "/repos/#{encoded_repo(repo)}/pulls/#{pr_number}/reviews"}
    ]

    Enum.reduce_while(paths, {:ok, %{}}, fn {key, path}, {:ok, cursor} ->
      case fetch_event_ids(path, client, opts) do
        {:ok, ids} -> {:cont, {:ok, Map.put(cursor, key, Enum.max(ids, fn -> 0 end))}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, cursor} -> {:ok, Map.put(checkpoint, "cursor", cursor)}
      error -> error
    end
  end

  defp add_review_cursor(checkpoint, _repo, _client, _opts), do: {:ok, checkpoint}

  defp fetch_event_ids(path, client, opts, page \\ 1, acc \\ []) do
    with {:ok, %{status: status, body: events}} <-
           client.("GET", path, %{"per_page" => 100, "page" => page}, nil, opts),
         true <- status in 200..299,
         true <- is_list(events) do
      ids =
        Enum.flat_map(events, fn
          %{"id" => id} when is_integer(id) -> [id]
          _ -> []
        end)

      updated_acc = ids ++ acc

      if length(events) < 100,
        do: {:ok, updated_acc},
        else: fetch_event_ids(path, client, opts, page + 1, updated_acc)
    else
      _ -> {:error, :github_review_cursor_failed}
    end
  end

  defp execute_github_api(arguments, opts) do
    github_client = Keyword.get(opts, :github_client, &Client.request/5)
    client_opts = Keyword.take(opts, [:tracker_settings])

    with {:ok, method, path, params, body} <- normalize_arguments(arguments),
         {:ok, %{status: status, body: response_body}} <-
           github_client.(method, path, params, body, client_opts),
         true <- is_integer(status) do
      rest_response(status, response_body)
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
      _ -> failure_response(tool_error_payload(:github_unknown_payload))
    end
  end

  defp normalize_arguments(arguments) when is_map(arguments) do
    with {:ok, method} <- normalize_method(Map.get(arguments, "method")),
         {:ok, path} <- normalize_path(Map.get(arguments, "path")),
         {:ok, params} <- normalize_params(Map.get(arguments, "params")) do
      {:ok, method, path, params, Map.get(arguments, "body")}
    end
  end

  defp normalize_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_method(method) when is_binary(method) do
    normalized = method |> String.trim() |> String.upcase()
    if normalized in @allowed_methods, do: {:ok, normalized}, else: {:error, :invalid_method}
  end

  defp normalize_method(_method), do: {:error, :invalid_method}

  defp normalize_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    if String.starts_with?(trimmed, "/") and not String.contains?(trimmed, ["://", "\n", "\r", <<0>>]) do
      {:ok, trimmed}
    else
      {:error, :invalid_path}
    end
  end

  defp normalize_path(_path), do: {:error, :invalid_path}

  defp normalize_params(nil), do: {:ok, %{}}
  defp normalize_params(params) when is_map(params), do: {:ok, params}
  defp normalize_params(_params), do: {:error, :invalid_params}

  defp rest_response(status, body) do
    dynamic_tool_response(status in 200..299, encode_payload(%{"status" => status, "body" => body}))
  end

  defp failure_response(payload), do: dynamic_tool_response(false, encode_payload(payload))

  defp dynamic_tool_response(success, output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp encode_payload(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, output} -> output
      {:error, _reason} -> inspect(payload)
    end
  end

  defp unsupported_tool_response(tool) do
    failure_response(%{
      "error" => %{
        "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
        "supportedTools" => supported_tool_names()
      }
    })
  end

  defp tool_error_payload(:invalid_arguments) do
    %{"error" => %{"message" => "`github_api` expects an object with `method` and `path`."}}
  end

  defp tool_error_payload(:invalid_method) do
    %{"error" => %{"message" => "`github_api.method` must be GET, POST, PATCH, PUT, or DELETE."}}
  end

  defp tool_error_payload(:invalid_path) do
    %{"error" => %{"message" => "`github_api.path` must be a relative GitHub REST path."}}
  end

  defp tool_error_payload(:invalid_params) do
    %{"error" => %{"message" => "`github_api.params` must be a JSON object when provided."}}
  end

  defp tool_error_payload(:missing_github_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing GitHub auth. Set `tracker.provider.token` in `WORKFLOW.md` or export `GITHUB_TOKEN`."
      }
    }
  end

  defp tool_error_payload(reason)
       when reason in [
              :github_workflow_control_disabled,
              :missing_github_issue_context,
              :invalid_workflow_checkpoint,
              :invalid_workflow_state,
              :invalid_workflow_phase,
              :invalid_workflow_summary,
              :missing_workflow_prompt,
              :invalid_workflow_gate,
              :invalid_workflow_pr_number,
              :invalid_workflow_approval_ref,
              :workflow_commit_not_found,
              :workflow_branch_not_found,
              :github_review_cursor_failed
            ] do
    %{
      "error" => %{
        "message" => "GitHub workflow checkpoint failed validation.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:github_api_request, reason}) do
    %{
      "error" => %{
        "message" => "GitHub API request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{"error" => %{"message" => "GitHub API tool execution failed.", "reason" => inspect(reason)}}
  end

  defp supported_tool_names, do: Enum.map(tool_specs(), & &1["name"])

  defp encoded_repo(repo) do
    repo
    |> String.split("/", parts: 2)
    |> Enum.map_join("/", &encode_segment/1)
  end

  defp encode_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp valid_sha?(value), do: is_binary(value) and String.match?(value, ~r/^[0-9a-f]{40}$/i)
end
