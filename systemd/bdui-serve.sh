#!/bin/sh
# Host bdui (beads-ui) server wrapper for systemd (see systemd/bdui.service).
#
# Runs the beads-ui server in the foreground for systemd, then re-registers
# every workspace the opencode-container launcher recorded in
# ~/.opencode-container/bdui-workspaces.txt — API registrations are in-memory
# only and would otherwise be lost whenever the daemon restarts.
#
# Seeded to ~/.opencode-container/bdui-serve.sh by the launcher; edit the
# repo copy, not the seeded one.
set -u

HOST_ADDR="${HOST:-127.0.0.1}"
PORT_NUM="${PORT:-3000}"
BASE="http://127.0.0.1:${PORT_NUM}"
LIST="${BDUI_WORKSPACE_LIST:-$HOME/.opencode-container/bdui-workspaces.txt}"

# Locate the beads-ui server entry and a node binary without relying on the
# service environment's PATH (systemd user units do not source shell rc files,
# so nvm-installed node/npm prefixes must be found explicitly). Scan candidate
# npm roots first; the node binary next to the winning root is preferred.
entry="${BDUI_SERVER_ENTRY:-}"
node_bin=""
if [ -z "$entry" ]; then
    for root in "$HOME"/.nvm/versions/node/*/lib/node_modules \
                "$HOME/.npm-global/lib/node_modules" \
                /usr/local/lib/node_modules \
                /usr/lib/node_modules; do
        if [ -f "$root/beads-ui/server/index.js" ]; then
            entry="$root/beads-ui/server/index.js"
            node_cand="$(dirname "$root")/bin/node"
            [ -x "$node_cand" ] && node_bin="$node_cand"
            break
        fi
    done
fi
if [ -z "$entry" ]; then
    echo "bdui-serve: beads-ui server entry not found (npm i -g beads-ui, or set BDUI_SERVER_ENTRY)" >&2
    exit 1
fi
if [ -z "$node_bin" ]; then
    node_bin="$(command -v node 2>/dev/null || true)"
fi
if [ -z "$node_bin" ]; then
    echo "bdui-serve: node not found next to beads-ui install or on PATH" >&2
    exit 1
fi

HOST="$HOST_ADDR" PORT="$PORT_NUM" "$node_bin" "$entry" &
server_pid=$!

# Wait for the HTTP interface before re-registering workspaces.
i=0
while [ "$i" -lt 50 ]; do
    if curl -sf -m 1 "$BASE/api/workspaces" >/dev/null 2>&1; then
        break
    fi
    kill -0 "$server_pid" 2>/dev/null || { wait "$server_pid"; exit 1; }
    sleep 0.2
    i=$((i + 1))
done

if [ -f "$LIST" ]; then
    while IFS= read -r ws; do
        [ -n "$ws" ] && [ -d "$ws/.beads" ] || continue
        curl -sf -m 2 -X POST "$BASE/api/register-workspace" \
            -H 'content-type: application/json' \
            -d "{\"path\":\"$ws\",\"database\":\"$ws/.beads\"}" >/dev/null 2>&1
    done < "$LIST"
fi

wait "$server_pid"
