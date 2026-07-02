<p align="center">
  <img src="https://img.shields.io/badge/平台-macOS%2014%2B-lightgrey?style=flat-square">
  <img src="https://img.shields.io/badge/协议-MIT-blue?style=flat-square">
  <img src="https://img.shields.io/badge/依赖-零-brightgreen?style=flat-square">
  <img src="https://img.shields.io/badge/代码-15%20行-ff69b4?style=flat-square">
</p>

<p align="center">
  <b>中文</b> &nbsp;|&nbsp; <a href="README.md">English</a>
</p>

# codex-gui-proxy

> **一行命令，让 macOS 上任意 Electron 应用走代理。不碰内核，不需要重签名，不需要沙箱。**

```bash
codex-proxy
```

---

## 这个项目解决什么问题？

macOS 下给单个应用设代理，比你想象的要棘手得多。你以为 `HTTP_PROXY` 环境变量能搞定，或者 `proxychains` 能搞定。其实都不能。

| 方案 | 失败原因 |
|------|----------|
| `proxychains-ng` | Hardened Runtime 静默丢弃 `DYLD_INSERT_LIBRARIES` |
| PF + 专用用户 | macOS PF 不支持 `rdr-to`；GUI 应用无法以守护用户身份启动 |
| `sandbox-exec` | Chromium 自带沙箱与外层沙箱死锁 |
| `HTTP_PROXY` 环境变量 | Chromium 直接无视——它用自己的网络栈 |

最终答案？Chromium 自带一个命令行参数，一直都有：

```
--proxy-server=<url>
```

就这一行。本项目把这个参数封装成了一个 15 行的 shell 脚本。

---

## 快速开始

```bash
# 1. 下载
curl -o ~/.local/bin/codex-proxy https://raw.githubusercontent.com/icyblazek/codex-gui-proxy/main/codex-proxy.sh
chmod +x ~/.local/bin/codex-proxy

# 2. 运行
codex-proxy
```

默认代理：`http://127.0.0.1:7898`（V2Ray / Clash 默认 HTTP 入站端口）。  
要改端口，编辑脚本或设置环境变量：

```bash
CODEX_PROXY_URL=socks5://127.0.0.1:1080 codex-proxy
```

---

## 原理

```
┌─────────────────────────────────────┐
│  Codex.app（Electron / Chromium）   │
│                                     │
│  --proxy-server=http://127.0.0.1:7898
│         │                           │
│         ▼                           │
│  ┌──────────┐     ┌──────────────┐  │
│  │  V2Ray   │────▶│  互联网      │  │
│  │  :7898   │     │  （走代理）   │  │
│  └──────────┘     └──────────────┘  │
│                                     │
│  直接连接 → 被代理接管               │
└─────────────────────────────────────┘
```

Chromium 网络栈原生支持 `--proxy-server`，无需 dylib 注入、无需内核 hook、无需嵌套沙箱。这个参数从 Chromium 2010 年就已经存在。

---

## 特性

- **零依赖** —— 只用了 macOS 自带的 `curl`、`bash`、`nc`
- **15 行逻辑** —— 30 秒就能读完
- **配置文件支持** —— `.env` 文件或 `~/.codex-proxy-launcher.env` 持久化配置
- **重复启动检测** —— 如果 Codex 已运行会提示先退出再启动
- **支持 SOCKS5** —— `socks5://127.0.0.1:1080` 直接可用
- **IPC 安全** —— `--proxy-bypass-list="<-loopback>"` 保证本地流量直连
- **健康检查** —— 启动前检测代理端口是否在监听
- **后台启动** —— `nohup` 启动，打印 PID

---

## 安装

### 方法一：一行命令

```bash
curl -sSL https://raw.githubusercontent.com/icyblazek/codex-gui-proxy/main/codex-proxy.sh | bash
```

### 方法二：手动安装

```bash
mkdir -p ~/.local/bin
curl -o ~/.local/bin/codex-proxy https://raw.githubusercontent.com/icyblazek/codex-gui-proxy/main/codex-proxy.sh
chmod +x ~/.local/bin/codex-proxy

# 如果 ~/.local/bin 不在 PATH 里
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### 方法三：Git 克隆

```bash
git clone https://github.com/icyblazek/codex-gui-proxy.git
ln -s "$(pwd)/codex-gui-proxy/codex-proxy.sh" ~/.local/bin/codex-proxy
chmod +x codex-gui-proxy/codex-proxy.sh
```

---

## 配置

### 推荐：配置文件

创建 `~/.codex-proxy-launcher.env`（脚本更新也不丢失配置）：

```bash
cp codex-proxy-launcher.env.example ~/.codex-proxy-launcher.env
nano ~/.codex-proxy-launcher.env
```

```env
CODEX_PROXY_HOST=127.0.0.1
CODEX_PROXY_PORT=7898
```

配置文件读取顺序（先读到的值优先）：

| 优先级 | 路径 | 用途 |
|--------|------|------|
| 1 | `$CODEX_PROXY_CONFIG` | 指定路径 |
| 2 | `./codex-proxy-launcher.env` | 工作目录 |
| 3 | `~/.codex-proxy-launcher.env` | 用户级（推荐） |

### 备选：命令行 / 环境变量

```bash
# 命令行参数
codex-proxy --proxy-url socks5://127.0.0.1:1080

# 环境变量
CODEX_PROXY_URL=http://127.0.0.1:7890 codex-proxy
```

支持的协议：`http`、`https`、`socks4`、`socks5`、`quic`。

---

## 使用

```bash
codex-proxy                                    # 使用默认代理
codex-proxy --proxy-url socks5://127.0.0.1:1080   # 指定代理
codex-proxy --help                             # 查看帮助
```

输出示例：

```
[codex-proxy] 启动 Codex --proxy-server=http://127.0.0.1:7898
[codex-proxy] 运行中 — PID 42991
```

### 验证代理生效

```bash
# 查看 Codex 的 TCP 连接——应该只有指向代理端口的
lsof -p $(pgrep -f 'Codex.app/Contents/MacOS/Codex') -i TCP
```

预期输出：只有到 `127.0.0.1:7898`（或你的代理端口）的连接。

---

## 兼容性

经测试，以下 Chromium/Electron 应用均可使用：

| 应用 | 命令 |
|------|------|
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

## 故障排查

<details>
<summary>Codex 已经在运行</summary>

启动器检测到已有 Codex 进程在运行，拒绝启动第二个实例。
完全退出 Codex（Cmd+Q），然后重新运行 `codex-proxy`，新实例才会继承代理设置。

```bash
# 必要时强制退出
pkill -x Codex
codex-proxy
```
</details>

<details>
<summary>提示 <code>WARNING: proxy unreachable</code></summary>

代理没启动，或者端口不对。验证：

```bash
curl --proxy http://127.0.0.1:7898 https://httpbin.org/ip
```

如果这条命令失败，先启动你的代理（V2Ray / Clash / Surge）。
</details>

<details>
<summary>界面加载不出来 / 白屏</summary>

`--proxy-bypass-list` 可能太激进了。去掉它试试：

```bash
/Applications/Codex.app/Contents/MacOS/Codex --proxy-server="http://127.0.0.1:7898"
```

如果这样能正常工作，说明目标应用的本地 IPC 需求超出了 `<-loopback>` 范围。
</details>

<details>
<summary>应用启动即崩溃</summary>

检查代理 URL 格式。协议前缀是必须的：

✅ `http://127.0.0.1:7898`  
✅ `socks5://127.0.0.1:1080`  
❌ `127.0.0.1:7898`（缺少 `http://`）
</details>

<details>
<summary>需要用户名密码认证的代理怎么用？</summary>

```
--proxy-server="http://用户名:密码@代理地址:端口"
```

注意：命令行参数中的密码对同机器的其他进程可见。
</details>

---

## 常见问题

**Q：为什么不直接在 macOS 系统设置里配代理？**

A：那样会把**所有**流量都走代理。本项目做的是**按应用**代理——只有 Codex（或你指定的应用）走代理。

**Q：Linux 上能用吗？**

A：可以。Chromium 的 `--proxy-server` 是跨平台的。Linux 下很多应用还额外支持 `HTTP_PROXY` 环境变量，选择更多。

**Q：Apple Silicon（M1/M2/M3）兼容吗？**

A：原生支持，不需要 Rosetta。

**Q：不用 Codex，用在别的应用上行吗？**

A：改 `CODEX_BIN` 为任意 Electron 应用的二进制路径即可。见上方[兼容性](#兼容性)表格。

---

## 参考资料

- [Chromium 网络设置文档](https://www.chromium.org/developers/design-documents/network-settings/)
- [`chrome://flags`](chrome://flags) — 搜索 "proxy" 查看所有代理相关标记
- [Chromium 源码：`content/public/common/content_switches.cc`](https://source.chromium.org/chromium/chromium/src/+/main:content/public/common/content_switches.cc)

完整排查过程见：[codex-proxy-solution.md](codex-proxy-solution.md)

---

## 协议

MIT © [ICYBLAZK](https://github.com/ICYBLAZK)
