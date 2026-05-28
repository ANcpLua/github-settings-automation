<!-- ANcpLua-CODEX-GUIDANCE: managed -->

# Repository Agent Guidance

This repository participates in the ANcpLua fleet automation model.

## Hard Rules

- Retired paid reviewer services must not be reintroduced. Do not add their
  config files, workflow actions, secrets, badges, templates, or invocation
  comments.
- Prefer Codex GitHub review and Codex cloud tasks for reviewer/repair work.
- Keep repository-specific build, test, and release commands in this file when
  they differ from the default project tooling.
- Do not claim support, readiness, or cleanup without fresh command evidence.

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
