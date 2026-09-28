# jlink-remote-bridge

> 老 J-Link 在 Windows ARM64 上装不了驱动？把探针挂在 macOS/Linux 上，用 IP 借给虚拟机里的 Keil。

## 问题

在 Windows ARM64（含 VMware Fusion / Parallels 里的 Win11 ARM 虚拟机）里插上老一代 J-Link，设备管理器里永远是那个黄色感叹号：

| 现象 | 实测值 |
|---|---|
| `Get-PnpDevice` | `Status: Error` |
| `DEVPKEY_Device_ProblemCode` | `28`（`CM_PROB_FAILED_INSTALL`） |
| `Service` / `DriverInfPath` / `DriverVersion` | 全空 —— 没有任何驱动绑定 |
| 手动指向 SEGGER 安装目录装驱动 | `Windows was unable to install your J-Link` |

**这不是配置问题，是架构问题，在 ARM64 侧无解。**

SEGGER 的老驱动是**内核态** `.sys`，只有 x86/x64 版本。Windows ARM64 能模拟 x64 **用户态**程序，但**内核驱动不能模拟** —— 所以在 Windows ARM64 上重装软件、手动指定 INF、改注册表统统无效。

只有硬件上支持 **WinUSB 模式**的探针才可能直连（此时设备兼容 ID 里会出现 `USB\MS_COMP_WINUSB`）。而 2012 年前后那批（HW V7.00）、SAM-ICE 之类的 OEM 贴牌件一律**不支持**，且改这个模式还必须在一台**非 ARM64** 的机器上做。

## 原理

macOS / Linux 上完全没有这个问题 —— 它们用的是**系统自带的通用 USB 栈**，探针不需要任何厂商驱动就能用。所以：

```
┌────────────┐  USB   ┌──────────────────────┐  TCP 19020  ┌─────────────────────────┐
│ J-Link     │───────>│ macOS / Linux        │────────────>│ Windows ARM64 虚拟机     │
│ (老探针)   │        │ JLinkRemoteServer    │             │ Keil µVision (LAN 模式) │
└────────────┘        └──────────────────────┘             └─────────────────────────┘
```

探针留在能识别它的机器上，把它**通过网络借出去**。Keil MDK 官方支持 J-Link 的 **LAN 模式**远程调试（只不支持 tunnel 模式），用起来跟插在本机一样。

## 快速开始

### 1. 宿主侧（macOS / Linux）：装上 SEGGER 软件包

```bash
# macOS
brew install --cask segger-jlink
# Linux：从官网下 DEB / TGZ
```

> ⚠️ **该 cask 目前经常装不上**：SEGGER 官网用 AWS WAF 拦非浏览器请求，`curl`/`brew` 拿到的是 0 字节，报 `Cask reports different checksum`。
> 变通办法：用浏览器到 <https://www.segger.com/downloads/jlink/> 手动下载 pkg 安装。

### 2. 宿主侧：确认探针能用

```bash
JLinkExe -CommanderScript <(printf 'ShowEmuList\nexit\n')
# J-Link[0]: Connection: USB, Serial number: 20090928, ProductName: SAM-ICE
```

`ProductName` 会暴露真实型号（比如 `SAM-ICE` 是 Atmel 贴牌 J-Link）。顺便说一句：SAM-ICE 调 STM32 实测没问题，不受 Atmel 授权限制。

### 3. 宿主侧：启动远程服务

```bash
cp .env.example .env      # 按需改（.env 已被 gitignore）
./jlink-remote-server.sh start

# 查到对方机器该填的 IP
./jlink-remote-server.sh ip
```

日志出现 `Waiting for client connections...` 就是好了。

### 4. IDE 侧：Keil µVision 配置

`Options for Target` → **Debug** → 勾 `Use` 并选 `Cortex-M/R J-LINK/J-Trace` → **Settings**：

- `Port` 选 **SW**，点 `Auto Clk`
- 在 **Interface and TCP/IP** 区域选 **TCP/IP**
- IP 填第 3 步查到的地址，`Port number` 填 `0`（走 J-Link 标准端口）或 `19020`
- 点 **Connect**

> 选中 TCP/IP 后驱动**不会**自动扫 IP，必须手动填 + 点 Connect。
> 这些设置**保存在工程文件里**（`.uvoptx`），同一个工程下次开箱即用。

## 脚本

| 脚本 | 用途 |
|---|---|
| `jlink-remote-server.sh` | `start` / `stop` / `status` / `ip` —— 把本机探针通过 IP 暴露出去 |
| `wsh` | 把本地 PowerShell 脚本灌进远程 Windows 主机执行（详见下方说明） |
| `segger-links.sh` | `list` / `check` / `minimal` / `restore` —— 精简 `/usr/local/bin` 里 SEGGER 铺的四十多个软链（**需 sudo**） |
| `segger-apps.sh` | `list` / `check` / `minimal` / `restore` —— 收起 `/Applications/SEGGER` 里用不到的 GUI `.app`（**需 sudo**） |

两个 `segger-*.sh` 都是**先备份、再动手**，且 `check` 模式只打印不改文件；`restore` 可完整回滚。收起 `.app` 用的是"移进以点开头的隐藏目录"而非删除 —— Launchpad / Spotlight 不索引点开头目录，图标消失但文件还在。

### 配置：`.env`

`jlink-remote-server.sh` 和 `wsh` 会读脚本同目录的 `.env`（键见 `.env.example`）。
真实环境变量**优先于** `.env`，所以临时覆盖这样写：

```bash
JLINK_SN=123456789 ./jlink-remote-server.sh start
WSH_TARGET=user@host ./wsh check.ps1
```

`segger-links.sh` / `segger-apps.sh` **故意不读 `.env`** —— 它们以 `sudo` 运行，让 root 去 source 一个用户可写的文件是提权隐患。

### 关于 `wsh`

直接 `ssh win 'powershell -c "..."'` 会同时踩三个坑：

1. **引号地狱** —— 嵌套两层以后基本不可维护；
2. **编码** —— 非 ASCII 会被按本地代码页（GBK）解码成乱码；
3. **重定向** —— 脚本里的 `2>/dev/null` 会被远程 PowerShell 自己解析成 `Out-File C:\dev\null` 并报错。

`wsh` 把脚本转成 UTF-16LE base64 用 `powershell -EncodedCommand` 执行，一次绕过全部三个问题。

## 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| IDE 报 `Cannot connect to J-Link via TCP/IP` | 远程服务没在跑 → `./jlink-remote-server.sh status` |
| 宿主本机 `JLinkExe` 突然看不到探针了 | **正常** —— USB 被 Remote Server 独占 |
| 探针拔过 / 重插 | 重启一次远程服务 |
| 对方机器连不上 | 在对方机器上 `Test-NetConnection <host> -Port 19020`（Windows）；确认宿主防火墙放行该端口 |
| 宿主 IP 变了 | 用 `./jlink-remote-server.sh ip` 重查，改 IDE 里的 IP |

更多实测踩坑记录见 [`docs/PITFALLS.md`](docs/PITFALLS.md)。

## 关于"能不能直接切 WinUSB 模式"

理论上如果探针硬件支持，把它切到 WinUSB 就不用这么绕了。但这条路有两道门：

1. **硬件得支持** —— WinUSB 是较新型号才有的能力（例：J-Link EDU 要 Mini V2 起）；
2. **切换必须在非 ARM64 机器上做** —— 用 J-Link Configurator 的 `USB Driver (Windows)` 项，在 ARM64 上连驱动都装不上，自然也没法改。

所以对老探针来说，远程桥接不是"绕路"，而是**唯一可行的路**。

## License

MIT
