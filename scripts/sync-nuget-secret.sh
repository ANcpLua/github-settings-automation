#!/usr/bin/env bash
# Sync NUGET_USER repo-secret onto one target repo from the calling
# workflow's environment. One source of truth: set the username once on
# g-s-a, every fleet publisher inherits it on the next sync sweep.
#
# NUGET_USER (the nuget.org username, e.g. `ANcpLua`) is what
# `NuGet/login@v1` uses during OIDC trusted-publishing token exchange.
# It replaces the legacy NUGET_API_KEY pattern (rotation no longer
# needed — keys are minted per-workflow-run via OIDC).
#
# Skips silently if NUGET_USER env var is empty (caller decides whether
# that's an error — useful for dry-runs).

set -euo pipefail

repo="${1:?usage: sync-nuget-secret.sh <owner/repo>}"
command -v gh >/dev/null || { echo "::error::gh not installed"; exit 1; }

if [ -z "${NUGET_USER:-}" ]; then
  echo "::warning::$repo — NUGET_USER env var not set in sync workflow; secret not synced"
  exit 0
fi

if put_err="$(printf '%s' "$NUGET_USER" | gh secret set NUGET_USER --repo "$repo" --body - 2>&1)"; then
  echo "$repo — NUGET_USER secret synced ✓"
  exit 0
fi

echo "::warning::$repo — failed to set NUGET_USER secret: $put_err"
exit 1
