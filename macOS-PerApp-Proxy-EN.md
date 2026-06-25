# macOS Per-App Proxy — Routing by Process Identity

> Scenario: You don't know a third-party app's traffic patterns (domains, IPs, ports), but you want **only that app** to go through a proxy — the rest of the system untouched.
>
> Core insight: switch from "route by destination" to **"route by process identity."** The macOS kernel network stack natively holds process context (it knows which process created every socket) — but the higher-level APIs default to matching on domains and IPs, which misdirects people.
>
> **Author: ICYBLAZK**

---

## 1. `proxychains-ng` (Fastest — 3 minutes)

### How It Works

Uses `DYLD_INSERT_LIBRARIES` + `DYLD_FORCE_FLAT_NAMESPACE` to inject `libproxychains4.dylib`, hooking `connect()` and `getaddrinfo()`. All TCP connections and DNS resolution (when `proxy_dns` is enabled) from the target process flow through the proxy — zero DNS leaks.

### Applicability

99% of third-party GUI apps (anything not Apple-signed). Apple-signed processes are blocked by SIP, but third-party apps are the sweet spot for this approach.

### Setup

```bash
# Install
brew install proxychains-ng

# Configure ~/.proxychains/proxychains.conf
cat > ~/.proxychains/proxychains.conf << 'EOF'
strict_chain
proxy_dns
[ProxyList]
socks5 127.0.0.1 1080
EOF

# Launch target app — only it gets proxied
proxychains4 /Applications/SomeApp.app/Contents/MacOS/SomeApp
```

### Verification

```bash
lsof -p $(pgrep AppName) | grep TCP
# You'll only see connections to 127.0.0.1:1080
```

**Pros:** No system changes, no need to know traffic patterns, fire and forget.

> ⚠️ **Caveat:** Fails on apps with Hardened Runtime that lack the `com.apple.security.cs.allow-dyld-environment-variables` entitlement. Use `codesign -dvvv /Applications/AppName.app` to check first.

---

## 2. PF + User-Level Isolation

### How It Works

Run the target app under a **dedicated user**. PF (Packet Filter) matches outbound traffic by `uid`/`gid` and redirects it to a local transparent proxy.

### Setup

```bash
# 1. Create a dedicated proxy user
sudo dscl . -create /Users/proxyuser
sudo dscl . -create /Users/proxyuser UniqueID 501

# 2. PF rules (/etc/pf.conf)
table <proxy_users> { 501 }
rdr pass on lo0 proto tcp from any to any -> 127.0.0.1 port 12345
pass out on en0 proto tcp from any to any user 501 rdr-to 127.0.0.1 port 12345

# 3. Enable PF
sudo pfctl -E -f /etc/pf.conf

# 4. Launch app as the dedicated user
sudo -u proxyuser /Applications/SomeApp.app/Contents/MacOS/SomeApp
```

**Paired with a transparent proxy:**

```bash
# mitmproxy in transparent mode (HTTPS supported)
mitmproxy --mode transparent --listen-port 12345
sudo sysctl -w net.inet.ip.forwarding=1
```

**Pros:** Kernel-level, no dylib injection dependency, SIP-independent.

> ⚠️ **Caveat:** `rdr-to` in `pass out` rules is NOT supported on macOS PF (it's an OpenBSD feature). GUI apps cannot launch under daemon users (no WindowServer access). This approach is only viable for CLI applications on macOS.

---

## 3. Per-App VPN (NetworkExtension — the Official Route)

### How It Works

macOS 10.15+ natively supports Per-App VPN. The system network stack automatically identifies each outbound packet's bundle and routes only the specified app's traffic through a virtual interface.

### Limitations

- Individual developers must go through **MDM profiles** (Apple Configurator 2 or self-signed)
- Without MDM, you can only do "device-wide VPN" — no per-app VPN
- Requires `com.apple.developer.networking.networkextension` entitlement

### MDM Profile Example (`perapp-vpn.mobileconfig`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadIdentifier</key>
    <string>com.example.perapp-vpn</string>
    <key>PayloadUUID</key>
    <string>XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key>
            <string>com.apple.vpn.managed</string>
            <key>PayloadIdentifier</key>
            <string>com.example.perapp-vpn.vpn</string>
            <key>VPN</key>
            <dict>
                <key>OnDemandMatchAppEnabled</key>
                <string>PerApp</string>
                <key>OnDemandMatchDomainsAlways</key>
                <array/>
                <key>OnDemandMatchAppOnDemandRules</key>
                <array>
                    <dict>
                        <key>DNSDomainMatch</key>
                        <array/>
                        <key>Action</key>
                        <string>Connect</string>
                        <key>AppDomainMatch</key>
                        <array>
                            <!-- Target bundle ID -->
                            <string>com.example.targetapp</string>
                        </array>
                    </dict>
                </array>
            </dict>
            <key>UserDefinedName</key>
            <string>Target App Proxy</string>
            <key>VPNSubType</key>
            <string>com.example.targetapp.proxy</string>
            <key>VPNType</key>
            <string>VPN</string>
        </dict>
    </array>
</dict>
</plist>
```

### Swift Skeleton

```swift
import NetworkExtension

class TransparentProxy: NETransparentProxyProvider {
    override func startProxy(
        options: [String: Any]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let settings = NETransparentProxyNetworkSettings(
            tunnelRemoteAddress: "127.0.0.1"
        )

        // Rule: all TCP traffic goes through proxy
        settings.includedNetworkRules = [
            NENetworkRule(
                remoteNetwork: nil,
                remotePrefix: 0,
                localNetwork: nil,
                localPrefix: 0,
                protocol: .TCP,
                direction: .outbound
            )
        ]
        completionHandler(nil)
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let tcpFlow = flow as? NEAppProxyTCPFlow else { return false }
        tcpFlow.readData { data, error in
            // SOCKS5 handshake + forwarding logic
        }
        return true
    }
}
```

### Info.plist Key Fields

```xml
<key>NEProviderClasses</key>
<dict>
    <key>NETransparentProxyProvider</key>
    <string>$(PRODUCT_MODULE_NAME).TransparentProxy</string>
</dict>
```

---

## 4. `NEFilterDataProvider` — Kernel-Level Socket Filter

### How It Works

A system-level socket filter that intercepts sockets at creation time, filtering precisely by the process's bundle ID.

```swift
import NetworkExtension

class FilterDataProvider: NEFilterDataProvider {
    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let socketFlow = flow as? NEFilterSocketFlow else {
            return .allow()
        }

        let bundleId = socketFlow.sourceAppBundleIdentifier ?? "unknown"

        if bundleId == "com.target.app" {
            // Only intercept the target app's flows
            return .filterDataVerdict(
                withFilterInbound: false,
                peekInboundBytes: 0,
                filterOutbound: true,
                peekOutboundBytes: 0
            )
        }
        return .allow()  // Allow everything else
    }
}
```

**Pros:** Zero-config per-app proxy, system-level, kernel-mode execution.  
**Cons:** Requires NetworkExtension entitlement + system extension loading — far heavier than proxychains-ng.

---

## 5. `--proxy-server` — The Chromium/Electron Shortcut ⭐

### How It Works

For Electron/Chromium-based apps (VS Code, Discord, Slack, Figma, Codex, Notion, etc.), the built-in `--proxy-server` flag forces all network traffic through a proxy — no dylib injection, no kernel hooks, no sandbox tricks. It's been in Chromium since 2010.

```bash
/Applications/SomeApp.app/Contents/MacOS/SomeApp \
    --proxy-server="http://127.0.0.1:7898" \
    --proxy-bypass-list="<-loopback>"
```

`<-loopback>` is a Chromium built-in pattern that keeps localhost traffic direct (for app IPC).

**Why `HTTP_PROXY` env vars don't work:** Chromium ignores them — it uses its own Network Service, independent of libcurl/CFNetwork proxy resolution.

**Pros:** One flag, zero friction. Works on every Chromium app across macOS, Linux, and Windows.

> 💡 Wrapping this into a launch script (e.g., `codex-proxy`) gives you the same UX as the other approaches — one command, fire and forget. See [codex-gui-proxy](https://github.com/icyblazek/codex-gui-proxy) for the ready-to-use script.

---

## Quick Reference

| Approach | Layer | SIP Required? | Use Case | Cost |
|----------|-------|---------------|----------|------|
| `proxychains-ng` | User-mode dylib injection | Insensitive (third-party apps) | Quick single-app analysis | ⭐ Very low |
| PF + dedicated user | Kernel PF | Unrelated | Long-term stable operation | ⭐⭐ Low |
| `--proxy-server` | Chromium network stack | Unrelated | Any Electron/Chromium app | ⭐ Zero |
| Per-App VPN + MDM | NetworkExtension | Unrelated | Shippable product | ⭐⭐⭐⭐ High |
| `NEFilterDataProvider` | Kernel extension | Unrelated | Enterprise full-protocol | ⭐⭐⭐⭐⭐ Very high |

---

## Conclusion

**For Electron/Chromium apps:** Use `--proxy-server`. One flag, zero friction.

**For native macOS apps without Hardened Runtime:** `proxychains-ng` — no system changes, no traffic analysis needed, 3 minutes to deploy.

**For native macOS apps with Hardened Runtime:** You'll need the Per-App VPN + MDM route (or bite the bullet and re-sign with `allow-dyld-environment-variables`).

**For shipping a product:** Per-App VPN + MDM is the official, supportable path. Everything else is dev tools.
