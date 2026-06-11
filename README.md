# github-settings-automation

Control plane for reproducible repository and organization settings across
`ANcpLua/*` and `O-ANcppLua/*`.

## Scope

In scope:

- idempotent repository settings enforcement
- profile-repository bootstrap
- reusable workflow templates for downstream repositories
- retired reviewer cleanup

Out of scope:

- application code
- business logic
- one-off migrations
- repository transfers
- secret rotation

## Review Model

AI reviews are **advisory**. CodeRabbit reviews PRs from `.coderabbit.yaml`
where a repo carries one, but nothing blocks on a review, nothing auto-triages
review threads, and nothing auto-requests fixes. Review comments are input for
the human (or their interactive agent) — there is no automated follow-up.

This control plane does not seed, sync, or run any reviewer automation.

## Retired Services

Codacy, the old `triage-bot.yml` workflow, and the `coderabbit-autofix.yml`
workflow (auto-commenting commands at reviewer bots) are retired. Do not add
their configuration files, GitHub Actions, secrets, badges, templates, or
invocation comments back to this repository or generated fleet files.

Per-repo `.coderabbit.yaml` config files are not part of the retired set —
they are wanted per-repo review tuning and are never touched by cleanup.

## Workflows

| Workflow | Trigger | Effect |
|---|---|---|
| `bootstrap-profile-repos.yml` | manual dispatch | Creates `ANcpLua/ANcpLua` and `O-ANcppLua/.github` if missing. Does not touch `O-ANcppLua/.github-private`. |
| `enforce-repo-settings.yml` | weekly cron (Mon 17:00 UTC) + dispatch | Targets repos carrying `qyl` or `ancplua-fleet` in `topic` mode. Enables `delete_branch_on_merge` and `allow_auto_merge`; removes retired Codacy/triage-bot/coderabbit-autofix files; syncs branch-protection overrides; syncs opted-in NuGet publishing; and syncs `auto-merge.yml` where already present. |
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

`auto-merge.yml` is event-driven. It enables native auto-merge for trusted
automation branches. It does not poll PRs.

## Fleet Cleanup

`scripts/remove-retired-review-automation.sh` removes the retired reviewer
surface from each target repo:

- known Codacy config files
- known Codacy workflow files under `.github/workflows/`
- any workflow file whose content still mentions Codacy
- the old `triage-bot.yml` workflow
- the retired `coderabbit-autofix.yml` workflow

Per-repo `.coderabbit.yaml` config files are deliberately exempt.

## Templates

`templates/` files are not executed from this repository. They are copied into
target repositories by `enforce-repo-settings.yml`.

| Template | Adoption mode |
|---|---|
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

Both PATs need `Issues: Read and write` because cleanup and drift workflows
post PR/issue comments through the GitHub issues comments API.

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
