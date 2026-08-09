# Windows 非 Docker 生产部署

`deploy-windows.ps1` 用于 Windows Server 的非 Docker 生产部署。它不会调用 Vite 开发服务器；前端只发布 `vite build` 产生的 `dist`，并由 `frontend/server.mjs` 提供静态文件和同源 `/api` 代理。

## 前置条件

- Windows Server 已安装 Node.js 22 和 .NET 10 SDK；
- MySQL、MongoDB 和 Neo4j 已作为 Windows 服务启动；
- MySQL 中已创建 `galreview_user`、`galreview_auth`、`qzwl_credit` 数据库；
- `backend/PracticeService/Resources` 已按 `resources.manifest.json` 恢复；
- 公网入口可由本脚本自动安装和配置 IIS，也可自行使用 Nginx/Caddy 反向代理至 `127.0.0.1:5120`。

## 配置

在项目根目录右键 `deploy-windows.ps1`，选择“使用 PowerShell 运行”；也可以在 PowerShell 中直接执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\deploy-windows.ps1
```

不带参数运行时会进入中文管理菜单。首次运行会从 `deploy/.env.windows.production.example` 复制生产配置模板，自动生成九个相互独立的 256-bit 服务密钥，然后打开记事本。服务密钥不需要手动修改，但 Neo4j 密码、管理员信息和正式域名等其余 `CHANGE_ME` 必须填写。实际配置仍保存为项目根目录的 `.env.windows.production`，且不应提交到 Git。

按当前部署约定，三个 MySQL 连接首次生成时默认使用 `root/root`。脚本会允许启动但显示安全警告；公网正式运行前，建议分别创建只拥有对应数据库权限的账户并替换连接字符串。

## 首次发布

在项目根目录以 PowerShell 执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\deploy-windows.ps1 -Action Deploy
```

`Deploy` 会：

1. 对所有 .NET 服务执行 Release publish；
2. 构建 Gateway、RenderService 和 Frontend；
3. 从运行产物中排除 TypeScript declaration/source map，并确认前端 `dist` 不含 `.ts`/`.tsx`/`.map`；
4. 停止上一个由本脚本记录的版本；
5. 按依赖顺序启动新版本，逐个等待 `/readyz`/`healthz`。

如果新版本未通过健康检查，脚本会停止其已启动的进程，并尝试恢复此前正在运行的版本。

产物、进程清单和日志位于 `.production/`。

## 一键配置 IIS 反向代理

先在 `.env.windows.production` 中填写正式公网地址：

```env
ACCOUNT_FRONTEND_BASE_URL=http://203.0.113.10
CORS_ORIGINS=http://203.0.113.10
```

然后用“以管理员身份运行”的 PowerShell 执行：

```powershell
.\deploy-windows.ps1 -Action Proxy
```

也可以在管理菜单选择“9. 一键配置 IIS 公网反向代理”，或者直接覆盖公网地址：

```powershell
.\deploy-windows.ps1 -Action Proxy -PublicUrl http://203.0.113.10
```

如果旧配置仍使用 `http://公网IP:5120`、`:5121` 或 `:5122`，脚本会自动移除开发/内部端口并迁移成 `http://公网IP`；无需手动修改环境文件。

该操作会安装 IIS、从 Microsoft 官方地址下载并验证 URL Rewrite 2.1 与 ARR 3 安装包、在 `C:\inetpub\GalReviewProxy` 创建只含代理规则的站点、授予 IIS 只读执行权限、将请求转发至 `127.0.0.1:5120`，并开放 Windows 防火墙的 80 端口。云厂商安全组仍需在控制台放行相同端口。脚本不会开放 Gateway 或内部服务端口。

公网 IP 使用 IIS 通配绑定 `*:80:`；脚本会停用未承载内容的 `Default Web Site` 并释放其默认绑定。域名访问则保留独立 Host Header，不会改动其他网站。若通配 80 端口属于非默认网站，脚本会停止并要求管理员自行决定，避免覆盖已有业务。

HTTPS 地址要求证书已导入 `LocalMachine\My`。脚本会自动查找覆盖该域名且带私钥的有效证书；也可明确指定：

```powershell
.\deploy-windows.ps1 -Action Proxy `
  -PublicUrl https://example.com `
  -CertificateThumbprint 证书指纹
```

配置 HTTPS 后，脚本同时建立 80 到 443 跳转并开放对应防火墙端口。它不会生成自签名生产证书。

## 公网直连模式（不使用反向代理）

仅用于明确需要直接暴露生产前端的场景。以管理员身份运行菜单 `10. 启动公网直连模式（端口 5120）`，或者执行：

```powershell
.\deploy-windows.ps1 -Action Direct -PublicUrl http://203.0.113.10:5120
```

脚本会把 `FRONTEND_BIND_ADDRESS` 设置为 `0.0.0.0`，同步更新 `ACCOUNT_FRONTEND_BASE_URL` 和 `CORS_ORIGINS`，开放 Windows 防火墙的 `FRONTEND_PORT`，并重启已有正式环境。Gateway 与 `5101-5108` 内部服务仍只监听 `127.0.0.1`。之后正常的 `Start`、`Restart` 和 `Deploy` 都会保持直连模式；重新执行菜单 `9` 会切回仅本机监听和 IIS 反向代理。

该模式只提供 HTTP，不提供 TLS。云安全组仍需手动放行 TCP 5120；云厂商的备案或域名白名单限制可能继续拦截，切换端口不能替代 ICP 备案。

## 日常操作

```powershell
# 查看状态
.\deploy-windows.ps1 -Action Status

# 检查命令、安装和端口；基础设施未启动时按警告处理
.\deploy-windows.ps1 -Action Check

# 部署前严格检查 MySQL、MongoDB、Neo4j 必须可连接
.\deploy-windows.ps1 -Action Check -RequireRunning

# 重启当前已构建版本
.\deploy-windows.ps1 -Action Restart

# 停止
.\deploy-windows.ps1 -Action Stop

# 代码更新后构建并替换
.\deploy-windows.ps1 -Action Deploy
```

## 开机自启

在 Windows “任务计划程序”中建立“系统启动时”任务，操作设置为：

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\path\to\GalReview\deploy-windows.ps1 -Action Start
```

`Start` 只启动 `.production/current-release.txt` 指向的已构建版本，不会在开机时重新下载依赖或编译。

OCR 是可选服务，不由本脚本安装。需要 OCR 时，先运行 `backend/OCRService/setup.ps1`，再将 `backend/OCRService/start.ps1` 注册为单独的开机任务，并保持 `OCR_BASE_URL=http://127.0.0.1:5110/`。

## 网络边界

脚本将 Frontend、Gateway 和全部内部服务绑定到 `127.0.0.1`。Windows 防火墙只需允许 IIS/Nginx/Caddy 的 `80/443`，不要对公网放行 `5000`、`5101-5108`、`5120-5122`。
