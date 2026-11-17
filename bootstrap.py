#!/usr/bin/env python3

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path


SECRETS_DIR = Path("/run/secrets")
WORKSPACE_DIR = Path("/workspace")
HERDR_SERVER_TIMEOUT_SECONDS = 15.0
SUPPORTED_SECRET_NAMES = {
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY",
    "CONTEXT7_API_KEY",
    "GOOGLE_APPLICATION_CREDENTIALS",
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
}


def env_var_name(secret_name: str) -> str:
    return secret_name.upper().replace("-", "_").replace(".", "_")


def load_secrets(secrets_dir: Path = SECRETS_DIR, environ: dict[str, str] | None = None) -> None:
    if not secrets_dir.is_dir():
        return

    environ = os.environ if environ is None else environ
    seen: dict[str, str] = {}  # normalized env var -> original filename
    for entry in secrets_dir.iterdir():
        if not entry.is_file():
            continue

        name = env_var_name(entry.name)
        if name not in SUPPORTED_SECRET_NAMES:
            continue
        if name in seen:
            raise RuntimeError(f"secret name collision: {seen[name]} and {entry.name} -> {name}")

        seen[name] = entry.name
        value = entry.read_text(encoding="utf-8").rstrip("\r\n")
        environ[name] = value


def beads_auto_init(
    environ: dict[str, str] | None = None,
    run=subprocess.run,
    which=shutil.which,
    workspace: Path = WORKSPACE_DIR,
) -> None:
    """Run `bd init` once per workspace when opted in via OPENCODE_CONTAINER_BEADS=1.

    `bd init` is idempotent, but the .beads/ existence check keeps repeat
    launches free and avoids rewriting project AGENTS.md on every run.
    Failures warn but never block OpenCode.
    """
    environ = os.environ if environ is None else environ
    if environ.get("OPENCODE_CONTAINER_BEADS") != "1":
        return
    if not workspace.is_dir() or (workspace / ".beads").exists():
        return
    if which("bd") is None:
        print("warning: OPENCODE_CONTAINER_BEADS=1 but bd is not on PATH", file=sys.stderr)
        return
    result = run(["bd", "init", "--quiet"], cwd=str(workspace), check=False)
    if getattr(result, "returncode", 0) != 0:
        print(f"warning: bd init exited with status {result.returncode}", file=sys.stderr)


# Subcommands that accept --standalone/--server (server-backed clients).
# Others (auth, session, pair, acp, mcp, plugin, ...) reject the flag.
STANDALONE_CAPABLE_COMMANDS = {"run", "mini", "stats", "api", "reload", "models"}


def standalone_args(args: list[str]) -> list[str]:
    """Default OpenCode to a private server instead of the shared background service.

    All containers share the state volume, so concurrent instances would fight
    over the single service.json registration: each server sees the other's
    serviceID and shuts down ("managed service registration replaced"), and
    herdr respawns the crashing CLI in a restart loop. A private server per
    container avoids the shared registration entirely. Skipped when the user
    already chose --standalone or --server, or when the subcommand rejects
    the flag.
    """
    if "--standalone" in args or "--server" in args:
        return args
    if args and not args[0].startswith("-") and args[0] not in STANDALONE_CAPABLE_COMMANDS:
        return args
    return ["--standalone", *args]


def start_herdr(
    args: list[str],
    environ: dict[str, str] | None = None,
    run=subprocess.run,
    popen=subprocess.Popen,
    sleep=time.sleep,
    which=shutil.which,
    execvp=os.execvp,
    workspace: Path = WORKSPACE_DIR,
    get_terminal_size=os.get_terminal_size,
) -> bool:
    """Start OpenCode inside a herdr pane and attach the client.

    Enabled with OPENCODE_CONTAINER_HERDR=1. Skipped when already inside a
    herdr pane (HERDR_ENV=1). Any startup failure falls back to running
    OpenCode directly.
    """
    environ = os.environ if environ is None else environ
    if environ.get("OPENCODE_CONTAINER_HERDR") != "1" or environ.get("HERDR_ENV") == "1":
        return False
    if which("herdr") is None:
        print("warning: OPENCODE_CONTAINER_HERDR=1 but herdr is not on PATH", file=sys.stderr)
        return False
    try:
        size = get_terminal_size()
        if size.columns < 2 or size.lines < 2:
            return False
    except OSError:
        return False

    cwd = str(workspace) if workspace.is_dir() else str(Path.home())
    try:
        # Keep herdr state (session.json, sockets, snapshots) on the container's
        # ephemeral /tmp instead of the persisted volume: each container run gets
        # a fresh server, so restored workspaces would only be zombies of dead
        # containers. The user's config.toml is copied forward so keybindings
        # survive. Panes still reach the server via injected HERDR_SOCKET_PATH.
        herdr_home = Path(environ.get("TMPDIR", "/tmp")) / "herdr-config"
        (herdr_home / "herdr").mkdir(parents=True, exist_ok=True)
        persisted_config = (
            Path(environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))
            / "herdr"
            / "config.toml"
        )
        if persisted_config.is_file():
            shutil.copy(persisted_config, herdr_home / "herdr" / "config.toml")
        environ["XDG_CONFIG_HOME"] = str(herdr_home)

        # The herdr CLI never auto-starts the server; run it headless in a
        # detached session so it outlives this bootstrap process via exec.
        server_log = Path(environ.get("TMPDIR", "/tmp")) / "herdr-server.log"
        popen(
            ["herdr", "server"],
            stdout=subprocess.DEVNULL,
            stderr=open(server_log, "wb"),
            start_new_session=True,
        )
        deadline = time.monotonic() + HERDR_SERVER_TIMEOUT_SECONDS
        while True:
            # `herdr status server` exits 0 even when the server is down;
            # only its stdout is authoritative.
            status = run(["herdr", "status", "server"], capture_output=True, text=True, check=False)
            if "status: running" in getattr(status, "stdout", ""):
                break
            if time.monotonic() > deadline:
                raise RuntimeError(f"herdr server did not become ready (see {server_log})")
            sleep(0.2)
        created = run(
            ["herdr", "workspace", "create", "--cwd", cwd, "--label", "workspace", "--no-focus"],
            capture_output=True,
            text=True,
            check=True,
        )
        pane_id = json.loads(created.stdout)["result"]["root_pane"]["pane_id"]
        start = ["herdr", "agent", "start", "main", "--kind", "opencode", "--pane", pane_id]
        if args:
            start += ["--", *args]
        run(start, check=True)
    except (subprocess.CalledProcessError, KeyError, RuntimeError, ValueError) as error:
        print(f"warning: herdr startup failed ({error}); starting opencode directly", file=sys.stderr)
        return False

    execvp("herdr", ["herdr"])
    return True


def start_bdui(
    environ: dict[str, str] | None = None,
    run=subprocess.run,
    which=shutil.which,
    workspace: Path = WORKSPACE_DIR,
) -> None:
    """Start the beads-ui web server when opted in via OPENCODE_CONTAINER_BDUI=1.

    bdui daemonizes and keeps its pid/log in the container's ephemeral /tmp
    (XDG_RUNTIME_DIR is unset here), so each container run gets a fresh server
    and the launcher only has to publish the port. Failures warn but never
    block OpenCode.
    """
    environ = os.environ if environ is None else environ
    if environ.get("OPENCODE_CONTAINER_BDUI") != "1":
        return
    if which("bdui") is None:
        print("warning: OPENCODE_CONTAINER_BDUI=1 but bdui is not on PATH", file=sys.stderr)
        return
    cwd = str(workspace) if workspace.is_dir() else str(Path.home())
    result = run(
        ["bdui", "start", "--host", "0.0.0.0"],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
    )
    if getattr(result, "returncode", 0) != 0:
        detail = (getattr(result, "stderr", "") or getattr(result, "stdout", "") or "").strip()
        print(f"warning: bdui start failed (status {result.returncode}): {detail[:200]}",
              file=sys.stderr)
    else:
        print("bdui: beads-ui server listening on 0.0.0.0:3000")


def bootstrap(args: list[str], execvp=os.execvp, environ: dict[str, str] | None = None) -> None:
    environ = os.environ if environ is None else environ
    load_secrets()
    beads_auto_init(environ)
    start_bdui(environ)
    args = standalone_args(args)
    if start_herdr(args, environ, execvp=execvp):
        return
    execvp("opencode", ["opencode", *args])


def main() -> None:
    bootstrap(sys.argv[1:])


if __name__ == "__main__":
    main()
