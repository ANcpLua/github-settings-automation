#!/usr/bin/env bash
# Sync the canonical nuget-publish workflow into one target repo.
#
# Why this exists: PR-pushed tags (e.g. QYL/v3.0.0) silently did nothing
# because the repo lacked nuget-publish.yml. The canonical lives in
# github-settings-automation; this script delivers it.
#
# Algorithm:
#   1. Skip if target repo has no global.json (not a .NET repo).
#   2. Skip if target's existing nuget-publish.yml carries a
#      `CANONICAL-DEPARTURE` opt-out marker. That marker is the explicit
#      "this repo intentionally differs" signal; respect it.
#   3. Compute the canonical content + diff against target's current
#      content. Skip if identical.
#   4. PUT the template via Contents API. Surface ruleset / PAT-scope
#      failures as warnings (caller treats as non-fatal sweep noise).
#
# Usage: sync-nuget-publish.sh <owner/repo> [<template-path>]
# Default template: templates/nuget-publish.yml

set -euo pipefail

repo="${1:?usage: sync-nuget-publish.sh <owner/repo> [<template-path>]}"
template="${2:-templates/nuget-publish.yml}"

[ -f "$template" ] || { echo "::error::template not found: $template"; exit 1; }
command -v jq >/dev/null || { echo "::error::jq not installed"; exit 1; }
command -v gh >/dev/null || { echo "::error::gh not installed"; exit 1; }

# Base64 portably (GNU base64 -w0 on Linux, BSD base64 on macOS needs tr)
b64_no_wrap() {
  if base64 --help 2>&1 | grep -q -- '-w'; then
    base64 -w0 "$1"
  else
    base64 < "$1" | tr -d '\n'
  fi
}

# 1. Skip non-.NET repos
if ! gh api "repos/$repo/contents/global.json" --silent 2>/dev/null; then
  echo "::notice::$repo — no global.json; not a .NET repo, nuget-publish sync skipped"
  exit 0
fi

# 2. Check for opt-out marker
existing_json="$(gh api "repos/$repo/contents/.github/workflows/nuget-publish.yml" 2>/dev/null || echo '{}')"
existing_content_b64="$(echo "$existing_json" | jq -r '.content // empty' | tr -d '\n')"
existing_sha="$(echo "$existing_json" | jq -r '.sha // empty')"

if [ -n "$existing_content_b64" ]; then
  # Precise match: only an ACTIVE opt-out marker (line-start, exact
  # `# CANONICAL-DEPARTURE: ` form) counts. The substring also appears
  # in the canonical template's own docstring explaining the marker,
  # which must NOT trigger the opt-out (chicken-and-egg).
  if echo "$existing_content_b64" | base64 -d 2>/dev/null | grep -qE '^# CANONICAL-DEPARTURE: '; then
    echo "::notice::$repo — nuget-publish.yml carries CANONICAL-DEPARTURE marker, sync skipped"
    exit 0
  fi
fi

# 3. Compute desired + diff
desired_b64="$(b64_no_wrap "$template")"
if [ "$existing_content_b64" = "$desired_b64" ]; then
  echo "$repo — nuget-publish.yml already canonical ✓"
  exit 0
fi

# 4. PUT
echo "$repo — seeding/updating canonical nuget-publish.yml"
put_args=(
  -f "message=chore: sync canonical nuget-publish.yml from github-settings-automation"
  -f "content=$desired_b64"
)
[ -n "$existing_sha" ] && put_args+=(-f "sha=$existing_sha")

if put_err="$(gh api "repos/$repo/contents/.github/workflows/nuget-publish.yml" --method PUT --silent "${put_args[@]}" 2>&1)"; then
  echo "$repo — nuget-publish.yml synced ✓"
  exit 0
fi

echo "::warning::$repo — PUT nuget-publish.yml failed: $put_err"
exit 1
