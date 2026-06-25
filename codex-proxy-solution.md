# Forcing Codex.app Through a Proxy: The Five-Attempt Debugging Chronicle

> Author: ICYBLAZEK  
> Date: 2026-06-25  
> Tags: macOS, proxy, Electron, Chromium, network isolation

---

## 0. The Problem

Route all network traffic from `/Applications/Codex.app` (OpenAI's AI coding assistant) through a local V2Ray proxy (`127.0.0.1:7898`), leaving the rest of the system untouched.

Codex is a closed-source third-party app. You don't know what domains or IPs it talks to. What you need is **routing by process identity**, not routing by destination.

---

## 1. Attempt One: proxychains-ng (Failed in 3 Minutes)

### The Theory

Inject `libproxychains4.dylib` via `DYLD_INSERT_LIBRARIES`, hook `connect()` and `getaddrinfo()`. All TCP connections and DNS resolution from the target process flow through the proxy.

### What We Did

```bash
brew install proxychains-ng
# Configure ~/.proxychains/proxychains.conf → socks5 127.0.0.1:7897
proxychains4 /Applications/Codex.app/Contents/MacOS/Codex
```

### Result: Nothing. The proxy had zero effect.

### Diagnosis

```bash
codesign -dvvv /Applications/Codex.app
# flags=0x10000(runtime)   ← Hardened Runtime is ON

codesign -d --entitlements - /Applications/Codex.app
# Missing: com.apple.security.cs.allow-dyld-environment-variables
```

**Root cause:** Codex has Hardened Runtime enabled and does not declare the DYLD environment variable entitlement. The macOS dynamic linker **silently drops** `DYLD_INSERT_LIBRARIES`. The dylib injection never happens.

### Lesson

`proxychains-ng` depends on `DYLD_INSERT_LIBRARIES`. This mechanism is dead on arrival for any app with Hardened Runtime — which is nearly every signed third-party app. Apple provides the `com.apple.security.cs.allow-dyld-environment-variables` entitlement switch, but almost no app enables it.

---

## 2. Attempt Two: PF + Dedicated User (Kernel-Level, DOA)

### The Theory

Run the target app under a dedicated user. PF (Packet Filter) matches outbound traffic by UID and redirects it to a local transparent proxy.

### The Design

```bash
# Create dedicated user _codexproxy (UID 502)
sudo dscl . -create /Users/_codexproxy UniqueID 502

# Planned PF rule
pass out proto tcp from any to any user 502 rdr-to 127.0.0.1 port 12345
```

### Result: `pfctl -n` threw a syntax error.

### Diagnosis

macOS's PF comes from OpenBSD, but it's an older version:

- `pass out ... user <uid>` ✅ supported
- `pass out ... rdr-to` ❌ NOT supported (newer OpenBSD feature)
- `pass out ... divert-to` ❌ also NOT supported
- `rdr` rules do NOT support `user` matching

**macOS PF can only `block`/`pass` by UID. It cannot redirect traffic by UID.**

### Layer-Two Problem

Even if PF redirection worked, there's a fatal issue with GUI apps:

```bash
sudo -u _codexproxy /Applications/Codex.app/Contents/MacOS/Codex
# → App cannot connect to WindowServer. GUI rendering fails.
```

macOS daemon users (no login session) cannot launch GUI apps. `_codexproxy`, even with a valid UID, has no access to the window server.

### Lessons

- macOS PF ≠ OpenBSD PF. The feature subset is limited.
- You cannot isolate GUI app networking by switching users.
- This approach only works for pure CLI applications.

---

## 3. Attempt Three: sandbox-exec (System Sandbox, Deadlock)

### The Theory

macOS's `sandbox-exec` provides process-level sandboxing with fine-grained network control. The plan:

```scheme
(deny network-outbound)                              # Block all outbound
(allow network-outbound (remote ip "localhost:7898")) # Only allow proxy port
```

### What We Did

```bash
sandbox-exec -f codex-proxy.sb /Applications/Codex.app/Contents/MacOS/Codex
```

### v1 Failure: `(deny network*)` Too Aggressive

Codex threw this error on launch:

```
Failed to bind() SingletonSocket: Operation not permitted
Failed to create a ProcessSingleton
```

**Root cause:** `(deny network*)` blocked Unix Domain Socket `bind()`. Electron/Chromium uses UDS for its process singleton lock (ProcessSingleton). The sandbox intercepted the bind, and the app exited immediately.

Fix: switch to `(deny network-outbound)` — only block outbound TCP/UDP, leave Unix sockets alone.

### v2 Failure: Double Sandbox Deadlock

After fixing the UDS issue, Codex **did launch** — then immediately crashed:

```
sandbox initialization failed: Operation not permitted
Network service crashed, restarting...
GPU process exited unexpectedly: exit_code=6
GPU process isn't usable. Goodbye.
```

**Root cause:** Codex is an Electron/Chromium app. It **has its own internal subprocess sandboxes** (renderer, GPU, network service each run in independent sandboxes). When we wrapped the entire process in `sandbox-exec`, Chromium's inner sandbox initialization was rejected by the outer sandbox — a **double-sandbox deadlock**.

This is an architectural conflict with no workaround. Chromium's sandbox initialization requires specific system calls (`sandbox_init`, mach port access, etc.) that an outer sandbox denies by default.

### Lessons

- Chromium/Electron apps cannot be wrapped in `sandbox-exec`.
- Nested sandboxing is an anti-pattern — the inner sandbox needs capabilities the outer one won't grant.
- `sandbox-exec` is for native macOS apps, not for browser frameworks that ship their own sandbox.

---

## 4. Attempt Four: HTTP_PROXY Environment Variables (Launched, But Dead)

### The Assumption

Codex is an Electron app. Electron is based on Chromium. Unix/Linux programs generally respect `HTTP_PROXY`/`HTTPS_PROXY` environment variables.

### What We Did

```bash
export HTTP_PROXY="http://127.0.0.1:7898"
export HTTPS_PROXY="http://127.0.0.1:7898"
/Applications/Codex.app/Contents/MacOS/Codex &
```

### Result: The app launched successfully. The UI couldn't load. The proxy had no effect.

### Diagnosis

Chromium on macOS **does not read** the `HTTP_PROXY` environment variable. Chromium's proxy configuration mechanisms are:

1. macOS system proxy settings (System Settings → Network → Proxies)
2. `--proxy-server` command-line flag
3. PAC script (`--proxy-pac-url`)
4. Writing to the Preferences JSON file

`HTTP_PROXY` is a Unix/Linux libcurl convention. Chromium takes an entirely different path.

### Lesson

Environment variable proxy settings are unreliable for GUI apps. Electron/Chromium uses its own network stack (Chromium Network Service), independent of the system's libcurl/CFNetwork proxy resolution. Each framework has its own proxy discovery mechanism. There is no universal solution.

---

## 5. Attempt Five: `--proxy-server` (The Right Answer, First Try)

### The Theory

`--proxy-server` is Chromium's native command-line flag, built into the Chromium network stack. Format:

```
--proxy-server=<scheme>://<host>:<port>
--proxy-bypass-list=<pattern>
```

Supported schemes: `http`, `socks4`, `socks5`, `quic`.

### What We Did

```bash
/Applications/Codex.app/Contents/MacOS/Codex \
    --proxy-server="http://127.0.0.1:7898" \
    --proxy-bypass-list="<-loopback>"
```

`<-loopback>` is a Chromium built-in pattern that keeps localhost traffic direct (Codex's internal IPC between components should not go through the proxy).

### Result: App launched normally. All API traffic routed through V2Ray.

### Why This One Worked

| Approach | Layer | Why It Failed |
|----------|-------|---------------|
| proxychains-ng | User-mode dylib | Hardened Runtime blocked it |
| PF + dedicated user | Kernel PF | macOS PF lacks capability + GUI cannot cross users |
| sandbox-exec | Kernel sandbox | Chromium inner sandbox conflict |
| HTTP_PROXY env var | Process environment | Chromium ignores it |
| **`--proxy-server`** | Chromium network stack | ✅ Native mechanism, zero conflict |

`--proxy-server` is Chromium's own proxy interface. No dylib injection, no kernel hooks, no sandbox involvement.

---

## 6. The Final Artifact

A 15-line launch script at `~/.local/bin/codex-proxy`:

```bash
#!/bin/bash
# Codex.app proxy launcher — Chromium --proxy-server approach
CODEX_BIN="/Applications/Codex.app/Contents/MacOS/Codex"
PROXY_URL="http://127.0.0.1:7898"

curl -s --connect-timeout 2 --proxy "$PROXY_URL" http://localhost:7898 >/dev/null 2>&1 \
  || echo "WARNING: proxy $PROXY_URL unreachable" >&2

nohup "$CODEX_BIN" \
    --proxy-server="$PROXY_URL" \
    --proxy-bypass-list="<-loopback>" \
    "$@" > /dev/null 2>&1 &

sleep 2
pgrep -f "Codex.app/Contents/MacOS/Codex" >/dev/null \
  && echo "[codex-proxy] Codex running" \
  || echo "[codex-proxy] WARNING: Codex may not have started"
```

Usage:

```bash
codex-proxy
```

The complete, polished version (with `--proxy-url`, `CODEX_PROXY_URL`, and `--help`) is at [codex-gui-proxy](https://github.com/icyblazek/codex-gui-proxy).

---

## 7. Methodology

### The Failure Tree

```
Goal: Route traffic by process identity
 │
 ├─[1] proxychains-ng ──→ Hardened Runtime blocked
 │
 ├─[2] PF + dedicated user ──→ PF capability gap + GUI user isolation impossible
 │
 ├─[3] sandbox-exec ────→ Chromium sandbox conflict (double sandbox deadlock)
 │
 ├─[4] HTTP_PROXY env var → Chromium ignores it
 │
 └─[5] --proxy-server ──→ ✅ Success
```

### Core Lessons

1. **Check the signature first (`codesign -dvvv`), then choose your approach.** Hardened Runtime kills the dylib injection path. If you see `flags=0x10000(runtime)`, abandon `proxychains-ng` immediately.

2. **macOS PF ≠ OpenBSD PF.** Don't assume features from the BSD man pages exist on macOS. `user` matching only supports `block`/`pass`, not `rdr-to`.

3. **GUI apps cannot be launched across users.** `sudo -u` to a non-logged-in user will always fail to connect to the WindowServer.

4. **Chromium apps ship their own sandbox.** Don't wrap a sandboxed app in another sandbox — the inner sandbox needs capabilities the outer one won't provide.

5. **Chromium does not read HTTP_PROXY.** `--proxy-server` is the only reliable way to configure a proxy for Chromium.

6. **Every framework has its own proxy discovery mechanism.** libcurl reads environment variables, Chromium reads command-line flags or system settings, NSURLSession reads system proxy settings. There is no unified solution.

### Applicability

The `--proxy-server` approach works for **all Chromium/Electron-based applications**:

- VS Code (`code --proxy-server=...`)
- Slack
- Discord
- Figma
- Notion
- Any Electron-shelled app

Authoritative references for Chromium command-line flags: `chrome://flags` and the Chromium source at `content/public/common/content_switches.cc`.
