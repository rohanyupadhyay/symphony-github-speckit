defmodule SymphonyElixir.GitHub.WorkflowControl do
  @moduledoc """
  Encodes durable GitHub workflow checkpoints and derives the next dispatch trigger.

  Checkpoints are readable issue comments with an opaque, versioned marker. The
  GitHub adapter can therefore reconstruct waiting state after a restart without
  a Symphony-owned database.
  """

  @marker_regex ~r/<!-- symphony-control:v1:([^\s]+) -->/
  @states ~w(awaiting_input awaiting_approval awaiting_review blocked)
  @gates ~w(spec plan implementation)
  @commands ~w(retry status cancel)
  @default_associations ~w(OWNER MEMBER COLLABORATOR)

  @type derived_state :: %{
          checkpoint: map() | nil,
          trigger: map() | nil,
          dispatchable: boolean()
        }

  @spec validate_settings(map()) :: :ok | {:error, atom()}
  def validate_settings(provider) when is_map(provider) do
    case Map.get(provider, "workflow_control") do
      nil ->
        :ok

      %{} = settings ->
        associations = Map.get(settings, "authorized_associations", @default_associations)

        cond do
          Map.get(settings, "enabled", false) not in [true, false] ->
            {:error, :invalid_github_workflow_control}

          not valid_associations?(associations) ->
            {:error, :invalid_github_workflow_associations}

          true ->
            :ok
        end

      _ ->
        {:error, :invalid_github_workflow_control}
    end
  end

  def validate_settings(_provider), do: {:error, :invalid_github_workflow_control}

  @spec enabled?(map()) :: boolean()
  def enabled?(provider) when is_map(provider) do
    get_in(provider, ["workflow_control", "enabled"]) == true
  end

  def enabled?(_provider), do: false

  @spec authorized_associations(map()) :: [String.t()]
  def authorized_associations(provider) when is_map(provider) do
    provider
    |> get_in(["workflow_control", "authorized_associations"])
    |> case do
      values when is_list(values) -> Enum.map(values, &normalize_association/1)
      _ -> @default_associations
    end
  end

  def authorized_associations(_provider), do: @default_associations

  @spec render_comment(map()) :: String.t()
  def render_comment(checkpoint) when is_map(checkpoint) do
    normalized = Map.put(checkpoint, "version", 1)
    marker = normalized |> Jason.encode!() |> Base.url_encode64(padding: false)

    [
      Map.get(normalized, "summary", "Symphony is waiting."),
      checkpoint_guidance(normalized),
      "<!-- symphony-control:v1:#{marker} -->"
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  @spec decode_checkpoint(String.t()) :: {:ok, map()} | :error
  def decode_checkpoint(body) when is_binary(body) do
    case Regex.scan(@marker_regex, body, capture: :all_but_first) |> List.last() do
      [encoded] -> decode_marker(encoded)
      _ -> :error
    end
  end

  def decode_checkpoint(_body), do: :error

  @spec valid_checkpoint(map()) :: :ok | {:error, atom()}
  def valid_checkpoint(checkpoint) when is_map(checkpoint) do
    state = checkpoint["state"]
    phase = checkpoint["phase"]
    summary = checkpoint["summary"]

    cond do
      state not in @states ->
        {:error, :invalid_workflow_state}

      not present?(phase) ->
        {:error, :invalid_workflow_phase}

      not present?(summary) ->
        {:error, :invalid_workflow_summary}

      state == "awaiting_input" and not present?(checkpoint["prompt"]) ->
        {:error, :missing_workflow_prompt}

      state == "awaiting_approval" and checkpoint["gate"] not in @gates ->
        {:error, :invalid_workflow_gate}

      state == "awaiting_review" and not positive_integer?(checkpoint["pr_number"]) ->
        {:error, :invalid_workflow_pr_number}

      true ->
        :ok
    end
  end

  def valid_checkpoint(_checkpoint), do: {:error, :invalid_workflow_checkpoint}

  @spec derive([map()], map(), [String.t()]) :: derived_state()
  def derive(comments, review_context, authorized_associations)
      when is_list(comments) and is_map(review_context) and is_list(authorized_associations) do
    authorized = authorized_associations |> Enum.map(&normalize_association/1) |> MapSet.new()

    case latest_checkpoint(comments, authorized) do
      nil ->
        %{checkpoint: nil, trigger: nil, dispatchable: true}

      %{comment: checkpoint_comment, checkpoint: checkpoint} ->
        trigger =
          derive_trigger(checkpoint, checkpoint_comment, comments, review_context, authorized)

        %{checkpoint: checkpoint, trigger: trigger, dispatchable: not is_nil(trigger)}
    end
  end

  defp decode_marker(encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, %{"version" => 1} = checkpoint} <- Jason.decode(json),
         :ok <- valid_checkpoint(checkpoint) do
      {:ok, checkpoint}
    else
      _ -> :error
    end
  end

  defp checkpoint_guidance(%{"state" => "awaiting_input", "prompt" => prompt}), do: prompt

  defp checkpoint_guidance(%{"state" => "awaiting_approval", "gate" => gate}) do
    "Reply with `/symphony approve #{gate}` or `/symphony revise <instructions>`."
  end

  defp checkpoint_guidance(%{"state" => "awaiting_review"}) do
    "Symphony is waiting for pull-request review or merge. Use `/symphony revise <instructions>` to request another pass."
  end

  defp checkpoint_guidance(%{"state" => "blocked", "prompt" => prompt}) when is_binary(prompt) do
    prompt <> "\n\nUse `/symphony retry`, `/symphony status`, or `/symphony cancel`."
  end

  defp checkpoint_guidance(%{"state" => "blocked"}) do
    "Use `/symphony retry`, `/symphony status`, or `/symphony cancel`."
  end

  defp checkpoint_guidance(_checkpoint), do: nil

  defp latest_checkpoint(comments, authorized) do
    comments
    |> Enum.filter(&authorized?(&1, authorized))
    |> Enum.flat_map(fn comment ->
      case decode_checkpoint(comment["body"]) do
        {:ok, checkpoint} -> [%{comment: comment, checkpoint: checkpoint}]
        :error -> []
      end
    end)
    |> Enum.max_by(&event_id(&1.comment), fn -> nil end)
  end

  defp derive_trigger(checkpoint, checkpoint_comment, comments, review_context, authorized) do
    later_comments =
      comments
      |> Enum.filter(&(event_id(&1) > event_id(checkpoint_comment)))
      |> Enum.filter(&authorized?(&1, authorized))
      |> Enum.reject(&marker_comment?/1)
      |> Enum.sort_by(&event_id/1)

    case checkpoint["state"] do
      "awaiting_input" -> latest_answer(later_comments)
      "awaiting_approval" -> latest_valid_command(later_comments, checkpoint)
      "blocked" -> latest_valid_command(later_comments, checkpoint)
      "awaiting_review" -> review_trigger(checkpoint, later_comments, review_context, authorized)
    end
  end

  defp latest_answer(comments) do
    comments
    |> List.last()
    |> case do
      nil -> nil
      comment -> event_payload(comment, "answer")
    end
  end

  defp latest_valid_command(comments, checkpoint) do
    comments
    |> Enum.map(&command_event/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&valid_command_for_checkpoint?(&1, checkpoint))
    |> List.last()
  end

  defp valid_command_for_checkpoint?(%{"command" => "approve", "scope" => scope}, checkpoint) do
    checkpoint["state"] == "awaiting_approval" and checkpoint["gate"] == scope
  end

  defp valid_command_for_checkpoint?(%{"command" => "revise"}, checkpoint) do
    checkpoint["state"] in ["awaiting_approval", "awaiting_review", "blocked"]
  end

  defp valid_command_for_checkpoint?(%{"command" => command}, checkpoint)
       when command in @commands do
    case command do
      "retry" -> checkpoint["state"] == "blocked"
      _ -> true
    end
  end

  defp valid_command_for_checkpoint?(_command, _checkpoint), do: false

  defp review_trigger(checkpoint, issue_comments, context, authorized) do
    pull_request = Map.get(context, "pull_request", %{})

    cond do
      pull_request["merged"] == true ->
        %{"kind" => "pull_request", "state" => "merged", "number" => pull_request["number"]}

      pull_request["state"] == "closed" ->
        %{"kind" => "pull_request", "state" => "closed", "number" => pull_request["number"]}

      true ->
        explicit_review_command(checkpoint, issue_comments, context, authorized) ||
          formal_review_trigger(checkpoint, context, authorized)
    end
  end

  defp explicit_review_command(checkpoint, issue_comments, context, authorized) do
    cursor = Map.get(checkpoint, "cursor", %{})

    pr_comments =
      [
        {Map.get(context, "conversation_comments", []), cursor["pr_comment_id"] || 0},
        {Map.get(context, "review_comments", []), cursor["review_comment_id"] || 0}
      ]
      |> Enum.flat_map(fn {events, minimum_id} ->
        Enum.filter(events, &(event_id(&1) > minimum_id and authorized?(&1, authorized)))
      end)

    (issue_comments ++ pr_comments)
    |> Enum.sort_by(&event_id/1)
    |> Enum.map(&command_event/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&valid_command_for_checkpoint?(&1, checkpoint))
    |> List.last()
  end

  defp formal_review_trigger(checkpoint, context, authorized) do
    minimum_id = get_in(checkpoint, ["cursor", "review_id"]) || 0

    actionable_reviews =
      context
      |> Map.get("reviews", [])
      |> Enum.filter(&authorized?(&1, authorized))
      |> Enum.filter(&(normalize_review_state(&1["state"]) in ["approved", "changes_requested"]))

    new_review? = Enum.any?(actionable_reviews, &(event_id(&1) > minimum_id))

    latest_by_reviewer =
      actionable_reviews
      |> Enum.sort_by(&event_id/1)
      |> Enum.reduce(%{}, fn review, acc -> Map.put(acc, get_in(review, ["user", "login"]), review) end)
      |> Map.values()

    change_request =
      latest_by_reviewer
      |> Enum.filter(&(normalize_review_state(&1["state"]) == "changes_requested"))
      |> Enum.max_by(&event_id/1, fn -> nil end)

    approval =
      latest_by_reviewer
      |> Enum.filter(&(normalize_review_state(&1["state"]) == "approved"))
      |> Enum.max_by(&event_id/1, fn -> nil end)

    review = if new_review?, do: change_request || approval

    if review do
      review
      |> event_payload("review")
      |> Map.put("state", normalize_review_state(review["state"]))
    end
  end

  defp command_event(comment) do
    body = comment["body"] || ""

    parsed =
      cond do
        Regex.match?(~r/^\/symphony\s+approve\s+(spec|plan|implementation)\s*$/i, body) ->
          [_, scope] = Regex.run(~r/^\/symphony\s+approve\s+(spec|plan|implementation)\s*$/i, body)
          %{"command" => "approve", "scope" => String.downcase(scope)}

        captures =
            Regex.named_captures(
              ~r/^\/symphony\s+revise(?:\s+(?<scope>spec|plan|implementation))?(?:\s+(?<instructions>.+))?\s*$/is,
              body
            ) ->
          %{"command" => "revise"}
          |> maybe_put("scope", normalize_scope(captures["scope"]))
          |> maybe_put("instructions", normalize_text(captures["instructions"]))

        Regex.match?(~r/^\/symphony\s+(retry|status|cancel)\s*$/i, body) ->
          [_, command] = Regex.run(~r/^\/symphony\s+(retry|status|cancel)\s*$/i, body)
          %{"command" => String.downcase(command)}

        true ->
          nil
      end

    if parsed, do: Map.merge(event_payload(comment, "command"), parsed)
  end

  defp marker_comment?(comment), do: match?({:ok, _}, decode_checkpoint(comment["body"]))

  defp authorized?(event, authorized) do
    MapSet.member?(authorized, normalize_association(event["author_association"]))
  end

  defp event_payload(event, kind) do
    %{
      "kind" => kind,
      "id" => event_id(event),
      "body" => event["body"],
      "author" => get_in(event, ["user", "login"])
    }
  end

  defp event_id(event) when is_map(event) do
    case event["id"] do
      value when is_integer(value) -> value
      _ -> 0
    end
  end

  defp normalize_review_state(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_review_state(_value), do: ""

  defp normalize_association(value) when is_binary(value),
    do: value |> String.trim() |> String.upcase()

  defp normalize_association(_value), do: ""

  defp normalize_scope(value) do
    case normalize_text(value) do
      nil -> nil
      normalized -> String.downcase(normalized)
    end
  end

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_text(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp valid_associations?(values) when is_list(values) and values != [] do
    Enum.all?(values, &(normalize_association(&1) in @default_associations))
  end

  defp valid_associations?(_values), do: false
end
