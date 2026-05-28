# Repository Agent Guidance

This repository is the control plane for ANcpLua and O-ANcppLua repository
settings. Keep changes operational, evidence-backed, and scoped to fleet
automation.

## Hard Rules

- Retired paid reviewer services must not be reintroduced. Do not add their
  config files, workflow actions, secrets, badges, templates, or invocation
  comments.
- Prefer Codex GitHub review and Codex cloud tasks for reviewer/repair work.
- Keep branch-protection, auto-merge, NuGet publishing, and drift-check logic
  separate unless a requested change explicitly crosses those surfaces.
- Do not claim support, readiness, or cleanup without fresh command evidence.
- Preserve user or pre-existing dirty work unless the user explicitly asks to
  delete it.

## Agent Roles

The default working shape is:

- Coordinator: main Codex thread; owns requirements, integration, and final
  evidence.
- Implementer: makes bounded code or configuration changes.
- Reviewer: checks requirement fit, regressions, and missing tests.
- Improver: simplifies maintainability after the implementation exists.

Use subagents for independent read-heavy or disjoint write tasks. Avoid parallel
edits to the same file.

## Review Guidelines

Follow `code_review.md` for local reviews and Codex GitHub review guidance.
For PR triage, use `@codex review` and `@codex fix ...` comments from a human
or enabled automatic Codex review settings. Do not recreate retired review bots
with GitHub Actions comments.

## Verification

Prefer these checks when relevant:

- `bash -n scripts/*.sh`
- `python3 -m py_compile scripts/drift_check.py`
- Parse changed workflow YAML before claiming it is valid.
- Run `rg -n "(retired reviewer service names|legacy bot handles)"` with the
  concrete terms involved in the cleanup before declaring a service removed.
