#!/usr/bin/env bash
# Sync managed Codex guidance into one target repository.
#
# Existing custom files are left alone. A file is updated only when it carries
# the managed marker from templates/AGENTS.md or templates/code_review.md.
# If default-branch rules block direct writes, the script falls back to an
# automation branch, opens/reuses a PR, and enables native auto-merge.

set -euo pipefail

repo="${1:?usage: sync-codex-guidance.sh <owner/repo> [<agents-template>] [<review-template>]}"
agents_template="${2:-templates/AGENTS.md}"
review_template="${3:-templates/code_review.md}"
marker="ANcpLua-CODEX-GUIDANCE: managed"
branch_name="automation/codex-guidance-sync"

command -v gh >/dev/null || { echo "::error::gh not installed"; exit 1; }
command -v jq >/dev/null || { echo "::error::jq not installed"; exit 1; }
[ -f "$agents_template" ] || { echo "::error::template not found: $agents_template"; exit 1; }
[ -f "$review_template" ] || { echo "::error::template not found: $review_template"; exit 1; }

log() { printf '[%s] %s\n' "$repo" "$*"; }
warn() { printf '::warning::[%s] %s\n' "$repo" "$*" >&2; }

encode_file() {
  base64 < "$1" | tr -d '\n'
}

default_branch="$(gh api "repos/$repo" --jq '.default_branch' 2>/dev/null || true)"
if [ -z "$default_branch" ] || [ "$default_branch" = "null" ]; then
  warn "repo not accessible or empty; skipping"
  exit 0
fi

targets=()
templates=()
messages=()

queue_if_needed() {
  local target="$1"
  local template="$2"
  local current_json
  local current_content

  current_json="$(gh api "repos/$repo/contents/$target?ref=$default_branch" 2>/dev/null || true)"

  if [ -z "$current_json" ]; then
    targets+=("$target")
    templates+=("$template")
    messages+=("chore: seed Codex guidance from github-settings-automation")
    return
  fi

  current_content="$(jq -r '.content // empty' <<<"$current_json" | base64 -d 2>/dev/null || true)"

  if ! grep -q "$marker" <<<"$current_content"; then
    log "skip $target: custom file without managed marker"
    return
  fi

  if [ "$current_content" = "$(cat "$template")" ]; then
    log "$target already canonical"
    return
  fi

  targets+=("$target")
  templates+=("$template")
  messages+=("chore: sync Codex guidance from github-settings-automation")
}

put_file() {
  local target="$1"
  local template="$2"
  local branch="$3"
  local message="$4"
  local sha="$5"
  local content_b64
  local args

  content_b64="$(encode_file "$template")"
  args=("repos/$repo/contents/$target" --method PUT --silent
    -f "message=$message"
    -f "content=$content_b64"
    -f "branch=$branch")
  [ -n "$sha" ] && args+=(-f "sha=$sha")

  gh api "${args[@]}"
}

content_sha() {
  local target="$1"
  local branch="$2"
  local response

  if ! response="$(gh api "repos/$repo/contents/$target?ref=$branch" 2>/dev/null)"; then
    return 0
  fi

  jq -r '.sha // empty' <<<"$response"
}

queue_if_needed "AGENTS.md" "$agents_template"
queue_if_needed "code_review.md" "$review_template"

if [ "${#targets[@]}" -eq 0 ]; then
  log "Codex guidance no-op"
  exit 0
fi

fallback_indexes=()

for i in "${!targets[@]}"; do
  target="${targets[$i]}"
  template="${templates[$i]}"
  message="${messages[$i]}"
  sha="$(content_sha "$target" "$default_branch")"

  if direct_err="$(put_file "$target" "$template" "$default_branch" "$message" "$sha" 2>&1 1>/dev/null)"; then
    log "$target: direct PUT to $default_branch ok"
    continue
  fi

  if grep -qE 'Repository rule violations|must be made through a pull request|405|protected branch' <<<"$direct_err"; then
    log "$target: direct PUT blocked by repository rules; queueing PR fallback"
    fallback_indexes+=("$i")
    continue
  fi

  warn "$target: direct PUT failed with non-ruleset error: $(head -c 200 <<<"$direct_err")"
  exit 1
done

if [ "${#fallback_indexes[@]}" -eq 0 ]; then
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

for i in "${fallback_indexes[@]}"; do
  target="${targets[$i]}"
  template="${templates[$i]}"
  message="${messages[$i]}"
  sha="$(content_sha "$target" "$branch_name")"

  if put_file "$target" "$template" "$branch_name" "$message" "$sha" 2>/dev/null; then
    log "$target: PUT to $branch_name ok"
    continue
  fi

  current_on_branch="$(gh api "repos/$repo/contents/$target?ref=$branch_name" --jq '.content // empty' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [ "$current_on_branch" = "$(cat "$template")" ]; then
    log "$target: branch already carries target content"
    continue
  fi

  warn "$target: PUT on branch $branch_name failed"
  exit 1
done

opener="$(gh api /user --jq '.login')"
existing_pr="$(gh api "repos/$repo/pulls?head=$opener:$branch_name&state=open" --jq '.[0].number // empty')"

if [ -z "$existing_pr" ]; then
  pr_url="$(gh pr create --repo "$repo" \
    --base "$default_branch" \
    --head "$branch_name" \
    --title "chore: sync Codex guidance" \
    --body "Automated by ANcpLua/github-settings-automation. Seeds or updates managed AGENTS.md and code_review.md so Codex local and GitHub review tasks share the same guidance." \
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

if gh pr merge "$pr_num" --repo "$repo" --auto --squash --delete-branch 2>/dev/null; then
  log "auto-merge enabled on PR #$pr_num"
else
  log "auto-merge already enabled or could not be enabled on PR #$pr_num"
fi
