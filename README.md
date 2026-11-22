# OpenCode Container

Run the [OpenCode](https://opencode.ai) CLI inside a locked-down container (Docker or Podman): read-only root filesystem, all Linux capabilities dropped, privilege escalation blocked, and API keys loaded from files instead of the command line. Your current directory is mounted as the only writable workspace.

Run it with the canonical launcher:

- **`bin/opencode-container`** (recommended) — persists everything to `~/.opencode-container/` and works from any directory.

<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="OpenCode Container hero: the real container run flags the wrapper applies — read-only filesystem, all capabilities dropped, no-new-privileges, 4 GB memory and 4 CPU limits, secrets mounted read-only, current directory as the only writable workspace">
</p>

## Getting Started

### Prerequisites

- [Podman](https://podman.io/docs/installation) or [Docker](https://docs.docker.com/get-docker/) installed on your machine.
- Bash (the `bin/oc-dev` helper; no task runner to install)
- `curl` and `jq` (required for `bin/oc-dev build-latest`)

### Quick Start

```bash
# Build the image
./bin/oc-dev build

# Create ~/.opencode-container/ and seed default config (optional;
# normal runs self-create it, init just makes the first step explicit)
bin/opencode-container init

# Add a provider API key (one-time)
echo "your-api-key" > ~/.opencode-container/secrets/anthropic_api_key
chmod 600 ~/.opencode-container/secrets/*

# Run with the wrapper script (recommended)
bin/opencode-container
```

The OpenCode TUI starts inside the container. Your current directory is mounted at `/workspace`; sessions, cache, and settings persist in `~/.opencode-container/`. See [Secrets Management](#secrets-management) for other providers.

### Using the Wrapper Script

The `bin/opencode-container` script is the recommended way to run OpenCode Container. It:

- Picks an engine: `$CONTAINER_ENGINE` if set, else `podman`, else `docker`
- Persists all data to `~/.opencode-container/` (cache, settings); session history and TUI state are isolated per workspace directory (stored under `~/.opencode-container/projects/<name>-<hash>/`)
- Reads secrets from `~/.opencode-container/secrets/`
- Uses the current directory as the workspace
- Works from any directory once added to your PATH

Run `bin/opencode-container init` once to create `~/.opencode-container/` and seed the default config up front; it is idempotent and never overwrites your edits (normal launches also self-create the state dirs, so init is convenience, not a requirement).

#### Options

| Flag | Default | Description |
|------|---------|-------------|
| `-w`, `--websearch` | off | Enable Exa web search |
| `-e`, `--experimental` | off | Enable experimental features and models |
| `-u`, `--update-config` | off | Overwrite `~/.opencode-container/config/` with the repo's `config/` |
| `--herdr` | off | Start OpenCode inside a [herdr](https://herdr.dev) pane (terminal multiplexer for agents) |
| `--beads` | off | Run `bd init` automatically on first launch in a workspace without `.beads/` |
| `--bdui` | off | Start the [beads-ui](https://github.com/mantoni/beads-ui) web server in the container and publish a per-workspace `127.0.0.1` port (prints the URL); see also the [host bdui service](#host-bdui-service-with-auto-registration) |
| `--bdui-port` | hashed | Override the host port used by `--bdui` |
| `--memory` | `4g` | Container memory limit |
| `--cpus` | `4` | Container CPU count |
| `--host-access` | off | Add the engine's host alias (`host.docker.internal` for Docker, `host.containers.internal` for Podman) so the container can reach host services (see [Accessing Host Services](#accessing-host-services)) |
| `--opencode-help` | — | Show OpenCode's own CLI options (runs the container with `--help`) |
| `-h`, `--help` | — | Show `opencode-container`'s own options |

Everything else is passed through to the OpenCode CLI — including short flags like `-m`/`--model`, `-c`/`--continue`, and `-s`/`--session`, as well as subcommands. Run `opencode-container --opencode-help` to see them all.

#### Adding to PATH

Adjust the path below to where you cloned this repository.

**Bash** — add to `~/.bashrc`, then run `source ~/.bashrc`:

```bash
export PATH="$HOME/git/opencode-container/bin:$PATH"
```

**Fish**:

```fish
fish_add_path $HOME/git/opencode-container/bin
```

#### Usage

Once added to your PATH, you can run from any directory:

```bash
# Run in the current directory
opencode-container

# Continue a session (passed through to OpenCode)
opencode-container -s ses_2d068fdfaffefxNTts5doK0upT

# Pass subcommands through (cwd is the mounted workspace)
opencode-container -e -w auth logout
opencode-container run "fix the login bug"

# Override the workspace directory
OPENCODE_WORKSPACE=/path/to/project opencode-container

# Raise resource limits for a heavy session
opencode-container --memory 8g --cpus 8

# Manage the baked skill library (see Skills Library below)
opencode-container skills enable --global
```

### Bundled agent tools: beads and herdr

The image ships pinned release binaries for [beads](https://github.com/gastownhall/beads) (`bd`, `beads`) and [herdr](https://herdr.dev) (`herdr`). Both are opt-in per launch:

- **`--herdr`** (or `OPENCODE_CONTAINER_HERDR=1`): bootstrap starts a headless herdr server, creates a workspace for `/workspace`, launches OpenCode in a pane, and attaches the herdr client. From inside the session the agent can control panes via the `herdr` skill (generated by `bin/oc-dev herdr-skill`). If any step fails (including no usable terminal), OpenCode starts directly instead.
- **`--beads`** (or `OPENCODE_CONTAINER_BEADS=1`): on first launch in a workspace without `.beads/`, bootstrap runs `bd init` once, which creates `.beads/`, project `AGENTS.md`/`CLAUDE.md` integration, and the beads skill. Repeat launches skip it.

To iterate on either binary without rebuilding the image, drop a replacement in `~/.opencode-container/bin/` (e.g. `~/.opencode-container/bin/herdr`); it is mounted read-only at `/opt/host-tools` and takes PATH precedence.

After bumping `HERDR_VERSION` in the Dockerfile, regenerate the herdr skill into the host config: `bin/oc-dev herdr-skill` (writes `~/.opencode-container/config/skills/herdr/SKILL.md`).

### Bundled web UI: bdui (beads-ui)

The image ships the pinned [beads-ui](https://github.com/mantoni/beads-ui) npm package (`bdui`, a web UI for `bd`). It is opt-in per launch:

- **`--bdui`** (or `OPENCODE_CONTAINER_BDUI=1`): bootstrap starts `bdui start --host 0.0.0.0` inside the container (which auto-registers the workspace's `.beads/` database), and the launcher publishes it on a host port bound to `127.0.0.1` only, then prints the exact URL, e.g. `bdui: http://127.0.0.1:3289/`. Open it in your host browser. If `bdui` fails to start, OpenCode still launches normally with only a warning.

**Multi-project:** each container has its own network namespace and runtime dir, so N project folders = N containers, each running its own bdui. The default host port is derived from the workspace path (`3000 + cksum(path) % 1000`), so a given project always gets the same URL and concurrent projects almost never collide — but the hash can collide (birthday-paradox odds rise around ~40 concurrent projects in the 1000-port space). On collision the container fails to start the port mapping; fix with `--bdui-port N` (or `OPENCODE_CONTAINER_BDUI_PORT`) to pick a free port.

**Single-host alternative:** bdui natively supports multiple workspaces (REST `POST /api/register-workspace`, in-UI workspace picker). If you prefer one bookmarked URL for all projects, run `npm i -g beads-ui && bdui start` on the host and register each project folder — e.g. `curl -X POST http://127.0.0.1:3000/api/register-workspace -H 'content-type: application/json' -d '{"path":"/path/to/project","database":"/path/to/project/.beads"}'` — the host `bd` reads each repo's beads DB directly, so no container or port juggling is needed. Use `--bdui` per container instead when the beads DB must stay container-private.

#### Host bdui service with auto-registration

For a permanent single-host UI, the repo ships a systemd **user** service that runs one host bdui server and keeps every bead workspace in its dropdown automatically:

- `systemd/bdui.service` — `Type=simple` unit (foreground node server on `127.0.0.1:3000`)
- `systemd/bdui-serve.sh` — wrapper that locates node + beads-ui (nvm-aware), starts the server, then re-registers every workspace listed in `~/.opencode-container/bdui-workspaces.txt` (API registrations are in-memory only and would otherwise be lost on every service restart)

Install (the launcher seeds `~/.opencode-container/bdui-serve.sh` from the repo automatically on every run):

```bash
opencode-container bdui-service install    # or the manual steps below
opencode-container bdui-service status     # active state + registered workspaces
opencode-container bdui-service uninstall  # disable + remove the unit
```

Manual fallback (e.g. if you don't run the launcher from the repo):

```bash
mkdir -p ~/.config/systemd/user
cp systemd/bdui.service ~/.config/systemd/user/bdui.service
cp systemd/bdui-serve.sh ~/.opencode-container/bdui-serve.sh
systemctl --user daemon-reload
systemctl --user enable --now bdui
```

Then just use `opencode-container` normally: whenever the workspace has a `.beads/` directory and the host service answers on `http://127.0.0.1:3000`, the launcher POSTs `register-workspace` with the host paths and appends the workspace to `bdui-workspaces.txt`, so it appears in the dropdown at <http://127.0.0.1:3000> — and reappears after `systemctl --user restart bdui` or a reboot. The check is a 1-second probe; with no service running the launcher is silent and unaffected. Set `OPENCODE_CONTAINER_BDUI_HOST_URL` to point at a different URL, and skip auto-registration entirely by passing `--bdui` (container-private server takes precedence).

### Bundled terminal tools: lazygit and ttt

The image also ships pinned release binaries for [lazygit](https://github.com/jesseduffield/lazygit) (git TUI client) and [ttt](https://tttedit.dev) (terminal text editor/IDE). Unlike beads and herdr, these need no launcher flags — they are always on `PATH` and run in any interactive TTY inside the container. Their runtime dependencies (`git`, `rg`) are already bundled. Configs are read from `$HOME/.config` (e.g. `/app/.config/lazygit`, `/app/.config/ttt`), which is backed by `~/.opencode-container/.config/` on the host and therefore persists between launches.

To iterate on either binary without rebuilding the image, drop a replacement in `~/.opencode-container/bin/` (e.g. `~/.opencode-container/bin/lazygit`); it is mounted read-only at `/opt/host-tools` and takes PATH precedence.

## Security Features

The container applies several independent layers of restriction:

- **Distroless runtime:** no package manager and no compiler; a minimal POSIX shell (`/bin/sh`) is present because OpenCode's shell tool and npm require one
- **Read-only root filesystem:** only `/tmp` (tmpfs) and mounted volumes are writable
- **Dropped capabilities:** `--cap-drop=ALL` removes all Linux capabilities (principle of least privilege)
- **No privilege escalation:** `--security-opt=no-new-privileges` blocks setuid/setgid exploits
- **Non-root user:** runs as UID 1000 (configurable at build time)
- **Resource limits:** the wrapper defaults to 4 GB memory / 4 CPUs
- **File-based secrets:** keys mounted read-only at `/run/secrets` — never baked into the image or passed on the command line
- **SELinux-compatible bind mounts:** host mounts use the private `:Z` label so Fedora's SELinux policy permits the image to access them

## Secrets Management

API keys live as plain files on the host and are loaded at container start — they are never baked into the image or passed on the command line.

### How It Works

1. Set up one file per key as shown in [Quick Start](#quick-start) (`~/.opencode-container/secrets/`, directory `700`, files `600`).
2. The runtime bootstrap (`bootstrap.py`) reads only supported secret filenames
   from `/run/secrets` and exports them as environment variables.
   Unsupported files are ignored. Filenames are uppercased; dashes and dots
   become underscores.
3. The table below lists the supported provider secrets. Other filenames do not
   create environment variables.

### Commonly Used Secrets

| Filename | Environment Variable | Provider |
|----------|---------------------|----------|
| `anthropic_api_key` | `ANTHROPIC_API_KEY` | Anthropic |
| `openai_api_key` | `OPENAI_API_KEY` | OpenAI |
| `context7_api_key` | `CONTEXT7_API_KEY` | Context7 MCP |
| `google_application_credentials` | `GOOGLE_APPLICATION_CREDENTIALS` | Vertex AI |
| `aws_access_key_id` | `AWS_ACCESS_KEY_ID` | AWS Bedrock |
| `aws_secret_access_key` | `AWS_SECRET_ACCESS_KEY` | AWS Bedrock |

**Note:** the launcher mounts these files read-only at `/run/secrets`; the
bootstrap loads supported secrets directly into the OpenCode process
environment. OpenCode commands and plugins can therefore access configured
provider secrets. Do not place unrelated files in the secrets directory.

On SELinux-enabled hosts such as Fedora, the launcher applies the private
`:Z` label to its bind mounts automatically. This relabels the mounted paths
for container use while leaving their normal permissions unchanged.

## Data Persistence & Configuration

When using the wrapper script (`bin/opencode-container`):

| Data | Location | Description |
|------|----------|-------------|
| **Home Directory** | `~/.opencode-container/` | OpenCode cache, plugins, settings |
| **Sessions** | `~/.opencode-container/projects/<name>-<hash>/share/` | Per-workspace session store (keyed by workspace path) |
| **TUI state** | `~/.opencode-container/projects/<name>-<hash>/state/` | Per-workspace tabs, prompt history, model selection |
| **Plan files** | `~/.opencode-container/projects/<name>-<hash>/plans/` | Per-workspace plan-mode documents (mounted at `/app/.claude/plans`) |
| **Secrets** | `~/.opencode-container/secrets/` | API keys and credentials |
| **Config** | `./config/` (this repo) | OpenCode configuration, MCP servers, global skill enablement |
| **Workspace** | Current directory | Your project files |

Because every workspace mounts at `/workspace` inside the container, OpenCode would otherwise merge all projects' sessions into one list and restore another workspace's session tabs (its TUI state keys tabs by cwd). The launcher therefore mounts a dedicated session store at `/app/.local/share`, TUI state at `/app/.local/state`, and plan-mode files at `/app/.claude/plans` (OpenCode's default plan directory) per workspace path. Older versions kept a single shared store at `~/.opencode-container/.local/share/opencode/`; that history is no longer shown and can be deleted once you no longer need it.

## Skills Library

The image bakes the [my-skills](https://github.com/tslator/my-skills) skill library at `/opt/my-skills` (stable symlink: `/opt/skills`), root-owned so the agent cannot edit its own skill sources. No network access or `--host-access` is involved: skill content ships in the image, and enablement is plain OpenCode configuration — the native `skills` key in `opencode.json` lists directories to discover skills from.

### Fleet skills

Fleet/workflow skills (`fleet-orchestrator`, `fleet-bead-pilot`) live in the my-skills `fleet-skills/` area and are installed like any other library skill, e.g. `bin/opencode-container skills enable fleet-orchestrator`. The `herdr` skill is tool-owned: regenerate it from the image's pinned herdr binary with `bin/oc-dev herdr-skill` (writes to `~/.opencode-container/config/skills/herdr/`).

### Global vs project layering

| Layer | File | For |
|-------|------|-----|
| Global | `~/.opencode-container/config/opencode.json` | how-you-work skills (workflow, orchestration, all meta-skills) |
| Project | `<project>/opencode.json` (or `.opencode/opencode.json`) | language/domain skills (e.g. Python) |

Project entries **append** to global ones (both layers are active together), edits are picked up live by the config watcher — no restart — and unknown paths degrade with a warning instead of failing.

### Managing skills

```bash
# enable the whole library globally (writes the global config's skills array)
opencode-container skills enable --global

# enable for one project (default: current directory)
cd ~/my-python-project && opencode-container skills enable

# inspect / remove / other installer subcommands
opencode-container skills status
opencode-container skills disable --global
opencode-container skills list
```

`skills <args...>` runs the image-baked installer (`/opt/my-skills/scripts/install_skills.py`) in a one-shot hardened container; `--global` maps to the mounted global config, `--project DIR` mounts `DIR`. Inside a session, the baked meta-skills (all default-enabled) can interview you and curate per-skill selections directly.

**First run:** the default config enables all baked meta-skills (`meta-skill-library-admin`, `meta-skill-eng-brief`, `meta-skill-eng-review`) via the `/opt/skills/meta-skills` directory entry. Just ask the agent — e.g. "help me choose skills for this project" — and it will walk the taxonomy with you and write the right config layer. Existing state dirs predate the default; run `opencode-container -u` once (or `opencode-container skills enable --global`) to adopt it.

### Updating skill content

Enablement changes are config edits only. To pick up new or changed skills from the library, bump the pin and rebuild:

```bash
bin/oc-dev skills-bump   # re-pin vendor/my-skills.sha to upstream HEAD
bin/oc-dev build         # re-vendor the checkout and rebuild the image
```

## Advanced Usage

### Accessing Host Services

By default, `127.0.0.1` inside the container refers to the container itself.
The default bridge network can still have engine- and host-firewall-dependent
reachability to host or local-network services. Launch with `--host-access` to
add an engine-appropriate host alias:

```bash
opencode-container --host-access
```

Inside the container, reach host ports via:

- **Docker:** `http://host.docker.internal:<port>`
- **Podman:** `http://host.containers.internal:<port>`

The launcher prints a warning when host access is enabled. Host services must
authenticate requests and should not expose administrative endpoints to the
agent. On Linux, host services must listen beyond `127.0.0.1` — bind them to
`0.0.0.0` (or, with Docker, the bridge IP usually `172.17.0.1`) if access is
required.

**Note:** skills no longer need `--host-access` — the skill library ships in
the image (see [Skills Library](#skills-library)); host access is only for
reaching host-run services such as model gateways.

**Example — OmniRoute gateway:** with Omniroute listening on port 20128, paste this into `~/.opencode-container/config/opencode.json`, then launch `opencode-container --host-access`. It serves an OpenAI-compatible `/v1` and is keyless by default; if a key is ever needed, add `"apiKey": "{env:OMNIROUTE_API_KEY}"` under `options`. Podman users: use `host.containers.internal` in `baseURL` instead.

```json
{
  "provider": {
    "omniroute": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "OmniRoute",
      "options": {
        "baseURL": "http://host.docker.internal:20128/v1"
      },
      "models": {
        "auto": { "name": "OmniRoute auto" }
      }
    }
  }
}
```

### Development Commands

```bash
bin/oc-dev --help                       # list all commands
bin/oc-dev build                        # Build with auto-detected UID/GID
bin/oc-dev build 2.0.9                  # Build a specific OpenCode version
bin/oc-dev build-latest                 # Build the latest OpenCode release
bin/oc-dev tag-latest 2.0.9             # Tag a built version as latest
bin/oc-dev shell                        # Debug shell (builder-tools stage with bash)
bin/oc-dev clean                        # Remove image
```

The version examples above match `ARG OPENCODE_VERSION` in the Dockerfile; check there for the current default. The binary is pinned by tarball hash (`ARG OPENCODE_SHA256`); `bin/oc-dev build <version>` overrides both (empty hash falls back to the npm registry's integrity check). To bump manually: fetch the new hash with `curl -fsSL "https://registry.npmjs.org/@opencode%2fcli-linux-x64/-/cli-linux-x64-<version>.tgz" | sha256sum`.

### Manual Container Run

For advanced users who need custom container configuration. The wrapper script is the maintained reference and defaults to 4 GB / 4 CPUs. Identical flags work with both `docker run` and `podman run`. Adjust the config mount to your clone path.

```bash
docker run --rm -it \
  --workdir /workspace \
  --read-only \
  --tmpfs /tmp:exec,size=512m,mode=1777 \
  --cap-drop ALL \
  --security-opt=no-new-privileges \
  --memory=2g \
  --cpus=2 \
  -v ~/.opencode-container:/app:rw,Z \
  -v /path/to/opencode-container/config:/app/.config/opencode:rw,Z \
  -v $(pwd):/workspace:rw,Z \
  -v ~/.opencode-container/secrets:/run/secrets:ro,Z \
  opencode-container
```

### Building Manually

```bash
# Default UID/GID (1000) — same flags for podman build
docker build -t opencode-container .

# With your UID/GID (recommended)
docker build --build-arg USER_UID=$(id -u) --build-arg USER_GID=$(id -g) -t opencode-container .

# With version tag
docker build --build-arg USER_UID=$(id -u) --build-arg USER_GID=$(id -g) -t opencode-container:2.0.9 .
```

`bin/oc-dev build` does this for you with whichever engine is installed (override with `CONTAINER_ENGINE=docker` or `CONTAINER_ENGINE=podman`).

### Adding a Custom CA Bundle

Place an optional PEM bundle named `custom-ca.crt` at the build-context root and run `bin/oc-dev build`. The image keeps Debian's default certificates, splits and validates each certificate from the bundle, then runs `update-ca-certificates` after `ca-certificates` is installed. The normalized certificates are retained so hash-based TLS lookups continue to work in the distroless runtime.

This uses a BuildKit-capable builder to read the optional file without requiring a placeholder in the repository.

The custom CA is installed before the remaining build-time HTTPS downloads, including NodeSource and OpenCode. npm is configured to use the resulting system CA bundle for both build-time and runtime registry access. The initial Debian package bootstrap still uses the base image's system trust.

### Building Behind a Proxy

Export credential-free proxy variables in your shell and `bin/oc-dev build` / `bin/oc-dev build-builder-tools`. BuildKit supplies them to network commands without storing them as image `ENV` values; runtime commands receive both upper- and lower-case forms (so apt/curl/npm all pick them up):

```bash
export HTTP_PROXY=http://proxy.example:3128
export HTTPS_PROXY=$HTTP_PROXY
export NO_PROXY=localhost,127.0.0.1
bin/oc-dev build
```

Credential-free proxy URLs are forwarded into the running container, so
OpenCode inside it can reach the network. Proxy URLs containing embedded
credentials are rejected; use a credential-free proxy or configure proxy
authentication outside this launcher. If a previously failed (no-proxy) build
left stale layers, run `bin/oc-dev prune-cache` first. Note: if your proxy terminates
TLS with a corporate CA certificate, build-time certificate validation will
still fail unless that CA is added to the image.

### Runtime Details

The image uses a multi-stage build with a distroless runtime:

- **Base:** `gcr.io/distroless/base-debian13` (no package manager; Debian `dash` is added as `/bin/sh` for OpenCode's shell tool and npm)
- **Node.js:** Node 24 from NodeSource, runtime dependencies extracted via `collect-runtime-deps.sh`
- **Python:** Python 3 with venv support from Debian 13, plus pinned [uv](https://github.com/astral-sh/uv) release binaries (`uv`, `uvx`) for fast package/project management
- **OpenCode:** installed from the checksum-verified npm platform tarball (`@opencode/cli-linux-x64`), pinned via `OPENCODE_VERSION` + `OPENCODE_SHA256`
- **Runtime collector:** resolves and verifies every executable in the Dockerfile manifest before the final image is assembled
- **Bootstrap:** `bootstrap.py` loads supported secrets from `/run/secrets`, then execs OpenCode
