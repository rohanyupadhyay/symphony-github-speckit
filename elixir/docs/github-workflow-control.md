# GitHub workflow control

GitHub workflow control is an optional layer for workflows that need durable questions, approval
gates, and pull-request review loops. GitHub issues are the human interface; Symphony's dashboard
continues to show runtime execution and logs.

## Configure it

```yaml
tracker:
  kind: github
  provider:
    repo: owner/repository
    token: $GITHUB_TOKEN
    workflow_control:
      enabled: true
      authorized_associations:
        - OWNER
        - MEMBER
        - COLLABORATOR
  required_labels: [symphony]
  active_states: [open]
  terminal_states: [closed]
```

The feature is disabled by default. Authorized associations may contain only `OWNER`, `MEMBER`,
and `COLLABORATOR`; comments from all other associations are ignored for control purposes.

Build Symphony, authenticate GitHub CLI, and start with the included launcher:

```bash
gh auth login
./scripts/run-github /absolute/path/to/WORKFLOW.md --port 4000
```

The launcher obtains the current `gh` token, provides it only to the Symphony host process, and
does not print it. Symphony removes GitHub token variables from the Codex child environment.

## Checkpoints and commands

Agents call `github_workflow_checkpoint` with a state, phase, and readable summary. Conditional
fields are `prompt`, `gate`, `branch`, `head_sha`, and `pr_number`. Approval checkpoints require a
40-character pushed commit SHA and branch whose current GitHub head matches that SHA. Review
checkpoints record the current PR conversation, inline-comment, and formal-review IDs so old events
are not handled twice.

Supported commands are:

```text
/symphony approve spec
/symphony approve plan
/symphony approve implementation
/symphony revise [spec|plan|implementation] <instructions>
/symphony retry
/symphony status
/symphony cancel
```

A direct authorized comment resumes only an `awaiting_input` checkpoint. Approval commands must
match the current gate. General issue and PR comments are context, not triggers. Formal requested
changes, formal approval, PR merge/closure, and explicit PR commands can resume an
`awaiting_review` checkpoint. An unresolved change request from any current reviewer takes
precedence over approvals from other reviewers.

Removing the required label makes the issue ineligible immediately. Closing the issue makes it
terminal. The workflow prompt remains responsible for applying `/symphony cancel` by removing the
label, and for closing the issue after a merged PR.

## Recovery and API usage

The latest authorized hidden marker is reconstructed from GitHub comments on every relevant poll,
so restarts need no Symphony database. One issue keeps its existing workspace across phases.

Only issues carrying all configured required labels are enriched. A waiting issue requires its
issue-comment pages to be read each poll. PR endpoints are queried only for `awaiting_review`.
Repositories with many simultaneously labeled issues should increase `polling.interval_ms` and
monitor GitHub rate-limit headers. This implementation uses polling, not webhooks.

This feature does not install GitHub Spec Kit extensions or create one GitHub issue per Spec Kit
task. A repository workflow may invoke its existing local Spec Kit skills while retaining a single
parent GitHub issue.
