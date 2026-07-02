<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey?style=flat-square" alt="platform">
  <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="license">
  <img src="https://img.shields.io/badge/dependencies-zero-brightgreen?style=flat-square" alt="deps">
  <img src="https://img.shields.io/badge/size-15%20lines-ff69b4?style=flat-square" alt="size">
</p>

<p align="center">
  <b>English</b> &nbsp;|&nbsp; <a href="README_CN.md">中文文档</a>
</p>

# codex-gui-proxy

> **One command to proxy any Electron app on macOS. No kernel hooks, no re-signing, no sandbox hacks.**

```bash
codex-proxy
```

---

## Why?

macOS makes per-app proxy a surprising puzzle. You'd think `HTTP_PROXY` would work, or `proxychains`. You'd be wrong.

| Approach | Why it failed |
|----------|---------------|
| `proxychains-ng` | Hardened Runtime silently drops `DYLD_INSERT_LIBRARIES` |
| PF + dedicated user | macOS PF lacks `rdr-to`; GUI apps can't run as daemon users |
| `sandbox-exec` | Chromium's own sandbox deadlocks with the outer sandbox |
| `HTTP_PROXY` env var | Chromium ignores it — uses its own network stack |

The answer? Chromium has a built-in flag for this. It's been there all along.

```
--proxy-server=<url>
```

That's it. This repo wraps that flag into a 15-line shell script.

---

## Quick Start

```bash
# 1. Download
curl -o ~/.local/bin/codex-proxy https://raw.githubusercontent.com/icyblazek/codex-gui-proxy/main/codex-proxy.sh
chmod +x ~/.local/bin/codex-proxy

# 2. Run
codex-proxy
```

Default proxy: `http://127.0.0.1:7898` (V2Ray / Clash default HTTP inbound).  
Edit the script to match your port, or set `CODEX_PROXY_URL`:

```bash
CODEX_PROXY_URL=socks5://127.0.0.1:1080 codex-proxy
```

---

## How It Works

```
┌─────────────────────────────────────┐
│  Codex.app (Electron / Chromium)    │
│                                     │
│  --proxy-server=http://127.0.0.1:7898
│         │                           │
│         ▼                           │
│  ┌──────────┐     ┌──────────────┐  │
│  │  V2Ray   │────▶│  Internet    │  │
│  │  :7898   │     │  (proxied)   │  │
│  └──────────┘     └──────────────┘  │
│                                     │
│  Direct connections → blocked       │
│  Proxy connections  → allowed       │
└─────────────────────────────────────┘
```

Chromium's network stack natively supports `--proxy-server`. No dylib injection, no kernel hook, no sandbox nesting. The flag has been in Chromium since 2010.

---

## Features

* **Zero dependencies** — macOS built-ins only (`curl`, `bash`, `nc`)
* **15 lines of logic** — read the whole thing in 30 seconds
* **Config file support** — `.env` file in repo or `~/.codex-proxy-launcher.env`
* **Already-running detection** — warns if Codex is open (must restart for proxy)
* **SOCKS5 support** — `socks5://127.0.0.1:1080` just works
* **IPC-safe** — `--proxy-bypass-list="<-loopback>"` keeps local traffic direct
* **Health check** — verifies proxy is listening before launching
* **Fire and forget** — `nohup` background launch, prints PID

---

## Install

### Option 1: One-liner

```bash
curl -sSL https://raw.githubusercontent.com/icyblazek/codex-gui-proxy/main/codex-proxy.sh | bash
```

### Option 2: Manual

```bash
mkdir -p ~/.local/bin
curl -o ~/.local/bin/codex-proxy https://raw.githubusercontent.com/icyblazek/codex-gui-proxy/main/codex-proxy.sh
chmod +x ~/.local/bin/codex-proxy

# Add to PATH if needed
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### Option 3: Git clone

```bash
git clone https://github.com/icyblazek/codex-gui-proxy.git
ln -s "$(pwd)/codex-gui-proxy/codex-proxy.sh" ~/.local/bin/codex-proxy
chmod +x codex-gui-proxy/codex-proxy.sh
```

---

## Configuration

### Recommended: Config file

Create `~/.codex-proxy-launcher.env` (survives script updates):

```bash
cp codex-proxy-launcher.env.example ~/.codex-proxy-launcher.env
nano ~/.codex-proxy-launcher.env
```

```env
CODEX_PROXY_HOST=127.0.0.1
CODEX_PROXY_PORT=7898
```

Config files are read in order (first set value wins):

| Priority | Path | Purpose |
|----------|------|---------|
| 1 | `$CODEX_PROXY_CONFIG` | Explicit path |
| 2 | `./codex-proxy-launcher.env` | Working directory |
| 3 | `~/.codex-proxy-launcher.env` | User-level (recommended) |

### Alternative: CLI / env var

```bash
# Command-line flag
codex-proxy --proxy-url socks5://127.0.0.1:1080

# Environment variable
CODEX_PROXY_URL=http://127.0.0.1:7890 codex-proxy
```

Supported schemes: `http`, `https`, `socks4`, `socks5`, `quic`.

---

## Usage

```bash
codex-proxy                          # default proxy (http://127.0.0.1:7898)
codex-proxy --proxy-url socks5://127.0.0.1:1080   # override
codex-proxy --help                   # show help
```

Output:

```
[codex-proxy] Starting Codex --proxy-server=http://127.0.0.1:7898
[codex-proxy] Running — PID 42991
```

### Verify

```bash
# Check Codex's TCP connections — should show only proxy
lsof -p $(pgrep -f 'Codex.app/Contents/MacOS/Codex') -i TCP
```

Expected: only connections to `127.0.0.1:7898` (or your proxy port).

---

## Compatibility

Tested and confirmed working with any Chromium/Electron app:

| App | Command |
|-----|---------|
| **Codex** | `codex-proxy` |
| **VS Code** | `code --proxy-server="http://127.0.0.1:7898"` |
| **Discord** | `/Applications/Discord.app/Contents/MacOS/Discord --proxy-server=...` |
| **Slack** | `/Applications/Slack.app/Contents/MacOS/Slack --proxy-server=...` |
| **Figma** | `/Applications/Figma.app/Contents/MacOS/Figma --proxy-server=...` |
| **Notion** | `/Applications/Notion.app/Contents/MacOS/Notion --proxy-server=...` |
| **Postman** | `Postman --proxy-server=...` |
| **Spotify** | `spotify --proxy-server=...` |
| **Teams** | `teams --proxy-server=...` |

---

## Troubleshooting

<details>
<summary>Codex is already running</summary>

The launcher detects an existing Codex process and refuses to start a second one.
Quit Codex completely (Cmd+Q), then re-run `codex-proxy` so the new instance
inherits the proxy settings.

```bash
# Force-quit if needed
pkill -x Codex
codex-proxy
```
</details>

<details>
<summary><code>WARNING: proxy unreachable</code></summary>

Your proxy isn't running or the port doesn't match. Verify:

```bash
curl --proxy http://127.0.0.1:7898 https://httpbin.org/ip
```

If this fails, start your proxy (V2Ray, Clash, Surge) first.
</details>

<details>
<summary>UI won't load / blank screen</summary>

The `--proxy-bypass-list` may be too aggressive. Remove it and retry:

```bash
/Applications/Codex.app/Contents/MacOS/Codex --proxy-server="http://127.0.0.1:7898"
```

If that works, the app has local IPC needs beyond `<-loopback>`.
</details>

<details>
<summary>App crashes on launch</summary>

Check your proxy URL format. It must include the scheme:

✅ `http://127.0.0.1:7898`  
✅ `socks5://127.0.0.1:1080`  
❌ `127.0.0.1:7898` (missing `http://`)
</details>

<details>
<summary>How do I use a proxy that requires authentication?</summary>

```
--proxy-server="http://user:pass@proxy.example.com:8080"
```

Note: credentials in command-line args are visible to other processes on the same machine.
</details>

---

## FAQ

**Q: Why not just set system proxy in macOS Settings?**

A: That routes ALL traffic through the proxy. This repo is for per-app proxy — only Codex (or your target app) goes through it.

**Q: Does this work on Linux?**

A: Yes. Chromium's `--proxy-server` is cross-platform. On Linux, many apps also respect `HTTP_PROXY`, so you have options.

**Q: What about Apple Silicon (M1/M2/M3)?**

A: Works natively. No Rosetta needed.

**Q: Can I use this without Codex?**

A: Yes. Replace `CODEX_BIN` with any Electron app's binary. See the [Compatibility](#compatibility) table.

---

## Reference

- [Chromium Network Settings](https://www.chromium.org/developers/design-documents/network-settings/)
- [`chrome://flags`](chrome://flags) — search "proxy" for all proxy-related flags
- [Chromium source: `content/public/common/content_switches.cc`](https://source.chromium.org/chromium/chromium/src/+/main:content/public/common/content_switches.cc)

Full deep-dive article: [codex-proxy-solution.md](codex-proxy-solution.md)

---

## License

MIT © [ICYBLAZK](https://github.com/ICYBLAZK)
