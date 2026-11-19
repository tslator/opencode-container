# Plan: bead-pilot — gated serial bead-processing skill

**Status:** planned
**Date:** 2026-11-19

## Goal

Add a skill that is the serial counterpart to the `orchestrator` (fleet) skill:
instead of delegating to parallel Herdr workers, the agent processes beads
itself, **one at a time**, with explicit human approval gates between steps.

## Name options

| Option | Rationale |
|---|---|
| **`bead-pilot`** (recommended) | Solo counterpart to the fleet/orchestrator metaphor — one operator, one bead at a time |
| `skipper` | Nautical fleet family (fleet → skipper); short, memorable |
| `bead-by-bead` | Literal, self-documenting in skill lists |
| `conveyor` | Conveys one-item-at-a-time pipeline |
| `cadence` | Emphasizes the steady gated rhythm |

Decision pending at implementation time; plan uses `bead-pilot` as working name.

## Core loop (the skill's workflow)

1. **Claim & explain**
   - `bd ready` → pick top issue (user may override choice); atomic
     `bd update <id> --claim`
   - Present: title, description, acceptance criteria, proposed approach,
     estimated blast radius (files touched)
   - **GATE 1** — stop and wait; only an explicit approval advances.
     Feedback or "no" → adjust approach and re-present, or `bd unclaim` if the
     user rejects the pick.
2. **Implement**
   - Work the issue only; run project tests/lint/build; capture results
   - **GATE 2** — present diff stat + test output; approval advances.
     Rejection → revise and re-gate.
3. **Summarize**
   - One-paragraph summary: what changed, why, test evidence, deviations
   - **GATE 3** — approval authorizes close & commit.
4. **Close & commit**
   - `bd close <id>` + conventional-commit commit of that bead's changes only
     (stage by file, never blind `git add -A`)
   - No push — push always stays user-owned
   - `bd close <id> --suggest-next` → back to step 1

## Gate mechanics (hard rules)

- Use the `question` tool at each gate; never proceed on silence or ambiguity
- Gate keyword handling: `approved`/affirmative → advance; edits/questions →
  loop within the same step; `stop`/`abort` → leave bead claimed-but-in-progress,
  report state
- Never collapse gates (e.g., implement before Gate 1 passes)

## Exit conditions

- `bd ready` empty
- User says stop
- Bead turns out blocked → `bd unclaim` + `bd update --notes`, skip to next

## Git-policy note

Step 4 commits by design — invoking the skill is itself the commit-authority
grant (conventional-commit prefixes, **no push**). This deliberately overrides
the conservative "no commit" default *only while the skill is active*; the
SKILL.md must state that explicitly so it does not look like a violation.

## Deliverables

1. `config/skills/bead-pilot/SKILL.md` (~90 lines, follows
   `vendor/my-skills/SKILL_TEMPLATE.md` conventions: description formula,
   Scope/Workflow/Rules/Done-when, `opencode/autoinvoke: false`)
   - Description formula: *Use when the user explicitly asks to process beads
     one at a time with approval gates. Covers claim, implement, summarize,
     close-and-commit cycle. Not for parallel worker delegation (see
     orchestrator).*
   - Preconditions: beads project present (`bd stats`), `bd prime` once per
     session, git repo baseline noted
2. `config/skills/bead-pilot/references/gate-templates.md` — exact wording for
   the gate prompts (explain / implement-review / summary / loop-continue)
3. Edit `config/skills/orchestrator/SKILL.md` — add "Not for serial gated
   single-bead work (see bead-pilot)" cross-reference
4. Docs: mention the new skill where skills are listed (README/AGENTS.md if
   applicable)
5. Test: scratch beads project (or throwaway `bd create` issues), walk the
   full loop twice, plus rejection paths at each gate

## Open questions

1. Final name (recommend `bead-pilot`)
2. Bead selection: auto-pick top of `bd ready`, or offer the user a choice
   each cycle?
3. Commit granularity: one commit per bead (assumed), or allow step 4 to split
   into multiple logical commits?
4. Should Gate 1 also let the user edit the bead (`bd update --description`)
   before implementation starts?

## Beads

Tracked in `bd`; see `bd list --label=bead-pilot`.
