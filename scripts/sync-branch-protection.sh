#!/usr/bin/env bash
# Sync canonical branch-protection overrides onto one repo's default branch.
#
# Why this exists: PR #174 on ANcpLua/ANcpLua.Analyzers was blocked by
# `required_conversation_resolution: true` after CodeRabbit was uninstalled
# (40 orphaned bot review threads, no way to resolve). The canonical policy
# forces that field to `false` so no future bot-uninstall locks the fleet
# out the same way. The sync engine OWNS that field going forward.
#
# Algorithm:
#   1. GET current protection. If branch has none (404), skip — the sync
#      only HEALS existing protection; it never AUTO-ENABLES protection
#      on a previously unprotected branch (that's a deliberate per-repo
#      decision the user makes once).
#   2. Transform the GET response into a PUT-acceptable body. GitHub's
#      GET wraps booleans in {url, enabled} objects; PUT wants bare bools.
#      Also strips `url` / `users_url` / `teams_url` fields the GET adds.
#   3. Merge canonical overrides on top (canonical keys win). Keys in the
#      template's `_comment` / `_why_each_key` namespaces are filtered
#      out so they don't leak into the PUT body.
#   4. PUT the merged body. On failure (403, ruleset conflict, etc.) warn
#      and exit non-zero — the caller in enforce-repo-settings.yml
#      converts that into a `::warning::` annotation but doesn't fail the
#      whole sweep.
#
# Usage: sync-branch-protection.sh <owner/repo> [<branch>] [<policy-file>]
# Defaults: branch=main, policy=templates/branch-protection.json
#
# Exit codes:
#   0   — synced OR skipped cleanly (no protection on branch)
#   1   — transform / PUT failure (caller logs warning, doesn't fail sweep)

set -euo pipefail

repo="${1:?usage: sync-branch-protection.sh <owner/repo> [<branch>] [<policy-file>]}"
branch="${2:-main}"
policy_file="${3:-templates/branch-protection.json}"

[ -f "$policy_file" ] || { echo "::error::policy file not found: $policy_file"; exit 1; }
command -v jq >/dev/null || { echo "::error::jq not installed"; exit 1; }
command -v gh >/dev/null || { echo "::error::gh not installed"; exit 1; }

# ── 1. GET current protection ───────────────────────────────────────────────
get_response="$(gh api "repos/$repo/branches/$branch/protection" 2>&1 || true)"
if echo "$get_response" | grep -qE '"status": *"404"|Branch not protected'; then
  echo "::notice::$repo/$branch — no branch protection; sync skipped"
  exit 0
fi
if ! echo "$get_response" | jq -e '.required_conversation_resolution' >/dev/null 2>&1; then
  echo "::warning::$repo/$branch — unexpected GET response shape; sync skipped"
  echo "$get_response" | head -c 400
  exit 1
fi

# ── 2. Transform GET → PUT body ─────────────────────────────────────────────
# GitHub's GET response has wrapper objects + URLs; PUT wants bare values.
# This filter handles the common cases. Complex required_pull_request_reviews
# with bypass actors needs a fuller transform; for the current fleet, every
# sampled repo has either no required reviews or simple ones, so the basic
# del(.url, .dismissal_restrictions.url, ...) shape suffices.
put_body="$(echo "$get_response" | jq '{
  required_status_checks: (
    if .required_status_checks == null then null
    else {
      strict: .required_status_checks.strict,
      contexts: (.required_status_checks.contexts // []),
      checks: (.required_status_checks.checks // [])
    }
    end
  ),
  enforce_admins: (.enforce_admins.enabled // false),
  required_pull_request_reviews: (
    if .required_pull_request_reviews == null then null
    else (.required_pull_request_reviews
          | del(.url)
          | (if .dismissal_restrictions then .dismissal_restrictions |= del(.url, .users_url, .teams_url) else . end))
    end
  ),
  restrictions: (
    if .restrictions == null then null
    else (.restrictions | del(.url, .users_url, .teams_url))
    end
  ),
  required_conversation_resolution: (.required_conversation_resolution.enabled // false),
  required_linear_history: (.required_linear_history.enabled // false),
  lock_branch: (.lock_branch.enabled // false),
  allow_force_pushes: (.allow_force_pushes.enabled // false),
  allow_deletions: (.allow_deletions.enabled // false),
  allow_fork_syncing: (.allow_fork_syncing.enabled // false),
  block_creations: (.block_creations.enabled // false)
}')"

# ── 3. Merge canonical overrides ────────────────────────────────────────────
# Strip the `_comment` / `_why_each_key` documentation fields from the
# template so they don't end up in the PUT body.
canonical="$(jq 'del(._comment, ._why_each_key)' "$policy_file")"
merged_body="$(jq -n --argjson cur "$put_body" --argjson can "$canonical" '$cur * $can')"

# ── Diff log (only the conv_resolution flip, the headline guarantee) ────────
before_conv="$(echo "$get_response" | jq -r '.required_conversation_resolution.enabled')"
after_conv="$(echo "$merged_body" | jq -r '.required_conversation_resolution')"
if [ "$before_conv" != "$after_conv" ]; then
  echo "$repo/$branch — required_conversation_resolution: $before_conv → $after_conv"
fi

# ── 4. PUT the merged body ──────────────────────────────────────────────────
if put_err="$(echo "$merged_body" | gh api -X PUT "repos/$repo/branches/$branch/protection" --input - 2>&1 >/dev/null)"; then
  echo "$repo/$branch — protection synced ✓"
  exit 0
fi

echo "::warning::$repo/$branch — PUT protection failed: $put_err"
exit 1
