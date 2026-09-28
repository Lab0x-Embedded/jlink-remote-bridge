# 实测踩坑记录

都是真机上踩出来的，不是推测。按主题分组。

## 诊断：怎么确认是"架构问题"而不是配置问题

```powershell
Get-PnpDevice -PresentOnly | Where-Object Status -ne 'OK' |
  Select-Object Status, Class, FriendlyName, InstanceId

Get-PnpDeviceProperty -InstanceId 'USB\VID_1366&PID_0101\0002009028' -KeyName `
  DEVPKEY_Device_ProblemCode, DEVPKEY_Device_Service, `
  DEVPKEY_Device_DriverInfPath, DEVPKEY_Device_HardwareIds, DEVPKEY_Device_CompatibleIds
```

关键读法：

- `ProblemCode = 28` 是 `CM_PROB_FAILED_INSTALL`，`Service` / `DriverInfPath` 全空 = 压根没有驱动匹配上。
- **兼容 ID 是判断"能不能直连"的关键**：
  - 出现 `USB\MS_COMP_WINUSB` → 设备在 WinUSB（driverless）模式，Windows ARM64 有可能直连；
  - 只有 `USB\COMPAT_VID_XXXX&Class_FF&SubClass_FF&Prot_FF` → 厂商自定义类，仍工作在厂商专有驱动模式。

## 探针身份：别只看"J-Link"

USB 描述符里产品名就是 `J-Link`，PID `0x0101`，看不出所以然。真正暴露身份的是 J-Link 软件自己的输出：

```bash
JLinkExe -CommanderScript <(printf 'ShowEmuList\nexit\n')
# J-Link[0]: Connection: USB, Serial number: 20090928, ProductName: SAM-ICE
```

`SAM-ICE` 是 Atmel 贴牌版 J-Link。**同理，调试输出里的 `Hardware version` 和固件编译日期才是判断"支不支持 WinUSB"的依据**（WinUSB 是较新硬件才有的能力）。
同一根探针用 `connect` 连一次还能顺带读出 `License(s)` 和 `VTref`：

```bash
JLinkExe -device STM32F407ZG -if SWD -speed 4000 -CommanderScript <(printf 'connect\nexit\n')
```

## macOS / Linux 侧

- **`ipconfig getifaddr bridge101` 对 bridge 接口无效**（直接返回空）。查 VM 网段的宿主地址要用 `ifconfig` 解析，别用 `ipconfig`。
- **SEGGER 官网对脚本请求是硬拦**：`curl` 无论怎么伪装都拿不到包（返回 202/405 带 AWS WAF 的 "Human Verification" 页面），Homebrew cask 也因此装不上（0 字节 → 校验和不符）。**唯一可靠途径是浏览器手动下载**。所以：不要对 SEGGER 的安装做不可逆操作。
- **`/usr/local/bin` 是 `root:wheel`**，删除/新建软链必须 `sudo`。自动化流程里如果没法输入密码，就把命令交给使用者执行。
- **别裸跑 `JLinkExe` / `JLink.exe`**（不带任何参数）—— 它进入交互模式读 stdin，在脚本里会**永久挂住**。一律用 `-CommanderScript` 或 `-CommandFile`。
- 杀远程服务用**精确匹配**：
  ```bash
  pkill -f "JLinkRemoteServerCLExe -Port 19020"      # 对
  pkill -f jlink                                     # 错，会误杀自己的查询进程
  ```

## Windows 客机侧

- **公钥位置**：管理员账号的免密登录，OpenSSH 默认读 `C:\ProgramData\ssh\administrators_authorized_keys`（`sshd_config` 里 `Match Group administrators` 那段），**不是**用户自己目录下的 `authorized_keys`。而且 `authorized_keys` 的 ACL 必须收紧（去掉继承，只留 当前用户/SYSTEM/Administrators），否则 sshd 会**静默忽略**它。
- **装不上 SSH 的头号原因是没装 OpenSSH.Server 本体**：
  ```powershell
  Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
  ```
  `Get-Service sshd` 返回空就是服务不存在，不是权限问题。可选功能装不上时再退到 ARM64 MSI。
- **端口探测"连接超时"而非"拒绝"**，通常是 Windows 防火墙在丢包 → 服务没起或规则没生效。加规则时用 `-Profile Any`，避免 VM 网络被归类为 Public 而被拦。
- **写 PowerShell 脚本时**：用 `$ProgressPreference = 'SilentlyContinue'` 去掉 CLIXML 噪音；输出前加
  ```powershell
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
  ```
  否则中文回来是乱码。

## 经由 SSH 执行 PowerShell 的三个坑（`wsh` 存在的原因）

1. **引号地狱**：`ssh host "powershell -c \"...\""` 嵌套两层后基本不可维护。
2. **编码**：脚本正文会被按本地代码页（GBK）解码，中文标签变乱码；输出侧同样。
3. **重定向被劫持**：命令尾部的 `2>/dev/null` 会被**远程 PowerShell 自己**解析成 `Out-File C:\dev\null`，报 `DirectoryNotFoundException`。

解法：`iconv -f UTF-8 -t UTF-16LE | base64` + `powershell -EncodedCommand`。

## 内容整理的坑

- **`.env` 光写进 `.gitignore` 不算数**：提交前要用 `git check-ignore -v .env` 实测确认，否则 `.env` 很容易跟着第一次提交一起上去。
- **不要抽公共 `lib.sh`**：这类工具最常见的使用方式是 `cp 单个脚本 ~/bin/`。一旦脚本依赖同目录的 lib，单独拷出去就废了。宁可每个脚本自包含。
- **`sudo` 脚本不要 source 用户可写的配置**：谁都能往 `.env` 里塞一行然后等你 `sudo`。这是提权隐患，不是洁癖。
- **macOS 自带 bash 是 3.2**：不能用 `${!var}` 间接取值，要 `eval "cur=\${$k:-}"` 兜。

## J-Link 远程相关的行为特点

- 客户端 / 服务端**版本不一致不影响**（实测 V7.96 客户端 ↔ V9.80 服务端正常工作）。
- 服务运行期间，**宿主本机的 `JLinkExe` 看不到探针**（USB 被独占）—— 这是正常的，不是故障。
- 客户端连接串是 `IP <host>`，也可以在 Commander 里直接敲这个命令。
- Keil MDK 只支持 J-Link 的 **LAN 模式**，不支持 tunnel 模式（tunnel 会报 `Cannot connect to J-Link via TCP/IP`）。
