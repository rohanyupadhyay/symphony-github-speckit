defmodule SymphonyElixir.GitHub.WorkflowControlTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.WorkflowControl

  @authorized ["OWNER", "MEMBER", "COLLABORATOR"]

  test "validates optional workflow-control provider settings" do
    assert :ok = WorkflowControl.validate_settings(%{})

    assert :ok =
             WorkflowControl.validate_settings(%{
               "workflow_control" => %{
                 "enabled" => true,
                 "authorized_associations" => @authorized
               }
             })

    assert {:error, :invalid_github_workflow_control} =
             WorkflowControl.validate_settings(%{"workflow_control" => true})

    assert {:error, :invalid_github_workflow_associations} =
             WorkflowControl.validate_settings(%{
               "workflow_control" => %{
                 "enabled" => true,
                 "authorized_associations" => ["OWNER", "CONTRIBUTOR"]
               }
             })

    refute WorkflowControl.enabled?(%{})

    assert WorkflowControl.enabled?(%{
             "workflow_control" => %{"enabled" => true}
           })

    assert WorkflowControl.authorized_associations(%{
             "workflow_control" => %{"enabled" => true}
           }) == @authorized

    assert {:error, :invalid_github_workflow_control} = WorkflowControl.validate_settings(nil)
    refute WorkflowControl.enabled?(nil)
    assert WorkflowControl.authorized_associations(nil) == @authorized

    assert {:error, :invalid_github_workflow_control} =
             WorkflowControl.validate_settings(%{"workflow_control" => %{"enabled" => "yes"}})

    assert {:error, :invalid_github_workflow_associations} =
             WorkflowControl.validate_settings(%{
               "workflow_control" => %{"authorized_associations" => []}
             })

    assert {:error, :invalid_github_workflow_associations} =
             WorkflowControl.validate_settings(%{
               "workflow_control" => %{"authorized_associations" => "OWNER"}
             })

    assert WorkflowControl.authorized_associations(%{
             "workflow_control" => %{"authorized_associations" => [" owner ", 7]}
           }) == ["OWNER", ""]
  end

  test "renders and decodes a versioned checkpoint without exposing marker data as prose" do
    checkpoint = %{
      "state" => "awaiting_approval",
      "phase" => "specify",
      "summary" => "The specification is ready.",
      "gate" => "spec",
      "branch" => "symphony/gh-42-add-auth",
      "head_sha" => String.duplicate("a", 40),
      "cursor" => %{"review_id" => 8}
    }

    body = WorkflowControl.render_comment(checkpoint)

    assert body =~ "The specification is ready."
    assert body =~ "/symphony approve spec"
    assert {:ok, decoded} = WorkflowControl.decode_checkpoint(body)
    assert decoded == Map.put(checkpoint, "version", 1)
    assert :error = WorkflowControl.decode_checkpoint(body <> "\n<!-- symphony-control:v1:not-base64 -->")
    assert :error = WorkflowControl.decode_checkpoint(nil)

    for invalid <- [
          nil,
          %{},
          %{"state" => "unknown", "phase" => "x", "summary" => "x"},
          %{"state" => "blocked", "phase" => "", "summary" => "x"},
          %{"state" => "blocked", "phase" => "x", "summary" => ""},
          %{"state" => "awaiting_input", "phase" => "x", "summary" => "x"},
          %{"state" => "awaiting_input", "phase" => "x", "summary" => "x", "prompt" => ""},
          %{"state" => "awaiting_approval", "phase" => "x", "summary" => "x"},
          %{"state" => "awaiting_approval", "phase" => "x", "summary" => "x", "gate" => "x"},
          %{"state" => "awaiting_review", "phase" => "x", "summary" => "x"},
          %{"state" => "awaiting_review", "phase" => "x", "summary" => "x", "pr_number" => 0}
        ] do
      assert {:error, _reason} = WorkflowControl.valid_checkpoint(invalid)
    end

    assert WorkflowControl.render_comment(%{
             "state" => "awaiting_review",
             "phase" => "review",
             "summary" => "Review it.",
             "pr_number" => 2
           }) =~ "pull-request review"

    assert WorkflowControl.render_comment(%{
             "state" => "blocked",
             "phase" => "push",
             "summary" => "Blocked."
           }) =~ "/symphony retry"

    assert WorkflowControl.render_comment(%{"phase" => "other"}) =~ "Symphony is waiting."
  end

  test "derives an initially dispatchable issue and ignores malformed event fields" do
    assert %{checkpoint: nil, trigger: nil, dispatchable: true} =
             WorkflowControl.derive(
               [
                 %{"id" => "bad", "author_association" => "OWNER", "body" => nil},
                 %{"id" => 1, "author_association" => 7, "body" => nil}
               ],
               %{},
               @authorized
             )

    malformed_id_checkpoint =
      checkpoint_comment(2, "blocked", %{})
      |> Map.put("id", "not-an-integer")

    assert %{checkpoint: %{"state" => "blocked"}, dispatchable: false} =
             WorkflowControl.derive([malformed_id_checkpoint], %{}, @authorized)
  end

  test "awaiting input resumes only for a later authorized non-marker comment" do
    checkpoint = checkpoint_comment(10, "awaiting_input", %{"prompt" => "Which retention period?"})

    unauthorized = comment(11, "NONE", "Forever")
    marker = checkpoint_comment(12, "awaiting_input", %{"prompt" => "Still waiting"})
    answer = comment(13, "COLLABORATOR", "Use 30 days.")

    assert %{dispatchable: false, checkpoint: %{"prompt" => "Still waiting"}, trigger: nil} =
             WorkflowControl.derive([checkpoint, unauthorized, marker], %{}, @authorized)

    assert %{dispatchable: true, trigger: %{"kind" => "answer", "id" => 13, "body" => "Use 30 days."}} =
             WorkflowControl.derive([checkpoint, unauthorized, marker, answer], %{}, @authorized)
  end

  test "trusts exact App bot checkpoints without allowing the bot to answer itself" do
    bot_checkpoint =
      checkpoint_comment(14, "awaiting_input", %{"prompt" => "Choose a retention period."})
      |> put_in(["author_association"], "NONE")
      |> put_in(["user"], %{"login" => "verity-symphony[bot]", "type" => "Bot"})

    bot_answer =
      comment(15, "NONE", "Use forever")
      |> put_in(["user"], %{"login" => "verity-symphony[bot]", "type" => "Bot"})

    assert %{dispatchable: false, checkpoint: %{"state" => "awaiting_input"}, trigger: nil} =
             WorkflowControl.derive(
               [bot_checkpoint, bot_answer],
               %{},
               @authorized,
               "verity-symphony[bot]"
             )

    human_answer = comment(16, "OWNER", "Use 30 days")

    assert %{dispatchable: true, trigger: %{"kind" => "answer", "id" => 16}} =
             WorkflowControl.derive(
               [bot_checkpoint, bot_answer, human_answer],
               %{},
               @authorized,
               "verity-symphony[bot]"
             )
  end

  test "rejects spoofed or different bot checkpoint authors" do
    checkpoint_body =
      checkpoint_comment(17, "blocked", %{})
      |> Map.fetch!("body")

    spoofed_user = %{
      "id" => 17,
      "author_association" => "NONE",
      "body" => checkpoint_body,
      "user" => %{"login" => "verity-symphony[bot]", "type" => "User"}
    }

    other_bot = put_in(spoofed_user, ["user"], %{"login" => "other[bot]", "type" => "Bot"})

    assert %{checkpoint: nil, dispatchable: true} =
             WorkflowControl.derive(
               [spoofed_user, other_bot],
               %{},
               @authorized,
               "verity-symphony[bot]"
             )
  end

  test "approval gates accept only matching explicit commands and classify revisions" do
    checkpoint = checkpoint_comment(20, "awaiting_approval", %{"gate" => "plan"})

    refute WorkflowControl.derive(
             [checkpoint, comment(21, "OWNER", "looks good")],
             %{},
             @authorized
           ).dispatchable

    refute WorkflowControl.derive(
             [checkpoint, comment(22, "OWNER", "/symphony approve spec")],
             %{},
             @authorized
           ).dispatchable

    assert %{
             dispatchable: true,
             trigger: %{"kind" => "command", "command" => "approve", "scope" => "plan"}
           } =
             WorkflowControl.derive(
               [checkpoint, comment(23, "MEMBER", "/symphony approve plan")],
               %{},
               @authorized
             )

    assert %{
             dispatchable: true,
             trigger: %{
               "kind" => "command",
               "command" => "revise",
               "scope" => "implementation",
               "instructions" => "Cover the Timeout Path"
             }
           } =
             WorkflowControl.derive(
               [
                 checkpoint,
                 comment(
                   24,
                   "COLLABORATOR",
                   "/symphony revise implementation Cover the Timeout Path"
                 )
               ],
               %{},
               @authorized
             )
  end

  test "blocked checkpoints accept retry status revise and cancel but not general comments" do
    checkpoint = checkpoint_comment(30, "blocked", %{"prompt" => "Push permission is missing."})

    refute WorkflowControl.derive(
             [checkpoint, comment(31, "OWNER", "I fixed it")],
             %{},
             @authorized
           ).dispatchable

    for command <- ["retry", "status", "cancel"] do
      assert %{dispatchable: true, trigger: %{"command" => ^command}} =
               WorkflowControl.derive(
                 [checkpoint, comment(32, "OWNER", "/symphony #{command}")],
                 %{},
                 @authorized
               )
    end

    assert %{dispatchable: true, trigger: %{"command" => "revise"}} =
             WorkflowControl.derive(
               [checkpoint, comment(33, "OWNER", "/symphony revise")],
               %{},
               @authorized
             )

    assert %{dispatchable: true, trigger: %{"command" => "revise", "scope" => "plan"}} =
             WorkflowControl.derive(
               [checkpoint, comment(34, "OWNER", "/symphony revise plan")],
               %{},
               @authorized
             )
  end

  test "review state prioritizes unresolved change requests and ignores general PR comments" do
    checkpoint =
      checkpoint_comment(40, "awaiting_review", %{
        "pr_number" => 7,
        "cursor" => %{"review_id" => 100, "pr_comment_id" => 200, "review_comment_id" => 300}
      })

    context = %{
      "pull_request" => %{"number" => 7, "state" => "open", "merged" => false},
      "conversation_comments" => [comment(201, "OWNER", "A general observation")],
      "review_comments" => [comment(301, "COLLABORATOR", "Please rename this variable")],
      "reviews" => [
        review(101, "alice", "COLLABORATOR", "APPROVED"),
        review(102, "bob", "MEMBER", "CHANGES_REQUESTED")
      ]
    }

    assert %{
             dispatchable: true,
             trigger: %{"kind" => "review", "state" => "changes_requested", "id" => 102}
           } = WorkflowControl.derive([checkpoint], context, @authorized)

    superseded =
      put_in(context, ["reviews"], context["reviews"] ++ [review(103, "bob", "MEMBER", "APPROVED")])

    assert %{
             dispatchable: true,
             trigger: %{"kind" => "review", "state" => "approved", "id" => 103}
           } = WorkflowControl.derive([checkpoint], superseded, @authorized)
  end

  test "a new approval does not override another reviewer's pre-checkpoint change request" do
    checkpoint =
      checkpoint_comment(45, "awaiting_review", %{
        "pr_number" => 7,
        "cursor" => %{"review_id" => 101}
      })

    context = %{
      "pull_request" => %{"number" => 7, "state" => "open", "merged" => false},
      "reviews" => [
        review(101, "bob", "MEMBER", "CHANGES_REQUESTED"),
        review(102, "alice", "COLLABORATOR", "APPROVED")
      ]
    }

    assert %{
             dispatchable: true,
             trigger: %{"kind" => "review", "state" => "changes_requested", "id" => 101}
           } = WorkflowControl.derive([checkpoint], context, @authorized)
  end

  test "review state dispatches explicit PR commands and merge or close events" do
    checkpoint = checkpoint_comment(50, "awaiting_review", %{"pr_number" => 9})

    explicit = %{
      "pull_request" => %{"number" => 9, "state" => "open", "merged" => false},
      "conversation_comments" => [comment(60, "OWNER", "/symphony revise fix the API name")]
    }

    assert %{dispatchable: true, trigger: %{"command" => "revise"}} =
             WorkflowControl.derive([checkpoint], explicit, @authorized)

    assert %{dispatchable: true, trigger: %{"kind" => "pull_request", "state" => "merged"}} =
             WorkflowControl.derive(
               [checkpoint],
               %{"pull_request" => %{"number" => 9, "state" => "closed", "merged" => true}},
               @authorized
             )

    assert %{dispatchable: true, trigger: %{"kind" => "pull_request", "state" => "closed"}} =
             WorkflowControl.derive(
               [checkpoint],
               %{"pull_request" => %{"number" => 9, "state" => "closed", "merged" => false}},
               @authorized
             )

    invalid_command_context = %{
      "pull_request" => %{"number" => 9, "state" => "open", "merged" => false},
      "review_comments" => [comment(61, "OWNER", "/symphony approve plan")],
      "reviews" => [review(62, "nobody", "OWNER", nil)]
    }

    refute WorkflowControl.derive([checkpoint], invalid_command_context, @authorized).dispatchable
  end

  test "review commands are ordered by creation time across GitHub event collections" do
    checkpoint = checkpoint_comment(70, "awaiting_review", %{"pr_number" => 11})

    older_inline =
      comment(900, "OWNER", "/symphony cancel")
      |> Map.delete("created_at")

    newer_conversation =
      comment(100, "OWNER", "/symphony status")
      |> Map.put("created_at", "2026-09-24T02:00:00Z")

    context = %{
      "pull_request" => %{"number" => 11, "state" => "open", "merged" => false},
      "conversation_comments" => [newer_conversation],
      "review_comments" => [older_inline]
    }

    assert %{trigger: %{"command" => "status"}} =
             WorkflowControl.derive([checkpoint], context, @authorized)
  end

  defp checkpoint_comment(id, state, extra) do
    checkpoint =
      Map.merge(
        %{"state" => state, "phase" => "test", "summary" => "Checkpoint #{id}"},
        extra
      )

    comment(id, "OWNER", WorkflowControl.render_comment(checkpoint))
  end

  defp comment(id, association, body) do
    %{
      "id" => id,
      "author_association" => association,
      "body" => body,
      "user" => %{"login" => "user-#{id}"},
      "created_at" => "2026-09-24T00:00:00Z"
    }
  end

  defp review(id, login, association, state) do
    %{
      "id" => id,
      "state" => state,
      "author_association" => association,
      "user" => %{"login" => login},
      "body" => "Review #{id}",
      "submitted_at" => "2026-09-24T00:00:00Z"
    }
  end
end
