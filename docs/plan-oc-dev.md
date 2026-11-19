# Plan: replace Makefile with `bin/oc-dev` CLI

## Motivation

The `Makefile` has become a CLI application without CLI benefits (no `make help`,
no per-target docs). Most of its logic is imperative shell code written in Make's
worst dialect (`$(if $(or ...))` nesting, parse-time `$(error)`, `$(MAKE)`
recursion), and engine detection + proxy forwarding are duplicated between the
Makefile (lines 3–23) and `bin/opencode-container` (lines 157–175, 374–399).

Alternatives considered:

- **just** — same category as make (task runner, minimal help); nicer syntax but
  doesn't fix the identity crisis; new host dependency.
- **docker/podman compose** — only ~15% of the Makefile (`shell` target) is
  compose-appropriate; build/tag/prune/skills are host-side task logic. Adds a
  heavier, engine-fragile dependency (podman needs podman-compose or the socket).
- **bash `bin/oc-dev`** — chosen. Matches existing repo idiom (`bin/` scripts,
  `test_*.sh`), zero new dependencies, real `--help`, kills the duplication.

Makefile stays unchanged and in place until `oc-dev` is complete and validated.

## Phase 1 — shared library: `bin/lib/common.sh`

Sourced by both `bin/opencode-container` and `bin/oc-dev`:

- `detect_engine()` — honors `$CONTAINER_ENGINE`, podman-first autodetect, dies
  with the launcher's existing error message.
- `init_proxy()` — sets `EFF_HTTP_PROXY` / `EFF_HTTPS_PROXY` / `EFF_NO_PROXY`
  from upper- or lower-case env, calls `reject_proxy_credentials`.
- `proxy_env_args()` — emits `-e K=V` pairs (both cases) as an array for `run`.
- `proxy_build_args()` — emits `--build-arg` pairs for `build`.
- `die()`

Refactor `bin/opencode-container` to source it (behavior-identical).
Regression gate: `test_launcher.sh`.

## Phase 2 — `bin/oc-dev` subcommands

Usage heredoc + case dispatch, `set -euo pipefail`, launcher style:

| Command | Behavior (vs Makefile) |
| --- | --- |
| `build [VERSION]` | engine, `id -u/-g`, proxy build-args, `-t opencode-container[:VERSION]`; runs `ensure_vendor` first |
| `build-builder-tools` | `--target builder-tools -t :builder-tools` |
| `build-latest` | curl+jq npm dist-tag → call `cmd_build "$v"` + `cmd_tag_latest "$v"` directly (no recursion) |
| `tag-latest VERSION` | positional required, `die` if missing |
| `shell` | mkdir dirs + the `run --rm -it` block verbatim; `$(pwd)` → script repo root |
| `skills` | `ensure_vendor`: clone at sha pin, `--force` to re-clone; error if sha empty or `gh` missing |
| `skills-bump` | `gh api` → write `vendor/my-skills.sha` |
| `herdr-skill` | `run --rm --entrypoint herdr ... > config/skills/herdr/SKILL.md` |
| `clean` / `prune-cache` | verbatim |
| `--help`, `cmd --help` | top-level command list + per-command help |

Vendor freshness: `ensure_vendor` clones when `vendor/my-skills` is missing or
older than `vendor/my-skills.sha` (stat mtime compare) — replicates the Make
file-target dependency explicitly.

## Phase 3 — validation (Makefile untouched throughout)

- `test_launcher.sh`, `test_skills_e2e.sh`, `test_bootstrap.py` pass after Phase 1.
- Equivalence: `oc-dev build` vs `make build` produce identical tags/build args
  (inspect with `bash -x` or an engine shim); `oc-dev shell` reaches bash;
  proxy matrix (unset / set / credentials-rejected) matches Makefile `$(error)`
  behavior.
- `shellcheck bin/oc-dev bin/lib/common.sh`.

## Phase 4 — cutover (separate change, after sign-off)

Update all `make` references: `README.md` (~15), `AGENTS.md`, `CLAUDE.md`,
`Dockerfile:252` comment, `docs/plan-skills-in-image.md`, `test_skills_e2e.sh:9`.
Delete `Makefile` in its own `chore:` commit.

## Beads

Tracked as one parent with four child tasks (phases 1–4).
