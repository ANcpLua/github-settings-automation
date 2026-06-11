# Code Review Guidance

Review for blocking issues first. Treat the following as high priority:

- automation that can write to the wrong repository, branch, or PR
- GitHub Actions logic that silently succeeds after doing nothing
- claims in documentation that are not backed by workflow or script behavior
- reintroduction of Codacy, the old triage-bot workflow, reviewer-triage, or
  non-CodeRabbit review/repair triggers
- missing validation for changed shell, Python, JSON, or YAML files

## CodeRabbit Triage

CodeRabbit is the active review surface. The expected PR flow is:

1. CodeRabbit automatic review runs on PR open/sync according to
   `.coderabbit.yaml`.
2. If CodeRabbit posts inline findings, the event-driven Autofix workflow posts
   `@coderabbitai autofix stacked pr` once for that head SHA.
3. CodeRabbit Autofix opens a separate repair PR or reports why no fix could be
   applied.
4. Native GitHub auto-merge waits for branch protection and CodeRabbit approval
   where configured.

Do not add a second reviewer bot that parses CodeRabbit, Codacy, Copilot, or
other AI comments. CodeRabbit review comments are inputs for CodeRabbit Autofix,
not for a homegrown triage workflow.
