# jlink-remote-bridge

> 老 J-Link 在 Windows ARM64 上装不了驱动。把探针挂在 macOS/Linux 上，用 IP 借给虚拟机里的 Keil —— 用起来跟插在本机一样。

## 怎么用

**① 开始**（探针插在宿主机的 USB 上，然后执行）

```bash
./jlink-remote-server.sh start
```

看到这两行就成了：

```
2026-09-28 13:32:25 - Connected to J-Link with S/N 20090928
2026-09-28 13:32:25 - Waiting for client connections...
```

之后直接在 Keil 里烧录 / 调试，不用每次重新配置。

**② 结束**（用完关掉）

```bash
./jlink-remote-server.sh stop
```

端口 19020（给 Keil 用的）和 19080（J-Link 自带的网页面板）会**一起释放**。

**③ 其他两条**

```bash
./jlink-remote-server.sh status   # 在跑吗
./jlink-remote-server.sh ip       # 该在 IDE 里填哪个 IP
```

> 这个服务**不常驻、不开机自启** —— 干活时 `start`，收工 `stop`，就这两条命令。

## 首次配置：Keil 里填一次 IP

只做一次，之后那个工程就不用再碰了。

`Options for Target`（魔术棒）→ **Debug** → 右边的调试器下拉框选 **`Cortex-M/R J-LINK/J-Trace`** → 点 **Settings**：

1. `Port` 选 **SW**，点 **Auto Clk**
2. 找到 **Interface and TCP/IP** 区域（通常在窗口左下部）→ 选 **TCP/IP**
3. **IP** 填 `./jlink-remote-server.sh ip` 查到的宿主地址；**Port** 填 `0`
4. 点 **Connect** → 信息区出现 `S/N` 和 `Hardware version` 就是成功
5. 切到 **Flash Download** 页确认 Flash 算法在（一般本来就有）→ **OK** 保存

三个容易踩的点：

- 选了 TCP/IP 后 **Keil 不会自动扫 IP**，必须手填 + 点 Connect，它不会自己发现。
- **Port 只能填 `0` 或 `19020`**，填别的连不上。
- 设置存在工程文件（`.uvoptx`）里 —— 换工程要重填，同一个工程不用。

## 三条铁律（踩过才写的）

1. **探针只能归一台机器。** 千万不要把 J-Link 直通给虚拟机 —— 一旦直通，宿主机就看不到探针，整条链路立刻断（日志刷 `Cannot connect to J-Link`）。放回宿主机后服务会**自动重连**，不用重启。
2. **服务在跑的时候，宿主机本机 `JLinkExe` 看不到探针** —— 这是正常的，USB 被服务独占了，不是故障。
3. **`localhost:19080` 那个网页控制面板不用管。** 它是 J-Link DLL 自带的模块（不是独立程序，没有开关能单独禁用），只绑 `127.0.0.1`，虚拟机和外网都碰不到。要它消失就 `stop`。

## 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| IDE 报 `Cannot connect to J-Link via TCP/IP` | 服务没在跑 → `./jlink-remote-server.sh status`；或探针又被直通给虚拟机了 |
| 宿主本机 `JLinkExe` 看不到探针 | **正常** —— USB 被服务独占 |
| 探针拔过 / 重插 | 重启一次服务（`stop` 再 `start`） |
| 对方机器连不上 | 在对方机器上跑 `Test-NetConnection <宿主IP> -Port 19020`，确认返回 True |
| 宿主 IP 变了 | `./jlink-remote-server.sh ip` 重查，改 IDE 里的 IP |
| 能连上但下载报 flash 错误 | 检查 Flash 算法是否与芯片容量匹配 |

更多实测踩坑记录见 [`docs/PITFALLS.md`](docs/PITFALLS.md)。

## 原理

macOS / Linux 用的是**系统自带的通用 USB 栈**，探针不需要任何厂商驱动就能用 —— 所以在宿主机上一切正常。把探针留在宿主机，把它**通过网络借出去**即可：

```
┌────────────┐  USB   ┌──────────────────────┐  TCP 19020  ┌─────────────────────────┐
│ J-Link     │───────>│ macOS / Linux        │────────────>│ Windows ARM64 虚拟机     │
│ (老探针)   │        │ JLinkRemoteServer    │             │ Keil µVision (LAN 模式) │
└────────────┘        └──────────────────────┘             └─────────────────────────┘
```

Keil MDK 官方支持 J-Link 的 **LAN 模式**远程调试（只不支持 tunnel 模式）。

### 为什么不能在 Windows ARM64 上直接修

在 Windows ARM64（含 VMware Fusion / Parallels 里的 Win11 ARM 虚拟机）里插上老一代 J-Link，设备管理器里永远是那个黄色感叹号：

| 现象 | 实测值 |
|---|---|
| `Get-PnpDevice` | `Status: Error` |
| `DEVPKEY_Device_ProblemCode` | `28`（`CM_PROB_FAILED_INSTALL`） |
| `Service` / `DriverInfPath` / `DriverVersion` | 全空 —— 没有任何驱动绑定 |
| 手动指向 SEGGER 安装目录装驱动 | `Windows was unable to install your J-Link` |

**这不是配置问题，是架构问题。** SEGGER 的老驱动是**内核态** `.sys`，只有 x86/x64 版本；Windows ARM64 能模拟 x64 **用户态**程序，但**内核驱动不能模拟** —— 所以重装软件、手动指定 INF、改注册表统统无效。

只有硬件支持 **WinUSB 模式**的探针才可能直连（设备兼容 ID 里会出现 `USB\MS_COMP_WINUSB`）。而 2012 年前后那批（HW V7.00）、SAM-ICE 之类的 OEM 贴牌件一律**不支持**，且改这个模式还必须在一台**非 ARM64** 的机器上做。

**所以对老探针来说，远程桥接不是"绕路"，而是唯一可行的路。**

## 安装（只做一次）

**宿主机装 SEGGER 软件包：**

```bash
# macOS
brew install --cask segger-jlink
# Linux：从官网下 DEB / TGZ
```

> ⚠️ **该 cask 目前经常装不上**：SEGGER 官网用 AWS WAF 拦非浏览器请求，`curl`/`brew` 拿到的是 0 字节，报 `Cask reports different checksum`。
> 变通办法：用浏览器到 <https://www.segger.com/downloads/jlink/> 手动下载 pkg 安装。

**确认探针能被识别：**

```bash
JLinkExe -CommanderScript <(printf 'ShowEmuList\nexit\n')
# J-Link[0]: Connection: USB, Serial number: 20090928, ProductName: SAM-ICE
```

`ProductName` 会暴露真实型号（`SAM-ICE` 是 Atmel 贴牌 J-Link）。顺带说：SAM-ICE 调 STM32 实测没问题，不受 Atmel 授权限制。

## 脚本与配置

| 文件 | 用途 |
|---|---|
| `jlink-remote-server.sh` | `start` / `stop` / `status` / `ip` —— 把本机探针通过 IP 暴露出去 |
| `wsh` | 把本地 PowerShell 脚本灌进远程 Windows 主机执行（见下） |

### `.env`（可选）

两个脚本都会读**脚本同目录**的 `.env`（键见 `.env.example`）。真实环境变量**优先于** `.env`：

```bash
JLINK_SN=123456789 ./jlink-remote-server.sh start
WSH_TARGET=user@host ./wsh check.ps1
```

两个脚本都是用户态脚本，直接读 `.env`。需要 `sudo` 的操作**不要**把配置放进 `.env` —— 让 root 去 source 一个用户可写的文件是提权隐患。

### 关于 `wsh`

直接 `ssh win 'powershell -c "..."'` 会同时踩三个坑：

1. **引号地狱** —— 嵌套两层以后基本不可维护；
2. **编码** —— 非 ASCII 会被按本地代码页（GBK）解码成乱码；
3. **重定向** —— 脚本里的 `2>/dev/null` 会被远程 PowerShell 自己解析成 `Out-File C:\dev\null` 并报错。

`wsh` 把脚本转成 UTF-16LE base64 用 `powershell -EncodedCommand` 执行，一次绕过全部三个问题。

## License

MIT
