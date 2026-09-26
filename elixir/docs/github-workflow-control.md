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
    auth:
      kind: github_app
      app_id: $GITHUB_APP_ID
      installation_id: $GITHUB_APP_INSTALLATION_ID
      private_key_path: $GITHUB_APP_PRIVATE_KEY_PATH
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
and `COLLABORATOR`; comments from all other human associations are ignored for control purposes.
The configured App's exact `Bot` identity may author checkpoint markers, but it can never answer a
question or approve its own work. Existing authorized human-authored markers remain valid.

Build Symphony and run the guided App setup. GitHub opens a prefilled private-App registration page
requesting Contents, Issues, Pull requests, and Workflows write access, with webhooks disabled.
After registering the App, generate and download a private key, install the App on the target
repository, and enter the App and installation IDs when prompted:

```bash
./bin/symphony github-app setup owner/repository --profile default
./bin/symphony github-app verify owner/repository --profile default
./scripts/run-github --app-profile default /absolute/path/to/WORKFLOW.md --port 4000
```

Profiles are stored under
`${XDG_CONFIG_HOME:-~/.config}/symphony-plus/github-apps/<profile>/`. Directories use mode `0700`;
the copied key and `profile.json` use `0600`. The key never belongs in Symphony Plus, a target
repository, or an issue workspace. To rotate a key, generate a replacement in GitHub, create and
verify a new profile name, switch the launcher to it, and then revoke the old key. To add another
repository in the same owner account, update the App installation's repository selection and run
`verify` for that repository; use another profile when GitHub assigns another installation ID.

The launcher exports only the App ID, installation ID, and private-key path to the Symphony host.
Symphony generates short-lived installation tokens, refreshes them before expiry, and removes App
and PAT environment variables from Codex. App comments, labels, PRs, and pushes appear as the
operator-chosen `<app-slug>[bot]` identity. No shared Symphony Plus App or hosted token service
exists.

For legacy PAT operation, omit `auth`, retain `token: $GITHUB_TOKEN`, authenticate `gh`, and launch
without `--app-profile`:

```bash
gh auth login
./scripts/run-github /absolute/path/to/WORKFLOW.md --port 4000
```

The reusable Spec Kit workflow template uses `danger-full-access` for its Codex thread and turns.
This is required because Codex's `workspace-write` sandbox intentionally makes `.git` read-only,
while this workflow must create branches, commit artifacts, and push them. Keep `workspace.root`
pointed at a dedicated Symphony workspace tree; never point it at a developer checkout. The setting
applies to Symphony's issue agents, not to unrelated Codex sessions.

With App authentication, Symphony configures each local issue workspace's commit author to the App
bot and disables inherited Git credential helpers. Agents commit locally and call
`github_git_push`; the host verifies the issue workspace, branch, head SHA, clean tree, and remote
before pushing. App-authenticated pushes intentionally reject SSH workers in this first release.

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

## Troubleshooting

- `missing_github_app_*`: rerun the launcher with the intended `--app-profile` and verify the
  profile files still exist.
- `insecure_github_app_private_key_permissions`: change the copied PEM to mode `0600`.
- HTTP `403`: confirm the App installation includes the repository and has Contents, Issues, Pull
  requests, and Workflows write access. Permission changes must be approved on the installation.
- `github_push_*_mismatch`: inspect the current workspace branch, local `HEAD`, origin URL, and
  uncommitted files; the host tool does not force-push or repair ambiguous state.
- `github_app_push_unsupported_on_ssh_worker`: use a local workspace or the legacy external
  credential path until remote App secret brokering is implemented.
