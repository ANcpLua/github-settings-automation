# github-settings-automation

Control plane for reproducible repository and organization settings across
`ANcpLua/*` and `O-ANcppLua/*`.

## Scope

In scope:

- idempotent repository settings enforcement
- profile-repository bootstrap
- reusable workflow templates for downstream repositories
- CodeRabbit Pro Plus review and repair automation
- retired reviewer cleanup

Out of scope:

- application code
- business logic
- one-off migrations
- repository transfers
- secret rotation

## Review Model

CodeRabbit Pro Plus is the active review and repair surface.

The fleet model is:

1. CodeRabbit reviews PRs automatically from `.coderabbit.yaml`.
2. If CodeRabbit posts inline findings, `.github/workflows/coderabbit-autofix.yml`
   posts one `@coderabbitai autofix stacked pr` command for that PR head SHA.
3. CodeRabbit Autofix performs the repair in a separate pass and opens a stacked
   PR or reports that it cannot apply a fix.
4. Native GitHub auto-merge waits for branch protection and reviewer approval.

There is no homegrown reviewer-triage parser. CodeRabbit comments are not fed
into a custom bot that tries to interpret AI output. They are fed back to
CodeRabbit Autofix, which is the supported repair path.

The documented CodeRabbit surfaces used here are:

- `.coderabbit.yaml` for automatic review, finishing touches, path
  instructions, and pre-merge checks.
- `@coderabbitai autofix stacked pr` for a separate repair PR after review.
- CodeRabbit finishing-touch recipes for repeated automation cleanup and repair
  tasks.

## Retired Services

Codacy and the old `triage-bot.yml` workflow are retired. Do not add their
configuration files, GitHub Actions, secrets, badges, templates, or invocation
comments back to this repository or generated fleet files.

CodeRabbit is explicitly not part of the retired set.

## Workflows

| Workflow | Trigger | Effect |
|---|---|---|
| `bootstrap-profile-repos.yml` | manual dispatch | Creates `ANcpLua/ANcpLua` and `O-ANcppLua/.github` if missing. Does not touch `O-ANcppLua/.github-private`. |
| `enforce-repo-settings.yml` | weekly cron (Mon 17:00 UTC) + dispatch | Targets repos carrying `qyl` or `ancplua-fleet` in `topic` mode. Enables `delete_branch_on_merge` and `allow_auto_merge`; removes retired Codacy/triage-bot files; syncs branch-protection overrides; syncs opted-in NuGet publishing; syncs `.coderabbit.yaml`; syncs `coderabbit-autofix.yml`; and syncs `auto-merge.yml` where already present. |
| `coderabbit-autofix.yml` | CodeRabbit review submitted + manual dispatch | Posts `@coderabbitai autofix stacked pr` once per PR head SHA only when CodeRabbit has posted inline comments for that head. |
| `drift-check.yml` | weekly cron (Mon 06:00 UTC) + dispatch | Runs the semantic drift detector over the watchlist in `scripts/drift-policy.yaml` and opens or updates a `config-drift` issue when drift is found. |

The removed cron lanes were:

- `codex-review.yml`: posted review requests across the fleet every 15 minutes.
- `pr-heal.yml`: scanned for stuck PRs every 15 minutes and posted repair
  handoff prompts.

Those files were deleted because they duplicated CodeRabbit, created comment
noise, and kept a manual handoff model alive.

## Auto-Merge Posture

No third-party auto-merge App and no destructive merge workflow. The fleet
relies on:

- GitHub native auto-merge, enabled by `enforce-repo-settings.yml`.
- Renovate `platformAutomerge: true` for dependency PRs that the shared preset
  marks safe.
- Branch protection required checks as the merge authority.
- CodeRabbit review and Autofix as the review/repair layer.

`auto-merge.yml` is event-driven. It enables native auto-merge for trusted
automation branches, CodeRabbit-authored PRs, and CodeRabbit approvals. It does
not poll PRs.

## CodeRabbit Sync

`scripts/sync-coderabbit-automation.sh` syncs two files into each target repo:

- `.coderabbit.yaml`
- `.github/workflows/coderabbit-autofix.yml`

It writes directly to the default branch when allowed. If branch protection or
rulesets block the write, it creates or reuses
`automation/coderabbit-pro-plus-sync`, updates the files there, opens a PR, and
tries to enable native auto-merge.

The workflow it syncs is intentionally narrow:

- it is triggered by CodeRabbit review submission, not a cron
- it skips non-CodeRabbit reviews
- it checks that CodeRabbit posted inline comments for the current head SHA
- it posts one marked Autofix command per head SHA
- default delivery is a stacked PR, not direct mutation of the original PR

## Fleet Cleanup

`scripts/remove-retired-review-automation.sh` removes the retired reviewer
surface from each target repo:

- known Codacy config files
- known Codacy workflow files under `.github/workflows/`
- any workflow file whose content still mentions Codacy
- the old `triage-bot.yml` workflow

CodeRabbit files are deliberately exempt.

## Templates

`templates/` files are not executed from this repository. They are copied into
target repositories by `enforce-repo-settings.yml`.

| Template | Adoption mode |
|---|---|
| `coderabbit.yaml` | Synced to `.coderabbit.yaml` in every topic target. |
| `coderabbit-autofix.yml` | Synced to `.github/workflows/coderabbit-autofix.yml` in every topic target. |
| `auto-merge.yml` | Replaced when an existing downstream copy drifts from the canonical template. Repos without the workflow are skipped. |
| `nuget-publish.yml` | Synced only into repos listed under `nuget_publishers:` in `scripts/drift-policy.yaml`. |

Active workflow templates use maintained major action tags or direct `gh` CLI
operations. If a workflow calls a third-party action by SHA, keep the version
comment next to the SHA.

## Required Secrets

A single fine-grained PAT cannot span both a user and an org. Two PATs are
required.

| Secret | Resource owner | Permissions | Used by |
|---|---|---|---|
| `REPO_SETTINGS_PAT_USER` | `ANcpLua` (user) | Repository: `Administration: Read and write` + `Contents: Read and write` + `Pull requests: Read and write` + `Workflows: Read and write` + `Issues: Read and write` on all repositories | personal-side enforcement and workflow/config sync |
| `REPO_SETTINGS_PAT_ORG` | `O-ANcppLua` (org) | Repository: `Administration: Read and write` + `Contents: Read and write` + `Pull requests: Read and write` + `Workflows: Read and write` + `Issues: Read and write` on all repositories + Organization: `Administration: Read and write` | org-side enforcement and workflow/config sync |
| `NUGET_USER` | n/a | nuget.org username, not an API key | central NuGet publishing sync |

Both PATs need `Contents: Read and write` because sync steps write files through
the repository contents API.

Both PATs need `Pull requests: Read and write` because protected repositories
fall back to branch-and-PR updates and may enable native auto-merge.

Both PATs need `Workflows: Read and write` because workflow sync writes files
below `.github/workflows/*`, which GitHub gates behind an additional permission
beyond `Contents: write`.

Both PATs need `Issues: Read and write` because the CodeRabbit Autofix workflow
posts PR comments through the GitHub issues comments API.

The org PAT needs Organization-level `Administration: write` because creating a
new repo under the org uses an organization-scoped endpoint.

## Config Drift Detector

`scripts/drift_check.py` audits a watchlist of shared configuration files across
listed repositories and reports semantic drift, not byte-level drift. Whitespace,
JSON key order, and YAML flow style do not create false drift by themselves.

### Running Locally

```bash
pip install pyyaml
python scripts/drift_check.py \
  --policy scripts/drift-policy.yaml \
  --output drift-report.md \
  --manifest drift-manifest.json
```

Exit code `0` means all watched paths have one semantic cluster, `1` means drift
was found, and `2` means configuration or authentication failed.

The detector reads GitHub through the `gh` CLI, so `gh auth status` must pass.

### Adding a Repo or Watched Path

Edit `scripts/drift-policy.yaml`:

```yaml
repos:
  - ANcpLua/<new-repo>

watch:
  - path: <new-file>
    # optional: normalizer: json
```

The detector chooses a normalizer from the file name unless `normalizer:` is
specified.
