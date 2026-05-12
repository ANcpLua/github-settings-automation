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
| `enforce-repo-settings.yml` | weekly cron (Mon 09:00 UTC) + dispatch | PATCHes repos under `ANcpLua` and `O-ANcppLua` to enable `delete_branch_on_merge` and `allow_auto_merge`, and seeds `templates/coderabbit.yaml` into any target that lacks a `.coderabbit.yaml`. Idempotent. Default mode = last 8 days; pass `full_sweep: true` on dispatch to hit every active repo. |

## Auto-merge posture

No third-party auto-merge App, no per-repo `destructive-auto-merge.yml`. The fleet relies on:

- **GitHub native auto-merge** — `allow_auto_merge: true` patched by `enforce-repo-settings.yml`.
- **Renovate** opens dependency PRs with `platformAutomerge: true` (see [`ANcpLua/renovate-config`](https://github.com/ANcpLua/renovate-config) — the shared baseline most repos extend). Renovate flips GitHub's native auto-merge on the PR; GitHub merges when branch protection's required checks pass.
- **CodeRabbit is advisory.** `templates/coderabbit.yaml` ships with `request_changes_workflow: false` so the bot comments without ever submitting a formal `CHANGES_REQUESTED` review. That is what eliminated the legacy `--admin`-bypass workflow surface; you cannot get blocked by a sticky review that never happens.

The combo is intentionally **modular**: Renovate decides *which* PRs get auto-flipped, branch protection decides what "green" means, CodeRabbit advises in parallel. None of them is a single point of control — that is the whole reason the owned-App plan was dropped.

### Scenario A — does NOT merge (and shouldn't)

Renovate opens a `Microsoft.Extensions.AI` minor bump (`10.5.2 → 10.6.0`). `platformAutomerge: true` flips native auto-merge on. The new minor introduces a breaking API change; the **Backend (.NET)** required check fails. Native auto-merge waits indefinitely for a green required check — there is no `--admin` bypass. CodeRabbit posts comments noting the call-site change but does not block (because it cannot). PR sits open until a human fixes the call site or closes the bump. This is exactly what the legacy destructive tier used to admin-merge through, and exactly what we wanted to stop.

### Scenario B — does merge (the modular dynamic)

Renovate opens a `peakoss/anti-slop` patch bump. `renovate-config` matches `updateTypes: ["patch"]` → `automerge: true`; `platformAutomerge: true` flips native auto-merge on. CI runs (anti-slop scans itself, all checks green) within ~2 min. Branch protection is satisfied. GitHub squash-merges, deletes the branch. Zero human input from open to merged. Same path works for any trusted opener (Renovate / Dependabot / owner / agents) — the difference between A and B is the CI signal, not the actor.

## Templates

`templates/` files are **not** executed from this repo. They are copied into target repos. Workflow YAMLs ship with explicit pinned SHAs (no floating tags — supply-chain hygiene); the CodeRabbit template ships as a complete config.

| Template | Source | Adoption mode |
|---|---|---|
| `coderabbit.yaml` | this repo | auto-seeded by `enforce-repo-settings.yml` into target repos that don't already carry `.coderabbit.yaml`. Repos with bespoke configs (e.g. qyl) keep their own. |
| `anti-slop.yml` | `peakoss/anti-slop@v0.3.0` (SHA `2ee02d20…`) | manual copy. `close-pr: false` for at least two weeks before enabling auto-close. |
| `refix.yml` | `HappyOnigiri/Refix@v1.4.0` (SHA `e0731dae…`) | manual copy. Label-gated (`refix`); never schedule; never auto-merge. Requires classic PAT. |

## Required secrets

A single fine-grained PAT cannot span both a user and an org — fine-grained
PATs are scoped to one resource owner. Two PATs are required.

| Secret | Resource owner | Permissions | Used by |
|---|---|---|---|
| `REPO_SETTINGS_PAT_USER` | `ANcpLua` (user) | Repository: `Administration: Read and write` + `Contents: Read and write` + `Pull requests: Read and write` on All repositories | personal-side steps in both workflows |
| `REPO_SETTINGS_PAT_ORG` | `O-ANcppLua` (org) | Repository: `Administration: Read and write` + `Contents: Read and write` + `Pull requests: Read and write` on All repositories + Organization: `Administration: Read and write` | org-side steps in both workflows |
| `REFIX_CLASSIC_PAT` | n/a | classic PAT: `repo, workflow, read:org, read:discussion` | target repo only, if `refix.yml` is adopted |
| `CLAUDE_CODE_OAUTH_TOKEN` | n/a | from `claude setup-token` | target repo only, if `refix.yml` is adopted |

The org PAT needs Organization-level `Administration: write` because creating
a new repo under the org hits `POST /orgs/{org}/repos`, which is an
organization-scoped endpoint.

Both PATs need `Contents: Read and write` because the `.coderabbit.yaml`
seed step writes a new file via `PUT /repos/{owner}/{repo}/contents/...`,
which `Administration` alone does not authorize.

Both PATs also need `Pull requests: Read and write` because the sync
script falls back to opening a PR (via `gh pr create`) when a repo's
ruleset blocks direct writes to the default branch, and because the
post-sync trap calls
`PUT /repos/.../pulls/N/reviews/M/dismissals` to unstick PRs with
stale `CHANGES_REQUESTED` reviews from coderabbitai[bot]. Without it,
both the `gh pr create` and the dismissal calls silently 403 — the
workflow stays green via `::warning::` lines but does nothing.

Two canonical mis-scope examples from this repo's run history:

- Run `25735412052` — PATs had `Administration` only. Every seed PUT
  hit `HTTP 403 Resource not accessible by personal access token`;
  no `.coderabbit.yaml` files were written.
- Run `25752657861` — PATs had `Administration` + `Contents` but not
  `Pull requests`. The sync step's ruleset-fallback path failed at
  `gh pr create` for `ANcpLua/ANcpLua.NET.Sdk` and the dismissal trap
  logged zero `dismissed` lines, so PRs #143 and #145 stayed BLOCKED
  by stale CodeRabbit `CHANGES_REQUESTED` reviews.

Audit the run logs (not the green tick) until you are sure both PATs
carry every scope above.

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
