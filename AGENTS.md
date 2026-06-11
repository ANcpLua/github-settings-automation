# Repository Agent Guidance

This repository is the control plane for ANcpLua and O-ANcppLua repository
settings. Keep changes operational, evidence-backed, and scoped to fleet
automation.

## Hard Rules

- CodeRabbit Pro Plus is the active AI review and repair surface. Prefer
  CodeRabbit configuration, CodeRabbit review commands, CodeRabbit Autofix, and
  CodeRabbit finishing touches over custom review bots.
- Codacy and the old triage-bot workflow are retired. Do not add their config
  files, workflow actions, secrets, badges, templates, or invocation comments.
- Do not add cron workflows that poll PRs to request reviews or post repair
  handoff prompts. Review and repair automation must be event-driven unless it
  is a settings/drift sweep.
- Keep branch-protection, auto-merge, NuGet publishing, CodeRabbit automation,
  and drift-check logic separate unless a requested change explicitly crosses
  those surfaces.
- Do not claim support, readiness, or cleanup without fresh command evidence.
- Preserve user or pre-existing dirty work unless the user explicitly asks to
  delete it.

## Review Guidelines

Follow `code_review.md` for local reviews and CodeRabbit review guidance. For
PR triage, rely on CodeRabbit automatic review first. If CodeRabbit has posted
actionable inline findings, the canonical follow-up is a separate CodeRabbit
Autofix pass, preferably `@coderabbitai autofix stacked pr`.

Do not recreate reviewer-triage workflows with GitHub Actions comments. The
only workflow-authored reviewer command allowed here is the canonical
CodeRabbit Autofix trigger after a CodeRabbit review with inline comments.

## Verification

Prefer these checks when relevant:

- `bash -n scripts/*.sh`
- `python3 -m py_compile scripts/drift_check.py`
- Parse changed workflow YAML before claiming it is valid.
- Run `rg -n "(Codacy|codacy|triage-bot|reviewer-triage)"` before declaring
  retired review automation removed.
