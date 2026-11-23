#!/usr/bin/env bash
# E2E smoke for the vendored-commands flow (my-skills commands/ → /opt/my-skills/commands).
#
# From a clean state dir, run bootstrap's link step in-container, start
# `opencode serve`, and verify the library command is advertised under its
# /my-skills-commands/ namespace. Also asserts a host-defined global command
# coexists with the linked directory (no clobber, no merge).
#
# Requires the built image (bin/oc-dev build) and, for podman, save/load to make
# the image visible in the throwaway HOME's rootless storage.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${IMAGE:-opencode-container:latest}"
ENGINE="${CONTAINER_ENGINE:-}"
if [ -z "$ENGINE" ]; then
    if command -v podman >/dev/null 2>&1; then ENGINE=podman
    elif command -v docker >/dev/null 2>&1; then ENGINE=docker
    else echo "error: no container engine found" >&2; exit 1; fi
fi

TEST_DIR="$(mktemp -d)"
FAKE_HOME="$TEST_DIR/home"
cleanup() {
    # podman's rootless storage under the throwaway HOME holds mapped-root
    # overlay dirs that plain rm cannot remove; reset the storage first.
    if [ "${ENGINE:-}" = podman ] && [ -d "$FAKE_HOME/.local/share/containers" ]; then
        HOME="$FAKE_HOME" "$ENGINE" system reset --force >/dev/null 2>&1 || true
    fi
    chmod -R u+rwX "$TEST_DIR" 2>/dev/null || true
    # mapped-root mount-point dirs survive chmod+rm; try the userns remap too.
    if [ "${ENGINE:-}" = podman ]; then
        "$ENGINE" unshare rm -rf "$TEST_DIR" 2>/dev/null || true
    fi
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
PROJ="$TEST_DIR/proj"
# Pre-create the engine's mount targets as the host user; otherwise podman
# creates /app/.config/opencode as mapped-root and cleanup cannot remove it.
mkdir -p "$FAKE_HOME/.opencode-container/config" "$FAKE_HOME/.opencode-container/.config/opencode" "$PROJ"

# Make the image visible under the throwaway HOME (podman rootless storage
# lives under $HOME; docker's daemon storage is HOME-independent).
if [ "$ENGINE" = podman ]; then
    "$ENGINE" save "$IMAGE" -o "$TEST_DIR/img.tar"
    HOME="$FAKE_HOME" "$ENGINE" load -i "$TEST_DIR/img.tar" >/dev/null
    rm "$TEST_DIR/img.tar"
fi

# Host-defined global command alongside the vendor link (must coexist).
mkdir -p "$FAKE_HOME/.opencode-container/config/commands"
printf 'Plain host command.\n' > "$FAKE_HOME/.opencode-container/config/commands/hostcmd.md"

cat > "$TEST_DIR/driver.py" <<'PYEOF'
import base64, json, os, socket, subprocess, sys, time, urllib.request
sys.path.insert(0, "/usr/local/bin")
import bootstrap
bootstrap.link_vendor_commands()
want = sys.argv[1:]
s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
proc = subprocess.Popen(["opencode", "serve", "--hostname", "127.0.0.1", "--port", str(port)],
                        cwd="/workspace", stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT, text=True)
os.set_blocking(proc.stdout.fileno(), False)
buf, pw, deadline = "", None, time.time() + 90
while time.time() < deadline:
    buf += proc.stdout.read(4096) or ""
    if "password " in buf:
        pw = buf.split("password ")[1].split("\n")[0].strip(); break
    if proc.poll() is not None:
        print("serve died:\n" + buf); sys.exit(1)
    time.sleep(0.2)
if not pw:
    proc.terminate(); print("no password"); sys.exit(1)
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + pw).encode()).decode()}
try:
    names, deadline = set(), time.time() + 60
    while time.time() < deadline:
        req = urllib.request.Request(f"http://127.0.0.1:{port}/api/command", headers=headers)
        names = {d["name"] for d in json.loads(urllib.request.urlopen(req, timeout=60).read())["data"]}
        if all(w in names for w in want):
            break
        time.sleep(1)
    missing = [w for w in want if w not in names]
    print(("PASS" if not missing else "FAIL") + f": vendor+host commands advertised "
          f"(have={sorted(names)}, missing={missing})")
    sys.exit(0 if not missing else 1)
finally:
    proc.terminate(); proc.wait(timeout=10)
PYEOF

USERNS=()
[ "$ENGINE" = podman ] && USERNS=(--userns=keep-id)
"$ENGINE" run --rm -i "${USERNS[@]}" --workdir /workspace --entrypoint /usr/bin/python3 \
    -v "$FAKE_HOME/.opencode-container:/app:rw,Z" \
    -v "$FAKE_HOME/.opencode-container/config:/app/.config/opencode:rw,Z" \
    -v "$PROJ:/workspace:rw,Z" \
    -v "$TEST_DIR/driver.py:/driver.py:ro,Z" \
    "$IMAGE" /driver.py my-skills-commands/commit hostcmd

# The link must land on the host volume under the namespaced name.
test -L "$FAKE_HOME/.opencode-container/config/commands/my-skills-commands"

echo "commands e2e smoke passed"
