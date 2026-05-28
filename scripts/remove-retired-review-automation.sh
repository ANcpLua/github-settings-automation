#!/usr/bin/env bash
# Remove retired reviewer automation from one target repository.
#
# Direct default-branch deletes are attempted first. When repository rules block
# direct writes, the script falls back to a branch + PR and enables native
# auto-merge. Replacement guidance is handled separately by
# scripts/sync-codex-guidance.sh.

set -euo pipefail

repo="${1:?usage: remove-retired-review-automation.sh <owner/repo>}"
branch_name="automation/remove-retired-review-automation"
message="chore: remove retired review automation"

command -v gh >/dev/null || { echo "::error::gh not installed"; exit 1; }
command -v jq >/dev/null || { echo "::error::jq not installed"; exit 1; }

tmp_paths="$(mktemp)"
tmp_unique="$(mktemp)"
trap 'rm -f "$tmp_paths" "$tmp_unique"' EXIT

log() { printf '[%s] %s\n' "$repo" "$*"; }
warn() { printf '::warning::[%s] %s\n' "$repo" "$*" >&2; }

default_branch="$(gh api "repos/$repo" --jq '.default_branch' 2>/dev/null || true)"
if [ -z "$default_branch" ] || [ "$default_branch" = "null" ]; then
  warn "repo not accessible or empty; skipping"
  exit 0
fi

cat > "$tmp_paths" <<'PATHS'
.coderabbit.yaml
.coderabbit.yml
coderabbit.yaml
coderabbit.yml
.codacy.yaml
.codacy.yml
.github/workflows/coderabbit.yml
.github/workflows/coderabbit.yaml
.github/workflows/coderabbit-autofix.yml
.github/workflows/codacy.yml
.github/workflows/codacy.yaml
.github/workflows/codacy-analysis.yml
.github/workflows/codacy-coverage.yml
.github/workflows/codacy-security.yml
.github/workflows/codacy-sast.yml
.github/workflows/triage-bot.yml
PATHS

workflow_paths="$(gh api "repos/$repo/contents/.github/workflows?ref=$default_branch" \
  --jq '.[] | select(.type == "file") | .path' 2>/dev/null || true)"

while IFS= read -r workflow_path; do
  [ -z "$workflow_path" ] && continue
  content_b64="$(gh api "repos/$repo/contents/$workflow_path?ref=$default_branch" --jq '.content // empty' 2>/dev/null || true)"
  content="$(base64 -d <<<"$content_b64" 2>/dev/null || true)"
  if grep -Eiq '(coderabbit|coderabbitai|codacy|codacy-analysis|codacy-coverage)' <<<"$content"; then
    printf '%s\n' "$workflow_path" >> "$tmp_paths"
  fi
done <<<"$workflow_paths"

sort -u "$tmp_paths" > "$tmp_unique"

content_sha() {
  local path="$1"
  local branch="$2"
  gh api "repos/$repo/contents/$path?ref=$branch" --jq '.sha // empty' 2>/dev/null || true
}

delete_file() {
  local path="$1"
  local branch="$2"
  local sha="$3"

  gh api "repos/$repo/contents/$path" --method DELETE --silent \
    -f "message=$message" \
    -f "sha=$sha" \
    -f "branch=$branch"
}

is_ruleset_error() {
  grep -qE 'Repository rule violations|must be made through a pull request|protected branch|required status check|405' <<<"$1"
}

fallback_paths=()
deleted_any=false

while IFS= read -r path; do
  [ -z "$path" ] && continue
  sha="$(content_sha "$path" "$default_branch")"
  if [ -z "$sha" ]; then
    continue
  fi

  if delete_err="$(delete_file "$path" "$default_branch" "$sha" 2>&1 1>/dev/null)"; then
    log "$path: deleted from $default_branch"
    deleted_any=true
    continue
  fi

  if is_ruleset_error "$delete_err"; then
    log "$path: direct delete blocked by repository rules; queueing PR fallback"
    fallback_paths+=("$path")
    continue
  fi

  warn "$path: delete failed with non-ruleset error: $(head -c 200 <<<"$delete_err")"
  exit 1
done < "$tmp_unique"

if [ "${#fallback_paths[@]}" -eq 0 ]; then
  if [ "$deleted_any" = false ]; then
    log "retired review automation no-op"
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

for path in "${fallback_paths[@]}"; do
  sha="$(content_sha "$path" "$branch_name")"
  if [ -z "$sha" ]; then
    log "$path: already absent on $branch_name"
    continue
  fi

  if delete_file "$path" "$branch_name" "$sha" 2>/dev/null; then
    log "$path: deleted from $branch_name"
    continue
  fi

  warn "$path: delete on $branch_name failed"
  exit 1
done

repo_owner="${repo%%/*}"
existing_pr="$(gh api "repos/$repo/pulls?head=$repo_owner:$branch_name&state=open" --jq '.[0].number // empty')"

if [ -z "$existing_pr" ]; then
  pr_url="$(gh pr create --repo "$repo" \
    --base "$default_branch" \
    --head "$branch_name" \
    --title "chore: remove retired review automation" \
    --body "Automated by ANcpLua/github-settings-automation. Removes retired CodeRabbit/Codacy workflow and config files plus the old triage-bot workflow. Codex replacement guidance is synced separately through AGENTS.md and code_review.md." \
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
