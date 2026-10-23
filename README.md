# dsh-phone-access

用手机打开 DSH，并且在 DSH 重启之后自己接回来。

## 起因

我电脑基本不关机，DSH 一直开着。但人不总在电脑前——通勤路上、在公司、躺床上，经常想拿手机接着干电脑上那摊活。

最开始的做法是用远程桌面把整个屏幕投到手机上，字小得看不清，输入法还老顶掉输入框。后来改成把 DSH 的 web 界面单独开一份给手机用，界面按竖屏排版，这样手机上看到的是正常的手机界面，不是缩小的桌面。

这个方案有个毛病：DSH 每次启动会把它自己的 web 实例一起结束掉（同一个 exe，按进程名清理），于是手机链接就废了。更烦的是 Cloudflare 的免费隧道每次重建都换域名、换 token，等于每次都得重新找链接。

所以就写了这个插件，把"重启之后自己接回来"这件事自动化掉。

## 装好之后

你正常启动 DSH——双击图标、右键打开、从任务栏、命令行敲进去，怎么启动都行——20 秒后它会检查手机端服务：

- 还活着：什么都不做。不换域名，不发邮件，不打扰你。
- 挂了：重新拉隧道、重新起 web 实例，然后把新链接发到你邮箱。

手机端健康的时候，这个插件除了写一行启动记录之外没有任何动作，也不常驻。

## 怎么用手机连

重建完成会往你邮箱发一封信，里面有两条链接：

- 「任意网络」：Cloudflare 隧道地址，手机有网就能开
- 「同一 WiFi」：局域网地址，在家用这个更快

点开就行，不用装 App，也不用开 VPN。第一次打开之后浏览器会记住登录状态，30 天内不用重新登录——但链接本身每次重建都会变，所以还是以最新那封邮件为准。

## 需要什么

必须有的：

- DSH，带 web profile（手机访问的就是这个实例）
- cloudflared（打隧道用，DSH 自带下载的那个也行）
- PowerShell 7

强烈建议装这个：

- `dsh-web-mobile` —— 手机竖屏排版。不装的话手机上打开是桌面布局，字小、按钮够不着、键盘一弹输入框就没了。装法是 `dsh plugin --profile web add dsh-web-mobile`。

可选：

- 一个能发信的邮箱（比如 QQ 邮箱开 SMTP，拿授权码），配上之后新链接会自动发过来。不配也行，链接会写在 `~/.dsh/web-service/mobile-urls.txt` 里。
- 手机端要能真的对话，还得在 DSH 里配好模型供应商。这是 DSH 那边的事，跟本插件无关。

## 装上

放插件、建链接、登记到 profile，三步：

```powershell
$src = "$env:USERPROFILE\.dsh\profiles\desktop\plugins-src\dsh-phone-access"
git clone https://github.com/jisvrin/dsh-phone-access.git $src

# 让 profile 能按包名找到它
cmd /c mklink /J "$env:USERPROFILE\.dsh\profiles\desktop\node_modules\dsh-phone-access" "$src"
```

然后在 `profiles/desktop/package.json` 里加上：

```json
"bundles": [ "...", "dsh-phone-access" ],
"dependencies": { "dsh-phone-access": "file:C:/Users/<你>/.dsh/profiles/desktop/plugins-src/dsh-phone-access" }
```

把 `scripts/` 里的三个 ps1 复制到 `~/.dsh/web-service/`，重启 DSH 就生效。

验证：

```powershell
Get-Content "$env:USERPROFILE\.dsh\web-service\plugin-trigger.log"   # 应该有 apply() called
Get-Content "$env:USERPROFILE\.dsh\web-service\mobile-urls.txt"      # 手机链接
```

## 发信配置

`~/.dsh/web-service/mail-config.json`：

```json
{
  "host": "smtp.qq.com",
  "port": 587,
  "from": "你的邮箱@qq.com",
  "to": "你的邮箱@qq.com",
  "password": "SMTP 授权码"
}
```

QQ 邮箱的授权码在「设置 → 账户 → 开启 IMAP/SMTP 服务」里拿，不是登录密码。这个文件里是明文凭据，建完锁一下权限：

```powershell
icacls "$env:USERPROFILE\.dsh\web-service\mail-config.json" /inheritance:r /grant:r "$env:USERNAME:(R,W)"
```

## 可调的东西

| 变量 | 默认 | 作用 |
|---|---|---|
| `DSH_HOME` | `%USERPROFILE%\.dsh` | DSH 家目录 |
| `DSH_MOBILE_PORT` | `3081` | 手机端端口 |
| `DSH_MOBILE_PROFILE` | `web` | 用哪个 profile 给手机 |
| `DSH_CLI` | `dsh` | dsh 启动器（要在 PATH 里） |
| `DSH_MOBILE_CLOUDFLARED` | 自动找 | cloudflared.exe 路径 |
| `DSH_MOBILE_DELAY_SECONDS` | `20` | 启动后等几秒再检查 |

## 踩过的几个坑

写的时候踩了几次，记下来省得别人再踩：

**`--trusted-host` 只认裸域名。** 写成 `https://xxx.trycloudflare.com` 会让 dsh 直接不起，报 `trustedHosts entry ... is not a bare host[:port] authority`。

**别在 dsh 前面加改写 Host 的反代。** 我一开始想用它绕过 `/api` 的信任围栏，结果 dsh 签发的 cookie 里绑着本地地址，浏览器看到的却是隧道域名，两边对不上，页面陷入 303 死循环，怎么刷都进不去。正确姿势就是 `--trusted-host` 白名单。

**抓 token 要按本次域名匹配。** `web.console.log` 是追加写的，里面躺着历次启动的 token，直接取最后一条很可能拿到上一个域名的，链接打开就是 401。

**验证链接得带 cookie。** `curl -L` 不带 cookie jar 会被 303/401 误导成"token 失效"，其实只是没保存登录态。用 `curl -L -c jar -b jar "<url>?token=..."`。

**为什么延迟 20 秒。** DSH 启动时会结束自己的 web 实例，检查太早就是跟一个马上要死的进程赛跑，建好立刻被杀。

## 不适合的情况

- 想要永久固定域名（`dsh.example.com` 那种）。这个方案用的是免费临时隧道，域名必变。要固定得走 Cloudflare 命名隧道 + 自己的域名。
- 想让手机离线跑 agent。这里只是把界面搬过去，算力还在电脑上。
- 不允许电脑对公网暴露任何端口。虽然隧道有 token 保护，但带 token 的链接等于控制权，别外传。
- 不是 Windows 的机器。脚本里用了 `Get-NetAdapter`、`wscript`、WMI 查询。

手机端和桌面端共用同一份会话库，所以能看到电脑上的会话接着聊。但别两端同时对同一个会话发消息。

## 卸掉

从 `package.json` 的 bundles 和 dependencies 里删掉，再：

```powershell
Remove-Item "$env:USERPROFILE\.dsh\profiles\desktop\node_modules\dsh-phone-access" -Force
Remove-Item "$env:USERPROFILE\.dsh\web-service" -Recurse -Force
```

## 许可

MIT
