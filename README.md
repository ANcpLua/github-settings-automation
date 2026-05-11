# github-settings-automation

Private control plane for reproducible repo and org settings across
`ANcpLua/*` and `O-ANcppLua/*`.

## Scope

In scope: idempotent settings enforcement, profile-repo bootstrap,
reusable workflow templates for downstream repos.

Out of scope: application code, business logic, one-off migrations,
repo transfers, secret rotation.

## Workflows

| Workflow | Trigger | Effect |
|---|---|---|
| `bootstrap-profile-repos.yml` | manual dispatch | Creates `ANcpLua/ANcpLua` and `O-ANcppLua/.github` if missing. Does not touch `O-ANcppLua/.github-private`. |
| `enforce-repo-settings.yml` | weekly cron (Mon 09:00 UTC) + dispatch | PATCHes repos under `ANcpLua` and `O-ANcppLua` created in the last 8 days to enable `delete_branch_on_merge` and `allow_auto_merge`. Idempotent. |

## Templates

`templates/*.yml` files are **not** executed from this repo. They are
copied into target repos. Both ship with pinned-SHA placeholders and
safe defaults.

| Template | Action source | Adoption gate |
|---|---|---|
| `anti-slop.yml` | `peakoss/anti-slop` | Pin SHA; run with `close-pr: false` for at least two weeks before enabling auto-close. |
| `refix.yml` | `HappyOnigiri/Refix` | Pin SHA; label-gated (`refix`); never schedule; never auto-merge. Requires classic PAT. |

## Required secrets

| Secret | Type | Where | Used by |
|---|---|---|---|
| `REPO_SETTINGS_PAT` | fine-grained PAT, `Administration: read/write` on `ANcpLua/*` and `O-ANcppLua/*` | this repo | both workflows |
| `REFIX_CLASSIC_PAT` | classic PAT: `repo, workflow, read:org, read:discussion` | target repo only, if `refix.yml` is adopted | `refix.yml` |
| `CLAUDE_CODE_OAUTH_TOKEN` | from `claude setup-token` | target repo only, if `refix.yml` is adopted | `refix.yml` |

## Manual one-offs (do not automate)

- `ANcpLua/AnimalChat` → `O-ANcppLua/AnimalChat`:
  `gh api -X POST repos/ANcpLua/AnimalChat/transfer -f new_owner=O-ANcppLua`
- `O-ANcppLua/.github-private` currently holds Copilot agent content;
  repurposing as a member-only onboarding README would collide.
- Framework-suite migration (`ANcpLua.NET.Sdk`, `.Analyzers`,
  `.Roslyn.Utilities`, `.Agents`,
  `.OpenTelemetry.SemanticConventions.Analyzers`, `ErrorOrX`,
  `renovate-config`, `ancplua-docs`, `dotcov`) is a separate
  coordinated move; sibling `O-ANcppLua/ANcpLua.OtelConventions.Api`
  already lives in the org.
