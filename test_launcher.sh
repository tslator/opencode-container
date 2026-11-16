#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/home" "$TEST_DIR/workspace" "$TEST_DIR/repo/config"
cat > "$TEST_DIR/bin/podman" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ARGS_FILE"
EOF
chmod +x "$TEST_DIR/bin/podman"

ARGS_FILE="$TEST_DIR/args" \
HOME="$TEST_DIR/home" \
PATH="$TEST_DIR/bin:$PATH" \
OPENCODE_CONTAINER_REPO="$TEST_DIR/repo" \
OPENCODE_WORKSPACE="$TEST_DIR/workspace" \
  "$ROOT_DIR/bin/opencode-container" -w -e

grep -F "$TEST_DIR/home/.opencode-container:/app:rw,Z" "$TEST_DIR/args"
grep -F "$TEST_DIR/home/.opencode-container/config:/app/.config/opencode:rw,Z" "$TEST_DIR/args"
grep -F "$TEST_DIR/home/.opencode-container/secrets:/run/secrets:ro,Z" "$TEST_DIR/args"
grep -F "$TEST_DIR/workspace:/workspace:rw,Z" "$TEST_DIR/args"
# per-project data dir mounted over /app/.local/share (sessions isolated per workspace)
grep -E '^[^ ]*/home/.opencode-container/projects/workspace-[0-9a-f]+:/app/.local/share:rw,Z$' "$TEST_DIR/args"
[ -d "$TEST_DIR/home/.opencode-container/projects" ]

grep -Fx -- 'OPENCODE_ENABLE_EXA=1' "$TEST_DIR/args"
grep -Fx -- 'OPENCODE_EXPERIMENTAL=1' "$TEST_DIR/args"
grep -Fx -- 'OPENCODE_ENABLE_EXPERIMENTAL_MODELS=1' "$TEST_DIR/args"
[ "$(grep -c -- '^--env$' "$TEST_DIR/args")" -eq 3 ]

# herdr/beads opt-ins plus host-tools dev override
mkdir -p "$TEST_DIR/home/.opencode-container/bin"
ARGS_FILE="$TEST_DIR/args2" \
HOME="$TEST_DIR/home" \
PATH="$TEST_DIR/bin:$PATH" \
OPENCODE_CONTAINER_REPO="$TEST_DIR/repo" \
OPENCODE_WORKSPACE="$TEST_DIR/workspace" \
  "$ROOT_DIR/bin/opencode-container" --herdr --beads

grep -Fx -- 'OPENCODE_CONTAINER_HERDR=1' "$TEST_DIR/args2"
grep -Fx -- 'OPENCODE_CONTAINER_BEADS=1' "$TEST_DIR/args2"
grep -F "$TEST_DIR/home/.opencode-container/bin:/opt/host-tools:ro,Z" "$TEST_DIR/args2"
grep -Fx -- 'PATH=/opt/host-tools:/usr/local/bin:/usr/bin' "$TEST_DIR/args2"

# host environment opt-in works without flags
ARGS_FILE="$TEST_DIR/args3" \
HOME="$TEST_DIR/home" \
PATH="$TEST_DIR/bin:$PATH" \
OPENCODE_CONTAINER_REPO="$TEST_DIR/repo" \
OPENCODE_WORKSPACE="$TEST_DIR/workspace" \
OPENCODE_CONTAINER_HERDR=1 \
  "$ROOT_DIR/bin/opencode-container"

grep -Fx -- 'OPENCODE_CONTAINER_HERDR=1' "$TEST_DIR/args3"
grep -Fx -- 'OPENCODE_CONTAINER_BEADS=1' "$TEST_DIR/args3" && exit 1

# -h/--help prints wrapper usage without invoking the engine or creating state dirs
ARGS_FILE="$TEST_DIR/args_help" \
HOME="$TEST_DIR/home2" \
PATH="$TEST_DIR/bin:$PATH" \
  "$ROOT_DIR/bin/opencode-container" --help > "$TEST_DIR/usage"
grep -F -- '--opencode-help' "$TEST_DIR/usage"
grep -F -- '--websearch' "$TEST_DIR/usage"
[ ! -e "$TEST_DIR/args_help" ]
[ ! -e "$TEST_DIR/home2/.opencode-container" ]

# --opencode-help runs the container with --help only (no state mounts)
ARGS_FILE="$TEST_DIR/args4" \
HOME="$TEST_DIR/home" \
PATH="$TEST_DIR/bin:$PATH" \
OPENCODE_CONTAINER_REPO="$TEST_DIR/repo" \
OPENCODE_WORKSPACE="$TEST_DIR/workspace" \
  "$ROOT_DIR/bin/opencode-container" --opencode-help
[ "$(tail -n1 "$TEST_DIR/args4")" = "--help" ]
grep -F -- '/workspace:rw,Z' "$TEST_DIR/args4" && exit 1
grep -F -- '--workdir' "$TEST_DIR/args4" && exit 1

echo "launcher mount and environment checks passed"
