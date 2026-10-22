# dsh-mobile-watch

> DSH bundle：每次启动 DSH（不管用什么方式启动）自动检查手机端访问服务，缺了就重建并把新链接发到邮箱。

[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

---

## 作用

把一个「手机访问 DSH」的服务做成**自愈**的：

1. **任何方式启动 DSH 都会触发**——双击桌面图标、右键打开、任务栏、Win+R、命令行、被其他程序拉起，全部覆盖。因为触发点挂在 **profile 的 bundle 装载**上，而不是快捷方式或计划任务。
2. **只在真的坏了的时候动作**——端口在听、隧道活着，就什么都不做（不换域名、不发邮件、不写日志）。
3. **重建完成后自动把新链接发到邮箱**——手机 QQ/邮箱收到通知，点开就能用。

## 使用场景

### 适合

- **家里宽带是 CGNAT、没有公网 IP**，没法直接端口映射/DDNS 的场景（国内移动宽带普遍如此）。
- **电脑常开**，人在外面（通勤、上班、床上）想用手机接着干电脑上的活：写代码、跑命令、看日志。手机只是"输入/查看端"，真正干活的是电脑。
- **不想装 VPN / 客户端**：手机浏览器打开链接就行，不用 Tailscale、不用装 App。
- **能接受"每次重建换一个链接"**：链接通过邮件自动送达，点开即用。
- 已经有 **DSH web profile** 在跑（本插件只负责"检查 + 重建 + 通知"，不产生 UI）。

### 不适合

- 需要**永久固定域名**（`dsh.example.com` 那种）——请改用 Cloudflare 命名隧道 + 自己的域名，或 DDNS。
- **手机端要离线/本地跑 agent** —— 本方案只是把界面搬到手机，算力仍在电脑。
- **不允许电脑对公网暴露任何端口** —— 虽然是 Cloudflare 隧道 + token 鉴权，但链接本身等于控制权。
- **非 Windows** 机器（脚本用了 `Get-NetAdapter` / `wscript` / WMI 查询）。
- 想用手机**同时和电脑操作同一个会话** —— 两端共用会话库，建议同一时间只在一端输入。

## 效果

```
你双击 DSH（或任何方式启动）
  → DSH 正常打开（插件只花一次 CreateProcess，不影响启动速度）
  → 20 秒后检查手机端服务
      ├─ 健康：静默退出
      └─ 缺失：重建 Cloudflare 隧道 + dsh web 实例
               → 发邮件：新的公网链接 + 局域网链接
```

适合这样的场景：**电脑常开、人在外面想用手机接着干活**，但家里宽带没有公网 IP（CGNAT），只能用临时隧道；而隧道进程每次重启 DSH 都会断，链接也每次都变。

## 搭配使用（依赖 / 配套插件）

本插件**只做“检查 + 重建 + 通知”**，它不自己提供手机界面。完整可用需要下面这些：

### 必需

| 组件 | 作用 | 说明 |
|---|---|---|
| **DSH**（含 web profile） | 提供手机访问的那个网页实例 | 用 `dsh --profile web --port 3081 ...` 启动；DSH 自带 `@deepseek-ai/dsh-web-app` |
| **cloudflared** | 打公网隧道（免注册 quick tunnel） | [下载](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/)；也可用 DSH 内置下载的（`~/.dsh/mobile-access/components/cloudflared/`） |
| **PowerShell 7**（`pwsh`） | 跑本仓库的 `scripts/*.ps1` | 脚本用 `pwsh.exe` 调起；Windows PowerShell 5.1 也能跑，但推荐 7 |

### 强烈建议（不加会很别扭）

| 组件 | 作用 | 不加会怎样 |
|---|---|---|
| **`dsh-web-mobile`**（社区插件，web profile） | 把 DSH 界面适配成**手机竖屏排版**（窄屏切底部浮层、输入区不被键盘遮、大 JSON 自动折叠） | 手机上打开是**桌面布局**，字小、按钮难点、输入框被键盘顶掉——能用但难受 |

安装：

```powershell
dsh plugin --profile web add dsh-web-mobile
```

### 可选

| 组件 | 作用 |
|---|---|
| **SMTP 邮箱**（如 QQ 邮箱授权码） | 把新链接自动发到手机（本仓库 `send-mobile-url.ps1`）；不配就只在 `mobile-urls.txt` 里留链接 |
| **手机端模型供应商**（如 OpenCode Go / WorkBuddy / DeepSeek 账户） | 让手机端的会话能真的回复；属于 DSH 侧配置，与本插件无关 |

### 与本插件的关系图

```
┌──────────────── 手机浏览器 ────────────────┐
│  打开 https://xxx.trycloudflare.com/?token= │
└───────────────────┬────────────────────────┘
                    │ Cloudflare 边缘
┌───────────────────▼────────────────────────┐
│          cloudflared (quick tunnel)         │  ← 本插件负责拉起
└───────────────────┬────────────────────────┘
┌───────────────────▼────────────────────────┐
│  dsh --profile web  (LAN IP:3081)           │  ← 本插件负责拉起
│  + dsh-web-mobile（手机排版，需你另装）      │
│  + 模型供应商（DSH 侧配置）                  │
└─────────────────────────────────────────────┘
         ▲
         │ 启动时触发一次
┌────────┴────────────────────────────────────┐
│  dsh-mobile-watch（本仓库，bundle 插件）     │
└─────────────────────────────────────────────┘
```

## 实现

### 触发链

```
DSH 启动
  └─ profile loader 装载 bundles
       └─ dsh-mobile-watch 的 apply() 被调用一次
            └─ spawn(powershell, detached, hidden):
                 Start-Sleep 20
                 & check-mobile.ps1
                      ├─ 3081 在听 且 cloudflared 存活 → exit
                      └─ 否则 → refresh-mobile.ps1
                           ├─ 探测物理网卡 IPv4
                           ├─ 起 cloudflared quick tunnel，抓分配到的域名
                           ├─ 起 dsh --profile web --host <LAN> --public-url <tunnel> --trusted-host <host>
                           ├─ 从日志里抓本次域名的 token
                           ├─ 写 mobile-urls.txt
                           └─ send-mobile-url.ps1（有配置文件才发）
```

### 为什么延迟 20 秒

DSH 在自己启动的过程中会把它之前启动的 `--profile web` 实例结束掉（同一个 exe，按进程名清理）。如果立刻检查，就会和一个「马上要被杀掉的进程」赛跑：刚重建好就被 DSH 杀了。所以必须等 DSH 启动完成、清理动作结束，再检查。

### 为什么不用「改快捷方式」或「WMI 事件订阅」

| 方案 | 覆盖所有启动方式 | 需要权限 | 实测结果 |
|---|---|---|---|
| 改快捷方式指向启动器 | ❌ 只覆盖图标 | 无 | 可用但覆盖不全 |
| WMI `Win32_ProcessStartTrace` 订阅 | ✅ | 要 UAC | **在目标机器上创建成功但完全不触发**，已放弃 |
| 计划任务轮询 | ✅ | 无 | 用户不接受（不想常驻检查） |
| **本 bundle（profile 装载时触发）** | ✅ | 无 | ✅ 采用 |

### 关键实现细节（踩过的坑）

- **`--trusted-host` 只接受裸 host**。写成 `https://xxx.trycloudflare.com` 会让 dsh 直接拒绝启动：
  `trustedHosts entry "..." is not a bare host[:port] authority`。
- **不要在 dsh 前面加改写 Host 的反向代理**。dsh 签发的 cookie 里绑定了 authority，改写 Host 会导致 cookie 与真实域名不匹配 → 浏览器陷入 303 无限重定向，页面永远加载不出来。正确做法就是 `--trusted-host` 白名单。
- **抓 token 必须按本次域名匹配**。`web.console.log` 是追加写的，里面留着历次启动的 token，直接取「最后一条」很可能拿到上一个域名的旧 token。
- **验证链接要用浏览器方式**：`curl -L -c jar -b jar "<url>?token=..."`。不带 cookie jar 会被 401/303 误导成「token 失效」。

## 安装

### 1. 放置 bundle

```powershell
# 放到 DSH 的插件源码目录（示例）
$src = "$env:USERPROFILE\.dsh\profiles\desktop\plugins-src\dsh-mobile-watch"
git clone https://github.com/jisvrin/dsh-mobile-watch.git $src
```

### 2. 链接到 profile 的 node_modules

```powershell
$link = "$env:USERPROFILE\.dsh\profiles\desktop\node_modules\dsh-mobile-watch"
cmd /c mklink /J "$link" "$src"
```

### 3. 注册 bundle + 依赖

编辑 `profiles/desktop/package.json`：

```json
{
  "dsh": {
    "profile": {
      "bundles": [ "...existing...", "dsh-mobile-watch" ]
    }
  },
  "dependencies": {
    "dsh-mobile-watch": "file:C:/Users/<you>/.dsh/profiles/desktop/plugins-src/dsh-mobile-watch"
  }
}
```

### 4. 放置脚本

```powershell
$work = "$env:USERPROFILE\.dsh\web-service"
New-Item -ItemType Directory -Path $work -Force | Out-Null
Copy-Item "$src\scripts\*.ps1" $work
```

### 5. 配置发信（可选）

创建 `~/.dsh/web-service/mail-config.json`：

```json
{
  "host": "smtp.qq.com",
  "port": 587,
  "from": "you@qq.com",
  "to": "you@qq.com",
  "password": "<SMTP 授权码，不是登录密码>"
}
```

限制文件权限（里面是凭据）：

```powershell
icacls "$env:USERPROFILE\.dsh\web-service\mail-config.json" /inheritance:r /grant:r "$env:USERNAME:(R,W)"
```

> QQ 邮箱：设置 → 账户 → 开启 IMAP/SMTP 服务 → 短信验证 → 拿到 16 位授权码。

### 6. 重启 DSH

下次启动 DSH 时插件生效。第一次可以验证：

```powershell
Get-Content "$env:USERPROFILE\.dsh\web-service\plugin-trigger.log"   # 应有一行 apply() called
Get-Content "$env:USERPROFILE\.dsh\web-service\mobile-urls.txt"      # 手机链接
```

## 配置项

| 环境变量 | 默认值 | 说明 |
|---|---|---|
| `DSH_HOME` | `%USERPROFILE%\.dsh` | DSH 家目录 |
| `DSH_MOBILE_PORT` | `3081` | 手机端 web 监听端口 |
| `DSH_MOBILE_PROFILE` | `web` | 用哪个 profile 作为手机端 |
| `DSH_CLI` | `dsh` | dsh 启动器（需在 PATH） |
| `DSH_MOBILE_CLOUDFLARED` | 自动探测 | cloudflared.exe 路径 |
| `DSH_MOBILE_DELAY_SECONDS` | `20` | 启动后延迟几秒再检查 |
| `DSH_MOBILE_CHECK_SCRIPT` | `<DSH_HOME>\web-service\check-mobile.ps1` | 检查脚本路径 |

## 运行时文件

```
~/.dsh/
├─ index.js                     插件本体（apply 时触发一次）
├─ cordis.patch.yml             bundle 挂载声明
├─ scripts/
│  ├─ check-mobile.ps1          幂等检查
│  ├─ refresh-mobile.ps1        重建隧道 + web + 抓 token
│  └─ send-mobile-url.ps1       发邮件
└─ web-service/                 运行时（自动生成）
   ├─ mobile-urls.txt           最新链接
   ├─ mail-config.json          发信配置（你自己放，含凭据）
   ├─ web-launch.ps1 / .vbs     web 实例启动器
   ├─ cf-launch-hidden.vbs      隧道启动器
   ├─ check-mobile.log          重建记录
   ├─ mail.log                  发信记录
   ├─ plugin-trigger.log        每次 DSH 启动记一行
   └─ cloudflared.log           隧道日志（含分配到的域名）
```

## 已知限制

- **每次重建都会换域名和 token**：Cloudflare 免费 quick tunnel 不提供固定域名。所以旧的手机链接必然失效，**永远用最新一封邮件**。
- **只支持 Windows**：脚本用了 `Get-NetAdapter`、`wscript`、WMI 进程查询。
- **手机端与桌面端共用会话库**：`--profile web` 读同一份 `~/.dsh/storages`，能看到桌面端的会话并接着聊；但不要两端同时对同一个会话发消息。
- **公网链接等于电脑控制权**：带 token 的地址能执行命令，别外传。无 token 访问返回 401。
- **Cloudflare 帐号不是必需的**，但 quick tunnel 没有 uptime 承诺。

## 卸载

```powershell
# 1) 从 package.json 的 bundles / dependencies 里删掉 dsh-mobile-watch
# 2) 删除 junction
Remove-Item "$env:USERPROFILE\.dsh\profiles\desktop\node_modules\dsh-mobile-watch" -Force
# 3) 删除脚本与运行时
Remove-Item "$env:USERPROFILE\.dsh\web-service" -Recurse -Force
```

## 相关

- DSH（DeepSeek Harness）profile / bundle 机制
- [Cloudflare Tunnel 文档](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)

## License

MIT
