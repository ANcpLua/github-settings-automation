# github-settings-automation

Private control plane for reproducible repository and organization settings
across `ANcpLua/*` and `O-ANcppLua/*`.

## Scope

In scope:

- idempotent repository settings enforcement
- profile-repository bootstrap
- reusable workflow templates for downstream repositories
- Codex-first review and repair guidance

Out of scope:

- application code
- business logic
- one-off migrations
- repository transfers
- secret rotation

## Retired services

The paid external reviewer surfaces are retired. Do not add their configuration
files, GitHub Actions, secrets, badges, templates, or invocation comments back
to this repository or to generated fleet guidance.

The replacement path is Codex-first:

- Codex GitHub code review is configured in Codex settings, not by a workflow in
  this repository.
- `@codex review` requests a focused review on a pull request.
- `@codex fix ...` starts a Codex cloud task with the pull request as context.
- `AGENTS.md` and `code_review.md` carry durable review guidance for local and
  cloud Codex runs.
- The local operating model is a coordinator plus three roles: Implementer,
  Reviewer, and Improver.

References:

- https://developers.openai.com/codex/integrations/github
- https://developers.openai.com/codex/concepts/customization

## Workflows

| Workflow | Trigger | Effect |
|---|---|---|
| `bootstrap-profile-repos.yml` | manual dispatch | Creates `ANcpLua/ANcpLua` and `O-ANcppLua/.github` if missing. Does not touch `O-ANcppLua/.github-private`. |
| `enforce-repo-settings.yml` | weekly cron (Mon 17:00 UTC) + dispatch | Targets repos carrying `qyl` or `ancplua-fleet` in `topic` mode. PATCHes repos under `ANcpLua` and `O-ANcppLua` to enable `delete_branch_on_merge` and `allow_auto_merge`; removes retired Codacy workflow/config files and the old triage bot (CodeRabbit files are kept — Pro Plus is active again since 2026-06-11); syncs branch-protection overrides; syncs opted-in NuGet publishing; seeds or updates managed Codex guidance (`AGENTS.md`, `code_review.md`); and syncs `auto-merge.yml`. `sweep_mode` dispatch input: `topic`, `recent` (created in last 8 days), `full` (every non-fork active repo). Scheduled cron uses `topic`. |
| `pr-heal.yml` | every 15 min cron + dispatch | Fleet-wide PR handoff. Scans active repos for stuck PRs (`BEHIND`, `DIRTY`, `BLOCKED`, `UNSTABLE`) that should merge and posts one copyable Codex cloud handoff prompt. Targets a single PR via the `target` input (`owner/repo#N`) for ad-hoc dispatch. |
| `drift-check.yml` | weekly cron (Mon 06:00 UTC) + dispatch | Runs the semantic drift detector over the watchlist in `scripts/drift-policy.yaml` and opens or updates a `config-drift` issue when drift is found. |

## Auto-merge posture

No third-party auto-merge App, no destructive merge workflow, and no retired
paid reviewer gate. The fleet relies on:

- GitHub native auto-merge, enabled by `enforce-repo-settings.yml`.
- Renovate `platformAutomerge: true` for dependency PRs that the shared preset
  marks safe.
- Branch protection required checks as the merge authority.
- Codex review as advisory signal through GitHub code review or explicit
  `@codex review`.

Bot and agent PRs using trusted branch prefixes (`codex/`, `copilot/`) can be
auto-flipped by `auto-merge.yml`. Owner-authored PRs flow
through the central `pr-heal.yml` cooldown so Codex review and other advisory
comments can land before merge-on-green is enabled.

### Scenario A: does not merge

Renovate opens a dependency minor bump and enables native auto-merge. The bump
introduces a breaking API change, so a required check fails. Native auto-merge
waits for green CI. Codex review may point at the failing area, but it is not a
merge authority. The PR remains open until Codex cloud or a human fixes the
branch.

### Scenario B: does merge

Renovate opens a trusted patch bump. The shared Renovate preset enables native
auto-merge. CI is green and branch protection is satisfied. GitHub squash-merges
and deletes the branch with no extra reviewer service in the path.

## PR self-healing

`pr-heal.yml` closes the "ready but stuck" gap for a solo-maintainer fleet.
Every 15 minutes, it scans active repositories for open, non-draft PRs that
have auto-merge enabled or carry `auto-resolve`, and whose `mergeStateStatus` is
`BEHIND`, `DIRTY`, `BLOCKED`, or `UNSTABLE`.

The current repair/reporting chain is intentionally flat:

1. Codex cloud handoff prompt. The workflow posts one marked comment containing
   a copyable `@codex ...` prompt. This keeps the Codex path visible without
   claiming that workflow-authored comments are a supported Codex task API.

There is no classic-PAT triage helper, no hardcoded App installation scope, and
no third-party repair action in this lane. Cross-repo PR lookup and comments
reuse `REPO_SETTINGS_PAT_USER` / `REPO_SETTINGS_PAT_ORG`.

## Fleet Cleanup

`scripts/remove-retired-review-automation.sh` removes the retired reviewer
surface from each target repo before guidance sync runs:

- known Codacy config files
- known Codacy workflow files under `.github/workflows/`
- any workflow file whose content still mentions Codacy
- the old `triage-bot.yml` workflow

CodeRabbit files are deliberately exempt: the Pro Plus subscription
re-activated on 2026-06-11 and CodeRabbit is part of the active reviewer set
again. Do not re-add coderabbit paths to the cleanup kill list.

The `enforce-repo-settings.yml` topic sweep runs this cleanup in
`pull_request` mode by default and leaves auto-merge disabled. Repos tagged
`qyl` or `ancplua-fleet` get a cleanup PR only when there is an actual diff to
review. GitHub shows the PR author as the owner of the authenticated
`REPO_SETTINGS_PAT_USER` / `REPO_SETTINGS_PAT_ORG` token, not
`github-actions[bot]`.

The replacement is Codex guidance, not another fake bot trigger. Codex review
is enabled in Codex settings or requested with `@codex review`; repair is
requested with `@codex fix ...` from the PR.

## Templates

`templates/` files are not executed from this repository. They are copied or
seeded into target repositories by `enforce-repo-settings.yml`.

| Template | Adoption mode |
|---|---|
| `AGENTS.md` | Seeded when missing, updated only when the existing file carries the managed marker. Custom downstream files are skipped. |
| `code_review.md` | Same managed-marker behavior as `AGENTS.md`; referenced by the managed `AGENTS.md`. |
| `auto-merge.yml` | Replaced when an existing downstream copy drifts from the canonical template. Repos without the workflow are skipped. |
| `nuget-publish.yml` | Synced only into repos listed under `nuget_publishers:` in `scripts/drift-policy.yaml`. |

Active workflow templates use maintained major action tags instead of pinned
third-party SHAs so version updates flow through the canonical template sync
rather than fossilizing in each repo.

The Renovate preset also avoids static package-version matrices. The Microsoft
Agent Framework policy is one dynamic NuGet family rule: stable and RC versions
are allowed, preview/alpha/beta/dev builds are excluded, and new
`Microsoft.Agents.AI.*` packages match without editing a local allowlist.
The old static `Version.props` custom-manager inventory is gone; dependency
updates now rely on Renovate's native managers and broad package-family rules
instead of hardcoding one XML property per package.

## Required secrets

A single fine-grained PAT cannot span both a user and an org. Two PATs are
required.

| Secret | Resource owner | Permissions | Used by |
|---|---|---|---|
| `REPO_SETTINGS_PAT_USER` | `ANcpLua` (user) | Repository: `Administration: Read and write` + `Contents: Read and write` + `Pull requests: Read and write` + `Workflows: Read and write` + `Issues: Read and write` on all repositories | personal-side enforcement and PR repair |
| `REPO_SETTINGS_PAT_ORG` | `O-ANcppLua` (org) | Repository: `Administration: Read and write` + `Contents: Read and write` + `Pull requests: Read and write` + `Workflows: Read and write` + `Issues: Read and write` on all repositories + Organization: `Administration: Read and write` | org-side enforcement and PR repair |
| `NUGET_USER` | n/a | nuget.org username, not an API key | central NuGet publishing sync |

Both PATs need `Contents: Read and write` because the guidance and workflow
sync steps write files through the repository contents API.

Both PATs need `Pull requests: Read and write` because `pr-heal.yml` checks PR
state and may enable native auto-merge.

Both PATs need `Workflows: Read and write` because the workflow sync steps write
files below `.github/workflows/*`, which GitHub gates behind an additional
permission beyond `Contents: write`.

Both PATs need `Issues: Read and write` because PR conversation comments use
the GitHub issues comments API.

The org PAT needs Organization-level `Administration: write` because creating a
new repo under the org uses an organization-scoped endpoint.

## Config drift detector

`scripts/drift_check.py` audits a watchlist of shared configuration files across
listed repositories and reports semantic drift, not byte-level drift. Whitespace,
JSON key order, and YAML flow style do not create false drift by themselves.

### Running locally

```bash
pip install pyyaml
python scripts/drift_check.py \
  --policy scripts/drift-policy.yaml \
  --output drift-report.md \
  --manifest drift-manifest.json
```

Exit code `0` means all watched paths have one semantic cluster, `1` means
drift was found, and `2` means configuration or authentication failed.

The detector reads GitHub through the `gh` CLI, so `gh auth status` must pass.

### Adding a repo or watched path

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
