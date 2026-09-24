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
