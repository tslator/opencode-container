#!/usr/bin/env bash
# E2E smoke for the skills-in-image flow (bead opencode-container-cva.6).
#
# From a clean state dir: seed the default config (global layer = general
# skill), enable a language skill in a test project via the launcher
# passthrough, then start `opencode serve` inside the image and verify both
# layers are advertised (union). Asserts no network/host paths are involved.
#
# Requires the built image (make build) and, for podman, save/load to make
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
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
PROJ="$TEST_DIR/proj"
mkdir -p "$FAKE_HOME/.opencode-container/config" "$PROJ"

# Make the image visible under the throwaway HOME (podman rootless storage
# lives under $HOME; docker's daemon storage is HOME-independent).
if [ "$ENGINE" = podman ]; then
    "$ENGINE" save "$IMAGE" -o "$TEST_DIR/img.tar"
    HOME="$FAKE_HOME" "$ENGINE" load -i "$TEST_DIR/img.tar" >/dev/null
    rm "$TEST_DIR/img.tar"
fi

# --- Scenario B (global): default config seeds the general skill -----------
cp "$ROOT_DIR/config/opencode.json" "$FAKE_HOME/.opencode-container/config/opencode.json"
grep -F -- '/opt/skills/meta-skills/meta-skill-library-admin' \
    "$FAKE_HOME/.opencode-container/config/opencode.json"

# --- Scenario C (project): launcher passthrough enables the language layer --
HOME="$FAKE_HOME" "$ROOT_DIR/bin/opencode-container" skills enable --project "$PROJ"
grep -F -- '/opt/my-skills/python-skills' "$PROJ/opencode.json"

# No network or host-path leakage: entries are image paths only.
if grep -Eq 'http://|https://|'"$TEST_DIR" "$PROJ/opencode.json"; then
    echo "FAIL: project config contains network or host paths" >&2
    cat "$PROJ/opencode.json" >&2
    exit 1
fi

# --- Union check: both layers advertised by the in-container server --------
cat > "$TEST_DIR/driver.py" <<'PYEOF'
import base64, json, os, socket, subprocess, sys, time, urllib.request

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
    ids, deadline = {}, time.time() + 60
    while time.time() < deadline:
        req = urllib.request.Request(f"http://127.0.0.1:{port}/api/skill", headers=headers)
        ids = {d["id"]: d for d in json.loads(urllib.request.urlopen(req, timeout=60).read())["data"]}
        if all(w in ids for w in want):
            break
        time.sleep(1)
    missing = [w for w in want if w not in ids]
    empty = [w for w in want if w in ids and not ids[w].get("description")]
    ok = not missing and not empty
    print(("PASS" if ok else "FAIL") + f": union of global+project skills advertised "
          f"(have={sorted(ids)}, missing={missing}, empty_desc={empty})")
    sys.exit(0 if ok else 1)
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
    "$IMAGE" /driver.py meta-skill-library-admin python-debugging

echo "skills e2e smoke passed"
