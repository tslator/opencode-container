---
name: bead-pilot
description: Use when the user explicitly asks to process beads one at a time with approval gates (claim, implement, summarize, close & commit). Covers the serial gated bead loop in a bd project. Not for parallel worker delegation or spawning agents (see orchestrator).
metadata:
  opencode/autoinvoke: false
---

# Bead Pilot

You are the pilot: you implement each bead yourself, one at a time, and never advance past a gate without explicit user approval. Beads (`bd`) is the durable source of truth. Gate wording: see `references/gate-templates.md` (relative to this skill's directory).

## Preconditions

```bash
bd stats
```

If this fails, report that no beads project is present and stop. Run `bd prime` once per session for current beads rules. Confirm the git repo state (`git status --short`) and note any pre-existing dirty files — never commit those.

## Git policy while this skill is active

Invoking this skill grants commit authority for step 4 only: conventional-commit prefixes (`feat:`/`fix:`/`chore:`…), staged file-by-file for the current bead's changes. **Never push.** Never `git add -A` blindly. This grant does not extend beyond the skill loop.

## The loop

Repeat until an exit condition. One bead at a time; never start bead N+1 before bead N is closed.

### 1. Claim & explain

```bash
bd ready
```

- No ready issues → exit the loop (see Exit).
- Take the top ready issue unless the user redirects. Claim atomically:

```bash
bd update <id> --claim
```

Non-zero exit means someone else claimed it — re-run `bd ready`, pick again.
Then present from `bd show <id>`: title, description, acceptance criteria, your proposed approach, and estimated blast radius (files you expect to touch). Offer the user a chance to amend the bead description (`bd update <id> --description=...`) before you build.

**GATE 1** — ask with the Gate 1 template. Affirmative → step 2. Feedback → adjust approach, re-present, re-gate. Rejection of the pick → `bd unclaim <id>`, back to top of step 1.

### 2. Implement

- Work only this issue. Touch only files in its scope; note any deviation.
- Run the project's tests, linter, and build; capture the actual output.

**GATE 2** — present `git diff --stat` plus test/lint results and ask with the Gate 2 template. Affirmative → step 3. Rejection → revise per feedback, re-run gates, re-present.

### 3. Summarize

Write one paragraph: what changed, why, test evidence, and any deviation from the Gate 1 approach.

**GATE 3** — ask with the Gate 3 template. Affirmative authorizes close & commit. Rejection → return to step 2, fix, re-gate 2 then 3.

### 4. Close & commit

1. `bd close <id>`
2. Commit exactly this bead's files: `git add <file>...` then a conventional-commit message referencing the issue ID.
3. `bd close <id> --suggest-next` — surface newly unblocked work.
4. Return to step 1 with the next ready bead.

## Gate mechanics (hard rules)

- Every gate is an explicit `question` tool call; never treat silence, an unrelated answer, or your own summary as approval.
- Response handling: affirmative (`approved`/`yes`/`go`) → advance; edits or questions → answer/adjust within the same step and re-gate; `stop`/`abort` → leave the bead claimed and in_progress, report its state, exit the loop.
- Never collapse or skip gates. Never implement before Gate 1 passes; never close or commit before Gate 3 passes.

## Exit conditions

- `bd ready` is empty → report the closed list and stop.
- User says stop/abort → report current bead state.
- A bead turns out blocked mid-work → `bd unclaim <id>`, `bd update <id> --notes=<reason>`, tell the user, continue with the next ready bead.

## Rules

- One bead in flight at a time; beads state is truth, transcripts are not.
- Never push. Never commit files unrelated to the current bead. Never amend or squash earlier commits without a separate explicit request.
- Do not create new beads mid-loop unless the user asks or a discovered follow-up needs tracking; file it with `bd create` and mention it — do not silently expand scope.
- Keep each gate's presentation self-contained: the user should be able to decide without reading the code.

## Done when

- The loop has exited on one of the three exit conditions.
- Every touched bead is closed (or unclaimed with notes) and, if Gate 3 passed, committed with a conventional message.
- `git status` shows no uncommitted changes belonging to processed beads; working tree contains only pre-existing or follow-up work.
