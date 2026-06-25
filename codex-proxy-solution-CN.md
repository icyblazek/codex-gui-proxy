# Codex.app 强制代理实战：五次试错后的最终方案

> 作者：ICYBLAZK  
> 日期：2026-06-25  
> 标签：macOS, 代理, Electron, Chromium, 网络隔离

---

## 0. 需求

让 `/Applications/Codex.app`（OpenAI 出品的 AI 编程助手）的所有网络流量经过本地 V2Ray 代理（`127.0.0.1:7898`），系统其余流量不受影响。

Codex 是第三方闭源应用，不知道它具体访问哪些域名/IP。需要的是**按进程身份路由**，而非按目的地路由。

---

## 1. 方案一：proxychains-ng（3 分钟失败）

### 原理

通过 `DYLD_INSERT_LIBRARIES` 注入 `libproxychains4.dylib`，hook `connect()` 和 `getaddrinfo()`。目标进程所有 TCP 连接和 DNS 解析全部经由代理。

### 实施

```bash
brew install proxychains-ng
# 配置 ~/.proxychains/proxychains.conf → socks5 127.0.0.1:7897
proxychains4 /Applications/Codex.app/Contents/MacOS/Codex
```

### 结果：无效。代理完全没有生效。

### 诊断

```bash
codesign -dvvv /Applications/Codex.app
# flags=0x10000(runtime)   ← Hardened Runtime 开启

codesign -d --entitlements - /Applications/Codex.app
# 缺少 com.apple.security.cs.allow-dyld-environment-variables
```

**根因：** Codex 启用了 Hardened Runtime 且未声明 DYLD 环境变量授权。macOS 动态链接器**静默忽略** `DYLD_INSERT_LIBRARIES`，dylib 注入无效。

### 教训

`proxychains-ng` 依赖 `DYLD_INSERT_LIBRARIES`，这个机制对带有 Hardened Runtime 的应用（几乎所有第三方签名应用）失效。Apple 在 entitlements 中提供了 `com.apple.security.cs.allow-dyld-environment-variables` 开关，但很少有应用主动开启。

---

## 2. 方案二：PF + 专用用户（内核级，折戟）

### 原理

将目标应用运行在专用用户下，PF（Packet Filter）按 UID 匹配出站流量并重定向到本地透明代理。

### 设计

```bash
# 创建专用用户 _codexproxy (UID 502)
sudo dscl . -create /Users/_codexproxy UniqueID 502

# PF 规则设想
pass out proto tcp from any to any user 502 rdr-to 127.0.0.1 port 12345
```

### 结果：`pfctl -n` 报语法错误。

### 诊断

macOS 的 PF 来自 OpenBSD，但版本较老：

- `pass out ... user <uid>` ✅ 支持
- `pass out ... rdr-to` ❌ 不支持（OpenBSD 较新特性）
- `pass out ... divert-to` ❌ 也不支持
- `rdr` 规则不支持 `user` 匹配

**macOS PF 只能按 UID 做 `block`/`pass`，不能按 UID 做流量重定向。**

### 二层问题

即使 PF 重定向可行，还面临 GUI 应用的致命困难：

```bash
sudo -u _codexproxy /Applications/Codex.app/Contents/MacOS/Codex
# → 应用无法连接 WindowServer，GUI 渲染失败
```

macOS 的守护用户（无登录会话）无法启动 GUI 应用。`_codexproxy` 即便有合法 UID，也无法访问窗口服务器。

### 教训

- macOS PF 不是 OpenBSD PF，能力子集有限
- GUI 应用的网络隔离不能靠切换用户实现
- 这个方案只适用于纯 CLI 应用

---

## 3. 方案三：sandbox-exec（系统沙箱，死锁）

### 原理

macOS 的 `sandbox-exec` 提供进程级沙箱，可以精细控制网络权限。方案：

```scheme
(deny network-outbound)                              # 阻断所有出站
(allow network-outbound (remote ip "localhost:7898")) # 仅放行代理端口
```

### 实施

```bash
sandbox-exec -f codex-proxy.sb /Applications/Codex.app/Contents/MacOS/Codex
```

### v1 失败：`(deny network*)` 过激

Codex 启动时报错：

```
Failed to bind() SingletonSocket: Operation not permitted
Failed to create a ProcessSingleton
```

**根因：** `(deny network*)` 阻断了 Unix Domain Socket 的 `bind()`。Electron/Chromium 用 UDS 做进程单例锁（ProcessSingleton），被沙箱拦截后应用直接退出。

修复为 `(deny network-outbound)`——只阻断出站 TCP/UDP，不碰 Unix Socket。

### v2 失败：双重沙箱死锁

修复 UDS 问题后，Codex **能启动**，但立即崩溃：

```
sandbox initialization failed: Operation not permitted
Network service crashed, restarting...
GPU process exited unexpectedly: exit_code=6
GPU process isn't usable. Goodbye.
```

**根因：** Codex 是 Electron/Chromium 应用，**内部自带子进程沙箱**（renderer、GPU、network service 各自跑在独立沙箱中）。我们用 `sandbox-exec` 套上外层沙箱后，Chromium 的内层沙箱初始化被外层拒绝——形成**双重沙箱死锁**。

这是架构性冲突，无法绕过。Chromium 内核的沙箱初始化需要特定系统调用（`sandbox_init`、mach port 等），外层沙箱默认拦截了这些调用。

### 教训

- Chromium/Electron 应用不能套 `sandbox-exec`
- 沙箱嵌套是反模式——内层沙箱需要的能力外层不会给
- `sandbox-exec` 适用于原生 macOS 应用，不适用于自带沙箱的浏览器框架

---

## 4. 方案四：HTTP_PROXY 环境变量（表面成功，实则无效）

### 假设

Codex 是 Electron 应用，Electron 基于 Chromium。Linux/Unix 程序普遍尊重 `HTTP_PROXY`/`HTTPS_PROXY` 环境变量。

### 实施

```bash
export HTTP_PROXY="http://127.0.0.1:7898"
export HTTPS_PROXY="http://127.0.0.1:7898"
/Applications/Codex.app/Contents/MacOS/Codex &
```

### 结果：应用启动成功，界面加载不出来。代理未生效。

### 诊断

Chromium 在 macOS 上**不读取** `HTTP_PROXY` 环境变量。Chromium 的代理配置机制是：

1. macOS 系统代理设置（System Preferences → Network → Proxies）
2. `--proxy-server` 命令行参数
3. PAC 脚本（`--proxy-pac-url`）
4. 通过 Preferences JSON 文件写入

`HTTP_PROXY` 环境变量是 Unix/Linux 下的 libcurl 习惯，Chromium 根本不走这条路。

### 教训

环境变量代理对 GUI 应用不可靠。Electron/Chromium 使用自己的网络栈（Chromium Network Service），独立于系统的 libcurl/CFNetwork 代理解析。不同框架有不同的代理发现机制，没有统一标准。

---

## 5. 方案五：`--proxy-server`（正确方案，一次成功）

### 原理

`--proxy-server` 是 Chromium 的原生命令行参数，内置于 Chromium 网络栈。格式：

```
--proxy-server=<scheme>://<host>:<port>
--proxy-bypass-list=<pattern>
```

支持的 scheme：`http`、`socks4`、`socks5`、`quic`。

### 实施

```bash
/Applications/Codex.app/Contents/MacOS/Codex \
    --proxy-server="http://127.0.0.1:7898" \
    --proxy-bypass-list="<-loopback>"
```

`<-loopback>` 是 Chromium 内置模式，让本地回环地址绕过代理（Codex 组件间 IPC 走 localhost，不应走代理）。

### 结果：应用正常启动，所有 API 流量经由 V2Ray 代理。

### 为什么这次是对的

| 方案 | 层级 | 为何失败 |
|------|------|----------|
| proxychains-ng | 用户态 dylib | Hardened Runtime 拦截 |
| PF + 专用用户 | 内核 PF | macOS PF 能力不足 + GUI 无法跨用户 |
| sandbox-exec | 内核沙箱 | Chromium 内层沙箱冲突 |
| HTTP_PROXY 环境变量 | 进程环境 | Chromium 不读取 |
| **`--proxy-server`** | Chromium 网络栈 | ✅ 原生机制，零冲突 |

`--proxy-server` 是 Chromium 网络栈自己的代理接口，不需要 dylib 注入、不需要内核 hook、不涉及沙箱。

---

## 6. 最终产物

一个 15 行的启动脚本 `~/.local/bin/codex-proxy`：

```bash
#!/bin/bash
# Codex.app 代理启动器 —— Chromium --proxy-server 方案
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

使用方法：

```bash
codex-proxy
```

---

## 7. 方法论总结

### 失败路径图

```
需求：按进程身份路由流量
 │
 ├─[1] proxychains-ng ──→ Hardened Runtime 拦截
 │
 ├─[2] PF + 专用用户 ──→ PF 能力不足 + GUI 用户隔离不可行
 │
 ├─[3] sandbox-exec ────→ Chromium 沙箱冲突（双重沙箱）
 │
 ├─[4] HTTP_PROXY 环境变量 → Chromium 不读取
 │
 └─[5] --proxy-server ──→ ✅ 成功
```

### 核心教训

1. **先检查签名（codesign -dvvv），再选方案。** Hardened Runtime 会堵死 dylib 注入路线，发现时立刻放弃 `proxychains-ng`。

2. **macOS PF ≠ OpenBSD PF。** 不要假定 BSD 手册页上的特性 macOS 全都有。`user` 匹配只支持 `block`/`pass`，不支持 `rdr-to`。

3. **GUI 应用不能跨用户启动。** `sudo -u` 到非登录用户时，WindowServer 连接必然失败。

4. **Chromium 应用自带沙箱。** 不要在自带沙箱的应用上再套一层系统沙箱——内层沙箱需要的能力外层不会给。

5. **Chromium 不读 HTTP_PROXY。** `--proxy-server` 是唯一可靠的 Chromium 代理配置方式。

6. **每种框架有自己的代理发现机制。** libcurl 读环境变量，Chromium 读命令行参数或系统设置，NSURLSession 读系统代理设置。不存在大一统方案。

### 适用性

`--proxy-server` 方案适用于**所有基于 Chromium/Electron 的应用**：

- VS Code (`code --proxy-server=...`)
- Slack
- Discord
- Figma
- Notion
- 任何 Electron 套壳应用

Chromium 命令行参数的权威文档：`chrome://flags` 和 Chromium 源码 `content/public/common/content_switches.cc`。
