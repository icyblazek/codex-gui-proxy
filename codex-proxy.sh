#!/bin/bash
#===========================================================================
# codex-proxy — Launch Codex.app with proxy via Chromium --proxy-server
#
# Usage:
#   codex-proxy                              # default proxy
#   codex-proxy --proxy-url socks5://:1080   # custom proxy
#   CODEX_PROXY_URL=http://:7890 codex-proxy  # env var override
#   codex-proxy --help                       # show help
#
# Chromium's --proxy-server flag is the only reliable way to force proxy
# on Electron apps. HTTP_PROXY env vars are ignored by Chromium.
#===========================================================================

set -euo pipefail

CODEX_BIN="/Applications/Codex.app/Contents/MacOS/Codex"
PROXY_URL="${CODEX_PROXY_URL:-http://127.0.0.1:7898}"

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

ENVIRONMENT:
  CODEX_PROXY_URL     Override default proxy URL
                      (--proxy-url takes precedence)

EXAMPLES:
  codex-proxy
  codex-proxy --proxy-url socks5://127.0.0.1:1080
  CODEX_PROXY_URL=http://127.0.0.1:7890 codex-proxy

For other Electron apps, replace CODEX_BIN in the script.
HELP
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: codex-proxy [--proxy-url <url>] [--help]" >&2
            exit 1
            ;;
    esac
done

# --- preflight ---
fail() { echo "[codex-proxy] ERROR: $*" >&2; exit 1; }

if [[ ! -x "$CODEX_BIN" ]]; then
    fail "Codex not found at $CODEX_BIN"
fi

# --- proxy health check ---
echo "[codex-proxy] Proxy: $PROXY_URL"

if command -v curl &>/dev/null; then
    if ! curl -sf --connect-timeout 2 --proxy "$PROXY_URL" http://localhost:7898 >/dev/null 2>&1; then
        echo "[codex-proxy] WARNING: proxy unreachable ($PROXY_URL)" >&2
        echo "[codex-proxy] Codex will start but network may fail." >&2
    fi
fi

# --- launch ---
echo "[codex-proxy] Starting Codex..."

nohup "$CODEX_BIN" \
    --proxy-server="$PROXY_URL" \
    --proxy-bypass-list="<-loopback>" \
    > /dev/null 2>&1 &

sleep 2

CODEX_PID=$(pgrep -f "Codex.app/Contents/MacOS/Codex" | head -1)

if [[ -n "$CODEX_PID" ]]; then
    echo "[codex-proxy] Running (PID $CODEX_PID)"
    echo "[codex-proxy] Verify: lsof -p $CODEX_PID -i TCP"
else
    echo "[codex-proxy] WARNING: Codex may not have started." >&2
    echo "[codex-proxy] Try running directly:" >&2
    echo "  $CODEX_BIN --proxy-server=\"$PROXY_URL\"" >&2
fi
