#!/bin/bash
#===========================================================================
# codex-proxy — Launch Codex.app through a proxy (Chromium --proxy-server)
#
# The only approach that actually works: Chromium's native --proxy-server
# flag. HTTP_PROXY env vars are ignored by Chromium. proxychains-ng is
# blocked by Hardened Runtime. sandbox-exec deadlocks with Chromium's own
# sandbox. This is the one that shipped.
#
# Usage:
#   codex-proxy                              # defaults from config or 127.0.0.1:7898
#   codex-proxy --proxy-url socks5://:1080   # one-off override
#   CODEX_PROXY_URL=http://:7890 codex-proxy # env var override
#   codex-proxy --help                       # show help
#
# Config files (read in order, first wins):
#   1. $CODEX_PROXY_CONFIG              (explicit path)
#   2. ./codex-proxy-launcher.env       (repo / working dir)
#   3. ~/.codex-proxy-launcher.env      (user-level, survives updates)
#===========================================================================

set -euo pipefail

# --- defaults ---
CODEX_BIN="/Applications/Codex.app/Contents/MacOS/Codex"
PROXY_URL=""
PROXY_HOST=""
PROXY_PORT=""
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"

# --- helpers ---
trim() {
    local v="$1"
    v="${v#${v%%[![:space:]]*}}"
    v="${v%${v##*[![:space:]]}}"
    printf '%s' "$v"
}

fail() { echo "[codex-proxy] ERROR: $*" >&2; exit 1; }

# --- config file loader ---
load_config_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%$'\r'}"
        line="$(trim "${line%%#*}")"
        [[ -z "$line" || "$line" != *=* ]] && continue

        local key="$(trim "${line%%=*}")"
        local value="$(trim "${line#*=}")"
        value="${value#\"}"; value="${value%\"}"
        value="${value#\'}"; value="${value%\'}"

        case "$key" in
            CODEX_PROXY_PORT)  [[ -z "${PROXY_PORT:-}" ]]  && PROXY_PORT="$value"  ;;
            CODEX_PROXY_HOST)  [[ -z "${PROXY_HOST:-}" ]]  && PROXY_HOST="$value"  ;;
            CODEX_PROXY_URL)   [[ -z "${PROXY_URL:-}" ]]   && PROXY_URL="$value"   ;;
            CODEX_APP_PATH)    [[ -z "${CODEX_APP_PATH:-}" ]] && CODEX_BIN="$value" ;;
        esac
    done < "$file"
}

# === load config (ordered by priority) ===
[[ -n "${CODEX_PROXY_CONFIG:-}" ]] && load_config_file "$CODEX_PROXY_CONFIG"
load_config_file "${SCRIPT_DIR}/codex-proxy-launcher.env"
load_config_file "${HOME}/.codex-proxy-launcher.env"

# === resolve proxy URL ===
if [[ -z "${PROXY_URL:-}" ]]; then
    if [[ -n "${CODEX_PROXY_URL:-}" ]]; then
        PROXY_URL="$CODEX_PROXY_URL"
    elif [[ -n "${PROXY_HOST:-}" && -n "${PROXY_PORT:-}" ]]; then
        PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"
    else
        PROXY_URL="http://127.0.0.1:7898"
    fi
fi

# --- argument parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --proxy-url)
            PROXY_URL="$2"
            shift 2
            ;;
        --help|-h)
            cat << 'HELP'
codex-proxy — Launch Codex.app through a proxy

USAGE:
  codex-proxy [OPTIONS]

OPTIONS:
  --proxy-url <url>   Proxy URL (default: http://127.0.0.1:7898)
  --help, -h          Show this help

CONFIG FILES (read in order, first set wins):
  1. $CODEX_PROXY_CONFIG               explicit path
  2. ./codex-proxy-launcher.env        working directory
  3. ~/.codex-proxy-launcher.env       user-level (recommended)

  Example ~/.codex-proxy-launcher.env:
    CODEX_PROXY_HOST=127.0.0.1
    CODEX_PROXY_PORT=7898

ENVIRONMENT:
  CODEX_PROXY_URL     Full proxy URL (overrides config files;
                      --proxy-url takes precedence over this)

EXAMPLES:
  codex-proxy
  codex-proxy --proxy-url socks5://127.0.0.1:1080

Why --proxy-server and not HTTP_PROXY?
  Chromium ignores HTTP_PROXY/HTTPS_PROXY env vars on macOS.
  --proxy-server is the only reliable mechanism. See:
  https://github.com/ctrailblazerx/codex-gui-proxy
HELP
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run: codex-proxy --help" >&2
            exit 1
            ;;
    esac
done

# === preflight: find Codex ===
# Allow CODEX_APP_PATH override from config/env
[[ -n "${CODEX_APP_PATH:-}" ]] && CODEX_BIN="$CODEX_APP_PATH"

# Fallback: check ~/Applications if /Applications doesn't exist
if [[ ! -x "$CODEX_BIN" ]]; then
    local_bin="${HOME}/Applications/Codex.app/Contents/MacOS/Codex"
    [[ -x "$local_bin" ]] && CODEX_BIN="$local_bin"
fi

if [[ ! -x "$CODEX_BIN" ]]; then
    fail "Codex not found at $CODEX_BIN
  Set CODEX_APP_PATH in ~/.codex-proxy-launcher.env if installed elsewhere."
fi

# === already-running check ===
if pgrep -qx Codex 2>/dev/null; then
    echo "[codex-proxy] Codex is already running."
    echo "[codex-proxy] Quit Codex completely (Cmd+Q), then re-run this launcher"
    echo "[codex-proxy] so the new instance picks up proxy settings."
    exit 1
fi

# === proxy health check ===
echo "[codex-proxy] Proxy: $PROXY_URL"

# Extract host:port for nc check
check_host="${PROXY_URL#*://}"; check_host="${check_host%%/*}"
check_port="${check_host##*:}"; check_host="${check_host%%:*}"

if [[ "$check_port" =~ ^[0-9]+$ ]]; then
    if ! nc -z -w 2 "$check_host" "$check_port" 2>/dev/null; then
        echo "[codex-proxy] WARNING: $check_host:$check_port is not listening." >&2
        echo "[codex-proxy] Start your proxy client first." >&2
    fi
else
    echo "[codex-proxy] WARNING: could not parse proxy port from '$PROXY_URL'" >&2
fi

# === launch ===
echo "[codex-proxy] Starting Codex..."

# Set both cases for programs that use either convention (even though
# Chromium ignores them, subprocesses / CLI tools might benefit)
export HTTP_PROXY="$PROXY_URL"
export HTTPS_PROXY="$PROXY_URL"
export ALL_PROXY="$PROXY_URL"
export NO_PROXY="localhost,127.0.0.1,::1"
export http_proxy="$PROXY_URL"
export https_proxy="$PROXY_URL"
export all_proxy="$PROXY_URL"
export no_proxy="localhost,127.0.0.1,::1"

nohup "$CODEX_BIN" \
    --proxy-server="$PROXY_URL" \
    --proxy-bypass-list="<-loopback>" \
    > /dev/null 2>&1 &

sleep 2
CODEX_PID=$(pgrep -f "Codex.app/Contents/MacOS/Codex" | head -1)

if [[ -n "$CODEX_PID" ]]; then
    echo "[codex-proxy] Running (PID $CODEX_PID)"
    echo "[codex-proxy] Verify:  lsof -p $CODEX_PID -i TCP"
else
    echo "[codex-proxy] WARNING: Codex may not have started." >&2
    echo "[codex-proxy] Try directly:" >&2
    echo "  $CODEX_BIN --proxy-server=\"$PROXY_URL\"" >&2
fi
