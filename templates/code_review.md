<!-- ANcpLua-CODEX-GUIDANCE: managed -->

# Code Review Guidance

Review for blocking issues first. Treat the following as high priority:

- automation that can write to the wrong repository, branch, or PR
- GitHub Actions logic that silently succeeds after doing nothing
- claims in documentation that are not backed by the workflow or script behavior
- reintroduction of retired paid reviewer services
- missing validation for changed shell, Python, JSON, or YAML files

For Codex GitHub reviews, focus comments on serious issues and include exact
file and line references. Cosmetic feedback is useful only when it prevents an
operational mistake.

## PR Triage

Use Codex as the replacement triage path:

- request review with `@codex review`
- request a focused review with `@codex review for <risk area>`
- request repair with `@codex fix <specific blocker>`

Do not add bot comments, labels, or workflow logic that mentions retired
reviewer services. If a workflow can only post a handoff prompt, say that
plainly and avoid claiming it starts a Codex task automatically.
