# macOS 强制代理方案——按进程身份路由

> 需求场景：不知道第三方应用的具体流量特征（域名 / IP / 端口），只希望**针对该 app** 走代理，系统其余流量不受影响。
>
> 核心思路：从"按目的地路由"切换到**"按进程身份路由"**。macOS 内核网络栈天然持有进程上下文（socket 创建时即知所属进程），只是上层 API 习惯用域名 / IP 匹配，容易把人带偏。
>
> **作者：ICYBLAZK**

---

## 一、`proxychains-ng`（最快上手，3 分钟搞定）

### 原理

通过 `DYLD_INSERT_LIBRARIES` + `DYLD_FORCE_FLAT_NAMESPACE` 注入 `libproxychains4.dylib`，hook 掉 `connect()` 和 `getaddrinfo()`。目标进程所有 TCP 连接 + DNS 解析（`proxy_dns` 开启时）全部经由代理，无 DNS 泄漏。

### 适用

99% 的第三方 GUI app（非 Apple 签名进程）。Apple 签名进程受 SIP 拦截，但第三方 app 恰是此方案的甜蜜区。

### 操作

```bash
# 安装
brew install proxychains-ng

# 配置 ~/.proxychains/proxychains.conf
cat > ~/.proxychains/proxychains.conf << 'EOF'
strict_chain
proxy_dns
[ProxyList]
socks5 127.0.0.1 1080
EOF

# 启动目标 app —— 只对它生效
proxychains4 /Applications/SomeApp.app/Contents/MacOS/SomeApp
```

### 验证

```bash
lsof -p $(pgrep AppName) | grep TCP
# 只会看到连接 127.0.0.1:1080
```

**优点**：不改系统、不需知道流量特征、随用随走。

---

## 二、PF + 用户级隔离

### 原理

将目标 app 运行在**专用用户**下，PF 按 `uid`/`gid` 匹配出站流量并重定向到本地透明代理。

### 操作

```bash
# 1. 创建代理专用用户
sudo dscl . -create /Users/proxyuser
sudo dscl . -create /Users/proxyuser UniqueID 501

# 2. PF 规则（/etc/pf.conf）
table <proxy_users> { 501 }
rdr pass on lo0 proto tcp from any to any -> 127.0.0.1 port 12345
pass out on en0 proto tcp from any to any user 501 rdr-to 127.0.0.1 port 12345

# 3. 启用 PF
sudo pfctl -E -f /etc/pf.conf

# 4. 以专用用户身份启动 app
sudo -u proxyuser /Applications/SomeApp.app/Contents/MacOS/SomeApp
```

**搭配透明代理**：

```bash
# mitmproxy 透明模式（支持 HTTPS）
mitmproxy --mode transparent --listen-port 12345
sudo sysctl -w net.inet.ip.forwarding=1
```

**优点**：内核级、无 dylib 注入依赖、SIP 无关。

---

## 三、Per-App VPN（NetworkExtension，正规军）

### 原理

macOS 10.15+ 原生支持 Per-App VPN。系统网络栈自动识别出站包所属 bundle，仅将指定 app 流量导入虚拟网卡。

### 限制

- 个人开发者需走 **MDM profile**（Apple Configurator 2 或自签 profile）
- 无 MDM 时只能做"全设备 VPN"，无法做 per-app VPN
- 需 `com.apple.developer.networking.networkextension` entitlement

### MDM Profile 示例（`perapp-vpn.mobileconfig`）

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
                            <!-- 目标 bundle ID -->
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

### Swift 端代码骨架

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

        // 规则：所有 TCP 流量走代理
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
            // SOCKS5 握手 + 转发逻辑
        }
        return true
    }
}
```

### Info.plist 关键字段

```xml
<key>NEProviderClasses</key>
<dict>
    <key>NETransparentProxyProvider</key>
    <string>$(PRODUCT_MODULE_NAME).TransparentProxy</string>
</dict>
```

---

## 四、`NEFilterDataProvider`——内核级 socket filter

### 原理

系统级 socket 过滤器，在 app 创建 socket 时拦截，可按进程 bundle ID 精准筛选。

```swift
import NetworkExtension

class FilterDataProvider: NEFilterDataProvider {
    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let socketFlow = flow as? NEFilterSocketFlow else {
            return .allow()
        }

        let bundleId = socketFlow.sourceAppBundleIdentifier ?? "unknown"

        if bundleId == "com.target.app" {
            // 仅拦截目标 app 的 flow
            return .filterDataVerdict(
                withFilterInbound: false,
                peekInboundBytes: 0,
                filterOutbound: true,
                peekOutboundBytes: 0
            )
        }
        return .allow()  // 其余放行
    }
}
```

**优点**：零配置 per-app 代理、系统级、内核态执行。  
**缺点**：需 NetworkExtension entitlement + 系统扩展加载，比 proxychains-ng 重得多。

---

## 方案速查

| 方案 | 层级 | SIP 要求 | 适用场景 | 实现成本 |
|------|------|----------|----------|----------|
| `proxychains-ng` | 用户态 dylib 注入 | 不敏感（第三方 app） | 快速分析单个 app | ⭐ 极低 |
| PF + 专用用户 | 内核 PF | 不关 | 长期稳定运行 | ⭐⭐ 低 |
| Per-App VPN + MDM | NetworkExtension | 不关 | 可发布产品 | ⭐⭐⭐⭐ 高 |
| `NEFilterDataProvider` | 内核扩展 | 不关 | 企业级全协议 | ⭐⭐⭐⭐⭐ 极高 |

---

## 结论

**90% 的场景用 `proxychains-ng`**：不改系统、不需要知道目标 app 流量特征、3 分钟上线。剩下 10% 是企业分发 or 需要产物化的场景，走 Per-App VPN + MDM 正规路线。
