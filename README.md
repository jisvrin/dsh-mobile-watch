# dsh-phone-access

DSH 的手机访问入口。在 DSH 启动时检查手机端服务，缺失则重建隧道与 web 实例，并把新链接发到邮箱。

## 作用

DSH 每次启动时加载本插件一次，无论启动方式（双击图标、右键打开、任务栏、命令行）。插件等待 20 秒，随后检查两件事：

- 3081 端口是否有 DSH web 实例在监听
- cloudflared 进程是否存活

两者都在则不执行任何操作；缺任意一个则重启隧道、重启 web 实例、写入新链接，并发送邮件。

插件没有常驻进程，启动后不保留定时器或监听器。20 秒延迟用于避开 DSH 启动过程中结束自身 web 实例的动作。

## 使用场景

适用：

- 家庭宽带为 CGNAT，没有公网 IP，无法做端口映射或 DDNS
- 电脑长期开机，手机作为输入与查看终端
- 不希望手机安装客户端或开启 VPN
- 可接受链接随重建变化，通过邮件获取新地址

不适用：

- 需要固定域名访问
- 需要手机端离线运行 agent
- 不允许电脑对公网暴露端口
- 非 Windows 系统

手机端与桌面端共用同一份会话库，可查看并继续桌面端的会话。同一会话不建议两端同时输入。

## 依赖

必需：

- DSH，含 web profile（手机访问的即该实例）
- cloudflared（可用 DSH 内置下载的版本）
- PowerShell 7

建议安装：

- `dsh-web-mobile`，提供手机竖屏排版。未安装时手机打开为桌面布局，控件尺寸与输入区域不适配。

可选：

- SMTP 邮箱，用于自动发送新链接。未配置时链接写在 `~/.dsh/web-service/mobile-urls.txt`。

手机端要能正常对话，还需在 DSH 侧配置模型供应商，此部分与本插件无关。

## 安装

```
$src = "$env:USERPROFILE\.dsh\profiles\desktop\plugins-src\dsh-phone-access"
git clone https://github.com/jisvrin/dsh-phone-access.git $src

cmd /c mklink /J "$env:USERPROFILE\.dsh\profiles\desktop\node_modules\dsh-phone-access" "$src"
```

在 `profiles/desktop/package.json` 中登记：

```json
"bundles": [ "...", "dsh-phone-access" ],
"dependencies": { "dsh-phone-access": "file:C:/Users/<user>/.dsh/profiles/desktop/plugins-src/dsh-phone-access" }
```

将 `scripts/` 下的三个 ps1 复制到 `~/.dsh/web-service/`，重启 DSH 生效。

验证：

```powershell
Get-Content "$env:USERPROFILE\.dsh\web-service\plugin-trigger.log"
Get-Content "$env:USERPROFILE\.dsh\web-service\mobile-urls.txt"
```

`plugin-trigger.log` 出现 `apply() called` 表示插件已加载。

## 发信配置

`~/.dsh/web-service/mail-config.json`：

```json
{
  "host": "smtp.qq.com",
  "port": 587,
  "from": "user@qq.com",
  "to": "user@qq.com",
  "password": "SMTP 授权码"
}
```

QQ 邮箱的授权码在「设置 → 账户 → 开启 IMAP/SMTP 服务」中生成，不是登录密码。该文件为明文凭据，创建后限制访问权限：

```powershell
icacls "$env:USERPROFILE\.dsh\web-service\mail-config.json" /inheritance:r /grant:r "$env:USERNAME:(R,W)"
```

## 可配置项

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DSH_HOME` | `%USERPROFILE%\.dsh` | DSH 家目录 |
| `DSH_MOBILE_PORT` | `3081` | 手机端端口 |
| `DSH_MOBILE_PROFILE` | `web` | 手机端使用的 profile |
| `DSH_CLI` | `dsh` | dsh 启动器，需在 PATH 中 |
| `DSH_MOBILE_CLOUDFLARED` | 自动探测 | cloudflared.exe 路径 |
| `DSH_MOBILE_DELAY_SECONDS` | `20` | 启动后延迟检查的秒数 |

## 实现要点

`--trusted-host` 只接受裸主机名。带 `https://` 前缀会导致 dsh 拒绝启动，报 `trustedHosts entry ... is not a bare host[:port] authority`。

不要在 dsh 前部署改写 Host 的反向代理。dsh 签发的 cookie 绑定 authority，Host 被改写后与真实域名不一致，浏览器会陷入 303 重定向循环。

抓取 token 需按当前域名匹配。`web.console.log` 为追加写入，包含历次启动的 token，直接取最后一条可能取到上一个域名的值。

验证链接需保留 cookie：`curl -L -c jar -b jar "<url>?token=..."`。缺少 cookie jar 时 303 与 401 会被误判为 token 失效。

重建会同时更换隧道域名和 web token，旧链接随即失效。

## 卸载

从 `package.json` 的 bundles 与 dependencies 中移除条目，然后：

```powershell
Remove-Item "$env:USERPROFILE\.dsh\profiles\desktop\node_modules\dsh-phone-access" -Force
Remove-Item "$env:USERPROFILE\.dsh\web-service" -Recurse -Force
```

## 许可

MIT

