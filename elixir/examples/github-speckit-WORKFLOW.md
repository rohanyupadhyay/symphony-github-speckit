---
tracker:
  kind: github
  provider:
    repo: OWNER/REPOSITORY
    token: $GITHUB_TOKEN
    workflow_control:
      enabled: true
      authorized_associations: [OWNER, MEMBER, COLLABORATOR]
  required_labels: [symphony]
  active_states: [open]
  terminal_states: [closed]
polling:
  interval_ms: 30000
workspace:
  root: /absolute/path/to/symphony-workspaces/PROJECT
hooks:
  after_create: |
    git clone --depth 1 https://github.com/OWNER/REPOSITORY.git .
  timeout_ms: 300000
agent:
  max_concurrent_agents: 1
  max_turns: 20
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
---

You are advancing GitHub issue `{{ issue.identifier }}` through one durable Spec Kit workflow.

Before acting, use `github_api` to read the current issue, all issue comments, and any linked pull
request feedback. Read `issue.native_ref.workflow_control` to determine the current checkpoint and
trigger. Work only inside the current issue workspace.

Use one branch named `symphony/gh-{{ issue.id }}-<short-slug>` and one feature directory named
`specs/gh-{{ issue.id }}-<short-slug>`. Set `SPECIFY_FEATURE_DIRECTORY` for the first specify run;
the repository-local `.specify/feature.json` preserves it for later sessions.

Advance exactly one state machine:

1. Run the repository's local `speckit-specify` and `speckit-clarify` skills.
2. Commit and push the specification artifacts, then checkpoint `awaiting_approval` at gate `spec`.
3. After `/symphony approve spec`, run `speckit-plan`, commit and push, then checkpoint gate `plan`.
4. After plan approval, run `speckit-checklist`, `speckit-tasks`, and `speckit-analyze`. Remediate
   critical or high findings by rerunning the owning phase, at most three times.
5. Commit and push all planning artifacts, then checkpoint gate `implementation`.
6. After implementation approval, run `speckit-implement`, then `speckit-converge`. If converge
   appends tasks, repeat implement/converge, at most three times.
7. Validate, commit, push, and open a pull request without auto-merge keywords. Post an
   `awaiting_review` checkpoint containing its number.
8. Apply implementation-only review feedback directly. Requirements or design feedback re-enters
   the corresponding Spec Kit phase and approval gate. Update the same branch and PR.
9. After merge, comment with final validation and close the parent issue. If the PR closes without
   merge, ask for revise, replacement, or cancellation instead.

When a Spec Kit skill needs input, do not invoke an in-process input request. Post an
`awaiting_input` checkpoint and end the turn. `specify` may ask one batch of up to three questions;
`clarify` asks one at a time up to five; `checklist` may ask three initial and two follow-up
questions. Treat `/symphony approve implementation` as permission to proceed past intentionally
unchecked reviewer-owned checklists.

Use `blocked` only with a concrete recovery prompt. `/symphony status` reports current artifacts
and validation and then restores the same checkpoint. `/symphony cancel` removes the `symphony`
label and posts a cancellation comment. Never merge automatically, expose credentials, install the
official GitHub Spec Kit extension, or use `speckit-taskstoissues`.
