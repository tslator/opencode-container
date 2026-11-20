# Plan: remove `config/skills/` (orchestrator + herdr)

Date: 2026-11-20

## Context

- `config/skills/` currently holds only `herdr/` and `orchestrator/`. `bead-pilot`
  already migrated to my-skills as `fleet-skills/fleet-bead-pilot`; the README
  "Bundled repo skills" table is stale on that too.
- `orchestrator` conflicts with the new `fleet-orchestrator` skill from the
  my-skills `fleet-skills/` area: near-identical descriptions, both trigger on
  "orchestrate a fleet of worker agents with Herdr + Beads". `fleet-orchestrator`
  is the canonical successor (bead opencode-container-5s7).
- my-skills has `fleet-skills/fleet-orchestrator` and `fleet-skills/fleet-bead-pilot`
  but **no `herdr` skill** — the herdr skill is a `herdr --skill`-generated
  artifact (tool-owned, fetched at runtime, never vendored).
- `config/opencode.json` `skills` key only enables `meta-skill-library-admin` —
  no change needed.
- `setup_state_dirs` in `bin/opencode-container` copies the whole `config/` tree
  (`cp -a --update=none`), so no launcher logic change is required once the
  folder is gone; only stale host copies need one-time cleanup.

## Steps

### 1. Remove the folder from the repo

```
git rm -r config/skills/
```

Removes `orchestrator/` (superseded by `fleet-orchestrator`) and `herdr/`.

### 2. Repoint `bin/oc-dev herdr-skill` to host state

Since herdr is no longer vendored, the regen command targets host state instead
of the repo:

- `cmd_herdr_skill` (`bin/oc-dev`): write to
  `~/.opencode-container/config/skills/herdr/SKILL.md` instead of
  `$REPO_DIR/config/skills/herdr/SKILL.md`; `mkdir -p` the host path first.
- Update help text (usage header and subcommand list): "Regenerate the herdr
  skill in ~/.opencode-container/config/skills/".

Alternative considered: delete the subcommand and rely on manual
`herdr --skill`. Rejected — keeping it repointed preserves a one-command path to
(reg)generate the runtime herdr skill.

### 3. README updates

- Delete the "Bundled repo skills" section (the table listing `herdr`,
  `orchestrator`, and the stale `bead-pilot` row).
- Reword the `HERDR_VERSION` bump note: regenerate via `bin/oc-dev herdr-skill`
  into the host config dir (not the repo).
- Add one line noting fleet skills now come from my-skills `fleet-skills/` via
  `bin/opencode-container skills enable …`.

### 4. Host cleanup (one-time, after the repo change)

```
rm -rf ~/.opencode-container/config/skills/orchestrator
rm -rf ~/.opencode-container/config/skills/herdr   # if not regenerating
```

`init`/launch no longer re-seeds either once the repo folder is gone.
`fleet-orchestrator` remains installed at
`~/.opencode-container/.opencode/skills/fleet-orchestrator`.

### 5. Leave alone

- `docs/plan-*.md` — historical plans; do not rewrite.
- `Dockerfile` / `vendor/my-skills` — image-baked skill library is unaffected.

### 6. Beads + git

- Track this work with beads (parent + children per step).
- Commit: `chore: remove config/skills; fleet skills now sourced from my-skills`

## Validation

- `bin/opencode-container init` on a clean host state dir creates no
  `config/skills/` from the repo.
- `bin/oc-dev herdr-skill` writes `~/.opencode-container/config/skills/herdr/SKILL.md`.
- In-container skill scan lists `fleet-orchestrator` (and `herdr` after regen)
  with no `orchestrator` duplicate.
