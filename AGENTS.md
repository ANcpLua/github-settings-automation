# Repository Agent Guidance

This repository is the control plane for ANcpLua and O-ANcppLua repository
settings. Keep changes operational, evidence-backed, and scoped to fleet
automation.

## Hard Rules

- AI reviews are ADVISORY. No reviewer bot may block a merge, auto-comment
  commands at other bots, or auto-"fix" PRs. There is no auto-triage and no
  auto-autofix — those surfaces are retired (2026-06-11).
- Codacy, the old triage-bot workflow, and the coderabbit-autofix workflow are
  retired. Do not add their config files, workflow actions, secrets, badges,
  templates, or invocation comments.
- Do not add cron workflows that poll PRs to request reviews or post repair
  handoff prompts. Automation must be event-driven unless it is a
  settings/drift sweep.
- Keep branch-protection, auto-merge, NuGet publishing, and drift-check logic
  separate unless a requested change explicitly crosses those surfaces.
- Do not claim support, readiness, or cleanup without fresh command evidence.
- Preserve user or pre-existing dirty work unless the user explicitly asks to
  delete it.

## Review Guidelines

Follow `code_review.md` for local reviews. Reviewer findings (CodeRabbit,
Copilot, Codex) are advisory input for the human or their interactive agent —
nothing acts on them automatically.

Do not recreate reviewer-triage workflows with GitHub Actions comments, and do
not add workflows that post commands at reviewer bots.

## Verification

Prefer these checks when relevant:

- `bash -n scripts/*.sh`
- `python3 -m py_compile scripts/drift_check.py`
- Parse changed workflow YAML before claiming it is valid.
- Run `rg -n "(Codacy|codacy|triage-bot|reviewer-triage)"` before declaring
  retired review automation removed.
