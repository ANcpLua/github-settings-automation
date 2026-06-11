# Code Review Guidance

Review for blocking issues first. Treat the following as high priority:

- automation that can write to the wrong repository, branch, or PR
- GitHub Actions logic that silently succeeds after doing nothing
- claims in documentation that are not backed by workflow or script behavior
- reintroduction of Codacy, the old triage-bot workflow, the coderabbit-autofix
  workflow, reviewer-triage, or any workflow that posts commands at reviewer
  bots
- missing validation for changed shell, Python, JSON, or YAML files

## Reviewer posture

AI reviews are advisory. CodeRabbit reviews PRs from `.coderabbit.yaml` where a
repo carries one, but nothing blocks on it, nothing auto-triages its threads,
and nothing auto-requests fixes. Review comments are input for the human or
their interactive agent — there is no automated follow-up.
