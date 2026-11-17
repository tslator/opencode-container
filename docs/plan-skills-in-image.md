# Plan: Skills in the container image

**Status:** done — etw, cva.1–6, 89t, 37m all complete (image on opencode 2.2.6, skill.use enforcement verified)
**Date:** 2026-11-17

## Goal

Make the `tslator/my-skills` skill library available to the in-container
OpenCode server **without** `--host-access` (which currently violates network
isolation by routing the container to a host-run HTTP catalog server). Skills
become image content; enablement becomes plain OpenCode configuration with a
global layer and a project layer.

## Model

> image = content · native `skills` key = state · installer = writer ·
> agent = interviewer · launcher = thin plumbing

No HTTP server anywhere. No host→container network path. The `my-skills`
repo stays usage-agnostic: it ships skills + taxonomy + tooling; consumers
decide activation.

## Key facts established during design

- OpenCode V2 `opencode.json` has a first-class `skills` key
  (`https://opencode.ai/config.json`): a string array of **paths or URLs** to
  discover skills from. Local directory paths work natively (proven by
  `my-skills/scripts/e2e_http_catalog.py` stage 2, "zero-copy enable").
- Pointing at a `<subject>-skills/` directory enables every skill in it;
  pointing at individual slug directories gives per-skill control.
  "Disable" = not listed; no subtraction semantics needed.
- Per-skill gating exists natively via the `policies` array
  (`action: "skill.use"`, `resource`, `allow|deny`); the older
  `permission.skill` form is deprecated.
- All `my-skills` skills are now taxonomy status `ready`, so draft gating is
  not required at launch; the mechanism stays for future drafts.
- The final image is distroless: **no bash**, but it ships `python3` (the
  bootstrap entrypoint), `sh` (dash), `git`, `rg`. Every component of this
  plan is invoked as `python3 <script>` directly — no shell required inside
  the container.
- `~/.opencode-container` is mounted at `/app`, and `config/` at
  `/app/.config/opencode` (`OPENCODE_CONFIG_DIR`), so global config edits are
  possible from inside a one-shot container with correct in-container paths.

## Design

### 1. Build (opencode-container)

- `make skills` clones `tslator/my-skills` (private repo; host `gh`/SSH auth)
  at a pinned commit into `vendor/my-skills/` in the build context.
  `vendor/my-skills.sha` records the pin.
- Dockerfile (final stage): `COPY vendor/my-skills /opt/my-skills`
  (root-owned ⇒ effectively read-only to the agent) plus symlink
  `/opt/skills -> /opt/my-skills` so config paths survive repo-layout
  changes.
- Skill content updates = bump SHA + rebuild. Enablement changes = config
  edits only, no rebuild.
- Default `config/opencode.json` ships with a single `skills` entry: the
  `meta-skill-library-admin` skill, so the interview flow can bootstrap all
  other enablement (everything else starts disabled).

### 2. Launcher (`bin/opencode-container`)

- New passthrough subcommand:
  `opencode-container skills <list|enable|disable|status|deps|gate> ...`
  runs a one-shot container with `--entrypoint python3` executing
  `/opt/my-skills/scripts/install_skills.py ...` (distroless-safe; no shell).
  Global operations mount only the state dir; project operations also mount
  cwd at `/workspace`.
- No interactive launcher UI. Optional sugar later: `--skills-setup` seeds
  `opencode run "help me choose skills for this project"`.

### 3. my-skills repo changes

- `install_skills.py enable/disable --config FILE`: a global-config target so
  the baked installer can merge into `/app/.config/opencode/opencode.json`
  using the existing JSONC-preserving edits.
- `enable` implies gating: generate `skill.use` policies from taxonomy
  status (modern `policies` form) so gating never drifts from the skills
  array. No-op today (all skills `ready`); protects future drafts.
- New **`skill-library-admin`** skill: teaches the agent to interview the
  user (read `taxonomy.csv`, ask about workflow and project stack), resolve
  slugs + `--with-deps` closure, preview the diff, and write global vs
  project config via the installer primitives. This is the interactive
  setup/update story.

### 4. Configuration layering

- **Global** — `~/.opencode-container/config/opencode.json` `skills` array:
  how-you-work skills (qualify, product/project management, orchestrator,
  and `skill-library-admin` itself so it can bootstrap its own enablement).
- **Project** — `<project>/.opencode/opencode.json` `skills` array:
  language/domain skills (C++ vs Python). Union with global at runtime.
- Committed project files reference `/opt/skills/...` paths:
  container-specific, accepted tradeoff (the symlink keeps them
  layout-stable).

### 5. Scenarios

- **A (first run):** unchanged launcher behavior creates
  `~/.opencode-container/`, seeds defaults; skills baked but none enabled.
- **B (global setup):** `opencode-container skills enable <slug...> --global`
  or an in-session interview via `skill-library-admin`; writes the global
  config. No network access needed — the repo and installer are in the image.
- **C (project setup):** from the project dir, `opencode-container skills
  enable <slug...> --project .` or the same in-session interview targeting
  `.opencode/opencode.json`. Subsequent changes ("added Qt") are the same
  interview, no special mode.

## Validation gates — PASSED (bead etw, 2026-11-17, opencode 2.0.9 in-image)

Probed with a live `opencode serve` inside the production image (global config
mounted at `/app/.config/opencode`, project config at `/workspace/.opencode`,
distinct probe skills per layer):

1. **Merge semantics — confirmed append.** A project-level `skills` array
   **adds to** the global array; skills from both layers are advertised
   simultaneously. The global/project layering design is sound.
2. **Live reload — watcher picks it up.** Editing the project `skills` array
   while the server runs surfaces newly referenced skills within seconds,
   **no restart or `/api/location/reload` needed**.
3. **Unknown paths — tolerated.** A nonexistent path in `skills` neither
   crashes the server nor hides other skills; typo/drift in config degrades
   gracefully.

## Enable-implies-gate — VERIFIED (bead cva.3, 2026-11-17)

`enable`/`disable`/`gate` maintain `skill.use` deny statements in the
top-level `policies` array (OpenCode ≥2.2.3 hard-deny form) for taxonomy
entries whose Status is not `ready`; 16-check synthetic driver covers
creation, JSONC-preserving edits, idempotency, foreign-statement safety,
and ready-pruning; in-image run verified with a simulated draft. All real
taxonomy entries are `ready`, so gating writes are no-ops today. **Caveat resolved:** image bumped
to opencode 2.2.6 (bead 37m, matches host); the e2e script now includes a
live gate-enforcement check (denied slug absent from `/api/skill`).

## Rejected alternatives

- **Host-run HTTP catalog + `--host-access`** — current workaround; breaks
  network isolation for every host service just to read markdown files.
- **In-container HTTP catalog server** (bootstrap-spawned `http.server`) —
  feasible (python3 exists) but strictly more moving parts than local paths
  for no benefit; the native `skills` key accepts local paths.
- **Custom `skills.json` enablement format** — rejected in favor of the
  native `skills` key for OpenCode compliance and portability; revisit only
  if subtraction semantics, dep-closure authoring, or gating automation
  actually hurt.
- **Runtime bind-mount of a host checkout** — simplest, but makes the image
  non-self-contained and leaks host layout into every launch command.
