# Worker dispatch prompt template

Fill the placeholders from `bd show <id>` and the current project context. Send as one prompt.

```text
You are a worker agent. Your issue is <id>: <title>.

Issue description:
<description from bd show>

Acceptance criteria:
<acceptance criteria, or "none recorded — verify against the description">

Context:
- Working directory: <cwd>
- Project conventions: read AGENTS.md (and bd prime output) before changing anything.
- Git policy: <conservative: do not commit or push; report changed files | team-maintainer: commit with conventional-commit prefixes, do not push>.
- Do not claim or close other issues. Your issue is already claimed and assigned to you.

Definition of done:
1. The issue's acceptance criteria are met.
2. The project's tests, linter, and build pass (run them; report results).
3. You did not touch files outside the scope of this issue.

Report format — your final message must start with exactly one of:
DONE <id> — one-paragraph summary + list of changed files
BLOCKED <id> — one-paragraph reason + what you need to proceed
```

## Notes for the orchestrator

- Keep the prompt self-contained: the worker cannot see your conversation.
- For multi-file or risky changes, add a design note from `bd show <id>` (`.design` field) if one exists.
- If the worker replies without the required prefix, treat it as ambiguous: read the transcript, then classify as DONE/BLOCKED yourself and note the deviation in the issue with `bd update <id> --notes=...`.
