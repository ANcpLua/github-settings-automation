#!/usr/bin/env bash
# Sync CodeRabbit Pro+ review configuration and Autofix automation to one repo.

set -euo pipefail

repo="${1:?usage: sync-coderabbit-automation.sh <owner/repo> [<config-template>] [<workflow-template>]}"
config_template="${2:-templates/coderabbit.yaml}"
workflow_template="${3:-templates/coderabbit-autofix.yml}"
branch_name="automation/coderabbit-pro-plus-sync"
message="chore: sync CodeRabbit Pro Plus automation"
write_mode="${CODERABBIT_SYNC_WRITE_MODE:-direct}"
auto_merge="${CODERABBIT_SYNC_AUTO_MERGE:-true}"

command -v gh >/dev/null || { echo "::error::gh not installed"; exit 1; }
command -v jq >/dev/null || { echo "::error::jq not installed"; exit 1; }

[ -f "$config_template" ] || { echo "::error::template not found: $config_template"; exit 1; }
[ -f "$workflow_template" ] || { echo "::error::template not found: $workflow_template"; exit 1; }

case "$write_mode" in
  direct|pull_request) ;;
  *) echo "::error::CODERABBIT_SYNC_WRITE_MODE must be direct or pull_request"; exit 1 ;;
esac

case "$auto_merge" in
  true|false) ;;
  *) echo "::error::CODERABBIT_SYNC_AUTO_MERGE must be true or false"; exit 1 ;;
esac

log() { printf '[%s] %s\n' "$repo" "$*"; }
warn() { printf '::warning::[%s] %s\n' "$repo" "$*" >&2; }

default_branch="$(gh api "repos/$repo" --jq '.default_branch' 2>/dev/null || true)"
if [ -z "$default_branch" ] || [ "$default_branch" = "null" ]; then
  warn "repo not accessible or empty; skipping"
  exit 0
fi

content_sha() {
  local path="$1"
  local branch="$2"
  local response

  if ! response="$(gh api "repos/$repo/contents/$path?ref=$branch" 2>/dev/null)"; then
    return 0
  fi

  jq -r '.sha // empty' <<<"$response"
}

content_text() {
  local path="$1"
  local branch="$2"
  local content_b64

  content_b64="$(gh api "repos/$repo/contents/$path?ref=$branch" --jq '.content // empty' 2>/dev/null || true)"
  if [ -z "$content_b64" ]; then
    return 0
  fi
  base64 -d <<<"$content_b64" 2>/dev/null || true
}

put_file() {
  local path="$1"
  local template="$2"
  local branch="$3"
  local sha="$4"
  local encoded

  encoded="$(base64 < "$template" | tr -d '\n')"
  args=(
    "repos/$repo/contents/$path"
    --method PUT
    --silent
    -f "message=$message"
    -f "content=$encoded"
    -f "branch=$branch"
  )
  if [ -n "$sha" ]; then
    args+=(-f "sha=$sha")
  fi

  gh api "${args[@]}"
}

is_ruleset_error() {
  grep -qE 'Repository rule violations|must be made through a pull request|protected branch|required status check|405' <<<"$1"
}

needs_update() {
  local path="$1"
  local template="$2"
  local branch="$3"
  local current

  current="$(content_text "$path" "$branch")"
  [ "$current" != "$(cat "$template")" ]
}

# Policy per path: "seed" creates the file only when absent — an existing
# .coderabbit.yaml is per-repo tuning (the whole point of CodeRabbit config)
# and must never be flattened back to the fleet template. "replace" keeps the
# file canonical (the autofix workflow is infrastructure, not tuning).
sync_paths=(
  ".coderabbit.yaml|$config_template|seed"
  ".github/workflows/coderabbit-autofix.yml|$workflow_template|replace"
)

skip_seed_existing() {
  local path="$1" policy="$2"
  [ "$policy" = "seed" ] && [ -n "$(content_sha "$path" "$default_branch")" ]
}

pr_needed=false
changed_direct=false

for entry in "${sync_paths[@]}"; do
  path="${entry%%|*}"
  rest="${entry#*|}"
  template="${rest%%|*}"
  policy="${rest#*|}"
  if skip_seed_existing "$path" "$policy"; then
    log "$path exists; preserving per-repo tuning (seed-only)"
    continue
  fi
  if ! needs_update "$path" "$template" "$default_branch"; then
    log "$path already canonical"
    continue
  fi

  if [ "$write_mode" = "pull_request" ]; then
    log "$path: queueing PR update"
    pr_needed=true
    continue
  fi

  sha="$(content_sha "$path" "$default_branch")"
  if put_err="$(put_file "$path" "$template" "$default_branch" "$sha" 2>&1 1>/dev/null)"; then
    log "$path: synced to $default_branch"
    changed_direct=true
    continue
  fi

  if is_ruleset_error "$put_err"; then
    log "$path: direct sync blocked by repository rules; queueing PR fallback"
    pr_needed=true
    continue
  fi

  warn "$path: sync failed with non-ruleset error: $(head -c 200 <<<"$put_err")"
  exit 1
done

if [ "$pr_needed" = false ]; then
  if [ "$changed_direct" = false ]; then
    log "CodeRabbit automation already canonical"
  fi
  exit 0
fi

head_sha="$(gh api "repos/$repo/git/refs/heads/$default_branch" --jq '.object.sha')"
if gh api "repos/$repo/git/refs" --method POST --silent \
    -f "ref=refs/heads/$branch_name" \
    -f "sha=$head_sha" 2>/dev/null; then
  log "branch $branch_name created"
else
  log "branch $branch_name already exists; reusing"
fi

for entry in "${sync_paths[@]}"; do
  path="${entry%%|*}"
  rest="${entry#*|}"
  template="${rest%%|*}"
  policy="${rest#*|}"
  if skip_seed_existing "$path" "$policy"; then
    log "$path exists on $default_branch; preserving per-repo tuning (seed-only)"
    continue
  fi
  if ! needs_update "$path" "$template" "$branch_name"; then
    log "$path already canonical on $branch_name"
    continue
  fi

  sha="$(content_sha "$path" "$branch_name")"
  put_file "$path" "$template" "$branch_name" "$sha"
  log "$path: synced to $branch_name"
done

repo_owner="${repo%%/*}"
existing_pr="$(gh api "repos/$repo/pulls?head=$repo_owner:$branch_name&state=open" --jq '.[0].number // empty')"

if [ -z "$existing_pr" ]; then
  pr_url="$(gh pr create --repo "$repo" \
    --base "$default_branch" \
    --head "$branch_name" \
    --title "chore: sync CodeRabbit Pro Plus automation" \
    --body "Automated by ANcpLua/github-settings-automation. Syncs .coderabbit.yaml and an event-driven CodeRabbit Autofix workflow. The workflow only posts @coderabbitai autofix stacked pr after CodeRabbit itself submits inline review comments, so a separate CodeRabbit Autofix pass performs the repair." \
    2>/dev/null || true)"
  pr_num="$(grep -oE '[0-9]+$' <<<"$pr_url" || true)"
  if [ -z "$pr_num" ]; then
    warn "gh pr create failed"
    exit 1
  fi
  log "PR #$pr_num opened"
else
  pr_num="$existing_pr"
  log "PR #$pr_num already open; reusing"
fi

if [ "$auto_merge" = "false" ]; then
  log "auto-merge disabled on PR #$pr_num"
elif gh pr merge "$pr_num" --repo "$repo" --auto --squash --delete-branch 2>/dev/null; then
  log "auto-merge enabled on PR #$pr_num"
else
  log "auto-merge already enabled or could not be enabled on PR #$pr_num"
fi

