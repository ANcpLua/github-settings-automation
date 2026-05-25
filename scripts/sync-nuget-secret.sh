#!/usr/bin/env bash
# Sync NUGET_API_KEY repo-secret onto one target repo from the calling
# workflow's environment (where g-s-a's own NUGET_API_KEY secret is
# exposed). One source of truth: rotate the key once on g-s-a, every
# fleet publisher gets the new value on the next sync sweep.
#
# Skips if NUGET_API_KEY env var is empty (caller decides whether that's
# an error — useful for dry-runs).

set -euo pipefail

repo="${1:?usage: sync-nuget-secret.sh <owner/repo>}"
command -v gh >/dev/null || { echo "::error::gh not installed"; exit 1; }

if [ -z "${NUGET_API_KEY:-}" ]; then
  echo "::warning::$repo — NUGET_API_KEY env var not set in sync workflow; secret not synced"
  exit 0
fi

if put_err="$(printf '%s' "$NUGET_API_KEY" | gh secret set NUGET_API_KEY --repo "$repo" --body - 2>&1)"; then
  echo "$repo — NUGET_API_KEY secret synced ✓"
  exit 0
fi

echo "::warning::$repo — failed to set NUGET_API_KEY secret: $put_err"
exit 1
