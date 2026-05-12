#!/usr/bin/env bash
# Sync the canonical .coderabbit.yaml posture into one repo.
#
# Two desired states, four real-world delivery cases. The script handles
# all of them in one pass per repo:
#
#   Desired state of the file:
#     1. File missing → seed templates/coderabbit.yaml.
#     2. File present and `request_changes_workflow: true` → flip that line only.
#     3. Otherwise (already advisory or field absent) → no file change.
#
#   Delivery path for cases 1/2:
#     A. Direct PUT to default branch (no ruleset, or owner bypasses).
#     B. Ruleset enforces "changes must be made through a pull request"
#        (e.g. ANcpLua.NET.Sdk's `squash-only-default-branch`) — fall back
#        to creating an automation branch, PUTting on that branch, opening
#        a PR, and enabling native auto-merge so the PR lands once required
#        checks pass.
#
#   Always (every exit path):
#     Dismiss every sticky `CHANGES_REQUESTED` review from coderabbitai[bot]
#     across every OPEN PR in this repo. Sticky reviews submitted under the
#     pre-flip config keep PRs deadlocked even after the config flips, and
#     the migration PR itself would otherwise be deadlocked the same way.
#
# Idempotent: re-runs find no work and emit only `no-op` / `already exists`
# log lines.
#
# Args:
#   $1  repo (e.g. "ANcpLua/ANcpLua.NET.Sdk")
#   $2  path to local templates/coderabbit.yaml (the seed template)
#
# Required env: GH_TOKEN with Contents:write + Pull-requests:write on the repo.

set -euo pipefail

repo="${1:?repo required}"
template_path="${2:?template path required}"
branch_name="automation/coderabbit-advisory-sync"
template_content="$(cat "$template_path")"

log() { printf '[%s] %s\n' "$repo" "$*"; }
warn() { printf '::warning::[%s] %s\n' "$repo" "$*" >&2; }

# Dismiss every open coderabbitai CHANGES_REQUESTED review across the repo's
# open PRs. Called from an EXIT trap so every code path (no-op, direct PUT,
# PR fallback, or even a partial failure exit) unsticks the deadlocked PRs.
dismiss_stale_cr_reviews_on_pr() {
  local pr_n="$1"
  gh api "repos/$repo/pulls/$pr_n/reviews" --jq \
    '.[] | select(.user.login == "coderabbitai[bot]") | select(.state == "CHANGES_REQUESTED") | .id' \
    2>/dev/null | while read -r review_id; do
    [ -z "$review_id" ] && continue
    if gh api "repos/$repo/pulls/$pr_n/reviews/$review_id/dismissals" --method PUT --silent \
        -f "message=Dismissed by github-settings-automation: CodeRabbit is advisory-only under the new posture (request_changes_workflow: false); see https://github.com/ANcpLua/github-settings-automation#auto-merge-posture" \
        2>/dev/null; then
      log "dismissed coderabbitai review $review_id on PR #$pr_n"
    fi
  done
}

dismiss_all_stale_cr_reviews_in_repo() {
  gh api "repos/$repo/pulls?state=open&per_page=100" --jq '.[].number' 2>/dev/null | while read -r pr_n; do
    [ -z "$pr_n" ] && continue
    dismiss_stale_cr_reviews_on_pr "$pr_n" || true
  done
}

trap dismiss_all_stale_cr_reviews_in_repo EXIT

# Repo meta — default branch is whatever the repo says, not hardcoded `main`.
default_branch="$(gh api "repos/$repo" --jq '.default_branch' 2>/dev/null || true)"
if [ -z "$default_branch" ] || [ "$default_branch" = "null" ]; then
  warn "repo not accessible or empty — skipping"
  trap - EXIT  # nothing to dismiss either
  exit 0
fi

# Existing .coderabbit.yaml meta (or empty if 404).
meta="$(gh api "repos/$repo/contents/.coderabbit.yaml?ref=$default_branch" 2>/dev/null || true)"

if [ -z "$meta" ]; then
  mode="seed"
  target_content="$template_content"
  commit_msg="chore: seed canonical .coderabbit.yaml from github-settings-automation"
  existing_sha=""
else
  existing_content="$(jq -r '.content' <<<"$meta" | base64 -d)"
  existing_sha="$(jq -r '.sha' <<<"$meta")"
  if ! grep -qE '^[[:space:]]*request_changes_workflow:[[:space:]]*true[[:space:]]*(#.*)?$' <<<"$existing_content"; then
    log "config no-op — already advisory or field absent"
    # EXIT trap still dismisses stale reviews — they can exist even on
    # already-advisory repos if the flip predates the current open PRs.
    exit 0
  fi
  mode="patch"
  target_content="$(sed -E 's|^([[:space:]]*request_changes_workflow:[[:space:]]*)true([[:space:]]*(#.*)?)$|\1false\2|' <<<"$existing_content")"
  commit_msg="chore: flip request_changes_workflow → false (advisory CodeRabbit posture)"
fi

target_b64="$(printf '%s' "$target_content" | base64 -w0)"

# ---------- Path A: direct PUT to default branch ----------
put_args=("repos/$repo/contents/.coderabbit.yaml" --method PUT --silent
  -f "message=$commit_msg"
  -f "content=$target_b64"
  -f "branch=$default_branch")
[ -n "$existing_sha" ] && put_args+=(-f "sha=$existing_sha")

if direct_err="$(gh api "${put_args[@]}" 2>&1 1>/dev/null)"; then
  log "$mode: direct PUT to $default_branch ok"
  exit 0
fi

# A 409 "Repository rule violations" or 422 "must be made through a pull request"
# is the expected fallback signal; any other error is real.
if ! grep -qE 'Repository rule violations|must be made through a pull request|405' <<<"$direct_err"; then
  warn "$mode: direct PUT failed with non-ruleset error: $(head -c 200 <<<"$direct_err")"
  exit 0
fi
log "$mode: ruleset blocks direct PUT — falling back to PR path"

# ---------- Path B: branch + PR + auto-merge ----------
head_sha="$(gh api "repos/$repo/git/refs/heads/$default_branch" --jq '.object.sha')"
gh api "repos/$repo/git/refs" --method POST --silent \
  -f "ref=refs/heads/$branch_name" \
  -f "sha=$head_sha" 2>/dev/null \
  && log "branch $branch_name created" \
  || log "branch $branch_name already exists — reusing"

branch_sha=""
if [ "$mode" = "patch" ]; then
  branch_sha="$(gh api "repos/$repo/contents/.coderabbit.yaml?ref=$branch_name" --jq '.sha' 2>/dev/null || echo "")"
fi

branch_put_args=("repos/$repo/contents/.coderabbit.yaml" --method PUT --silent
  -f "message=$commit_msg"
  -f "content=$target_b64"
  -f "branch=$branch_name")
[ -n "$branch_sha" ] && branch_put_args+=(-f "sha=$branch_sha")

if ! gh api "${branch_put_args[@]}" 2>/dev/null; then
  current_on_branch="$(gh api "repos/$repo/contents/.coderabbit.yaml?ref=$branch_name" --jq '.content' 2>/dev/null | base64 -d || echo "")"
  if [ "$current_on_branch" = "$target_content" ]; then
    log "branch already carries target content — skipping PUT"
  else
    warn "PUT on branch $branch_name failed"
    exit 0
  fi
fi

opener="$(gh api /user --jq '.login')"
existing_pr="$(gh api "repos/$repo/pulls?head=$opener:$branch_name&state=open" --jq '.[0].number // empty')"

if [ -z "$existing_pr" ]; then
  pr_num="$(gh pr create --repo "$repo" \
    --base "$default_branch" \
    --head "$branch_name" \
    --title "$commit_msg" \
    --body "Automated by [ANcpLua/github-settings-automation](https://github.com/ANcpLua/github-settings-automation) — flips CodeRabbit to advisory-only posture so the fleet relies on native auto-merge instead of bot-review gating. See repo README, *Auto-merge posture*." \
    2>/dev/null | grep -oE '[0-9]+$' || true)"
  if [ -z "$pr_num" ]; then
    warn "gh pr create failed"
    exit 0
  fi
  log "PR #$pr_num opened"
else
  pr_num="$existing_pr"
  log "PR #$pr_num already open — reusing"
fi

gh pr merge "$pr_num" --repo "$repo" --auto --squash --delete-branch 2>/dev/null \
  && log "auto-merge enabled on PR #$pr_num" \
  || log "auto-merge already enabled or could not be enabled on PR #$pr_num"

# EXIT trap dismisses stale CR reviews — covers this new PR plus #143, #145,
# and any other open PRs in this repo carrying sticky CHANGES_REQUESTED.
