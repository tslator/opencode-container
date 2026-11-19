# shellcheck shell=bash
# Shared host-side helpers for bin/opencode-container and bin/oc-dev.
# Sourced, never executed directly. Safe under `set -e` and `set -u`.

# die MESSAGE — print an error and exit 1.
die() {
    echo "error: $*" >&2
    exit 1
}

# detect_engine — set ENGINE from $CONTAINER_ENGINE, or autodetect podman
# first, then docker. Exits with an error when neither is found.
detect_engine() {
    ENGINE="${CONTAINER_ENGINE:-}"
    if [ -z "$ENGINE" ]; then
        if command -v podman >/dev/null 2>&1; then
            ENGINE=podman
        elif command -v docker >/dev/null 2>&1; then
            ENGINE=docker
        else
            echo "Error: no container engine found; install podman/docker or set CONTAINER_ENGINE" >&2
            exit 1
        fi
    fi
}

# reject_proxy_credentials URL — reject proxy URLs with embedded credentials.
reject_proxy_credentials() {
    case "$1" in
        *://*@*)
            echo "error: proxy URLs with embedded credentials are not supported" >&2
            exit 2
            ;;
    esac
}

# init_proxy — set EFF_HTTP_PROXY / EFF_HTTPS_PROXY / EFF_NO_PROXY from
# whichever of the upper- or lower-case variables the caller exported, and
# reject embedded credentials (tools differ on which case they read).
# EFF_* are consumed indirectly by proxy_env_args via ${!var}.
# shellcheck disable=SC2034
init_proxy() {
    EFF_HTTP_PROXY="${HTTP_PROXY:-${http_proxy:-}}"
    EFF_HTTPS_PROXY="${HTTPS_PROXY:-${https_proxy:-}}"
    EFF_NO_PROXY="${NO_PROXY:-${no_proxy:-}}"
    [ -n "$EFF_HTTP_PROXY" ] && reject_proxy_credentials "$EFF_HTTP_PROXY"
    [ -n "$EFF_HTTPS_PROXY" ] && reject_proxy_credentials "$EFF_HTTPS_PROXY"
    return 0
}

# proxy_env_args — after init_proxy, set PROXY_ENV_ARGS to the `-e K=V`
# engine-run arguments for both cases of each proxy variable that is set.
proxy_env_args() {
    local name var value
    PROXY_ENV_ARGS=()
    for name in HTTP_PROXY HTTPS_PROXY NO_PROXY; do
        var="EFF_${name}"
        value="${!var}"
        [ -n "$value" ] || continue
        PROXY_ENV_ARGS+=(-e "${name}=${value}" -e "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')=${value}")
    done
    return 0
}
