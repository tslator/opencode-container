# Gate prompt templates

Exact wording for the four gates. Every gate is an explicit `question` tool call.
`<id>` = bead ID, `<title>` = issue title. Response handling is identical across
gates unless a gate says otherwise:

- **affirmative** (`approved` / `yes` / `go`) → advance to the next step
- **edits or questions** → answer or adjust within the current step, then re-gate
- **`stop` / `abort`** → leave the bead claimed and `in_progress`, report its
  state, exit the loop

## Gate 1 — explain-and-approve

Ask after presenting title, description, acceptance criteria, proposed approach,
blast radius, and offering a bead-description amendment.

> **Gate 1 — approve the approach for `<id>`?**
> Bead: `<id>` — `<title>`
> Approach: <proposed approach in 2–4 sentences>
> Blast radius: <expected files>
> Only an explicit approval starts implementation.

Options: `approved` · `amend bead description first` · `revise approach` · `reject pick (unclaim, next bead)` · `stop`

Gate-specific handling:
- `amend bead description first` → apply the user's text with
  `bd update <id> --description=...`, re-present, re-gate.
- `reject pick` → `bd update <id> --unclaim`, return to `bd ready`.

## Gate 2 — implement-review

Ask after implementation, presenting `git diff --stat` and test/lint/build output.

> **Gate 2 — review the implementation for `<id>`?**
> Changed: <diff --stat summary>
> Tests: <pass/fail counts, exact commands run>
> Deviations: <none | list>

Options: `approved` · `revise (give feedback)` · `stop`

Gate-specific handling: rejection feedback → revise, re-run quality gates,
re-present Gate 2.

## Gate 3 — summary-approve

Ask after writing the one-paragraph summary.

> **Gate 3 — approve `<id>` for close & commit?**
> Summary: <what changed, why, test evidence, deviations>
> Commit plan: `<type>: <message> (<id>)`, staged files: <list>

Options: `approved` · `revise` · `stop`

Gate-specific handling: approval authorizes exactly one close + one commit for
this bead. Rejection → return to implementation, then re-gate 2 and 3.

## Loop-continue

Ask before starting the next bead when the user has not pre-authorized a full
backlog run.

> **Continue with the next bead?**
> Closed so far: <list>
> Next ready: `<next-id>` — `<next-title>`

Options: `approved (continue)` · `pick a different bead` · `stop here`

Gate-specific handling: `pick a different bead` → show `bd ready` and let the
user choose. `stop here` → exit the loop cleanly (no bead left half-processed).
