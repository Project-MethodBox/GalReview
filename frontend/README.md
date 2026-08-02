# GalReview 前端

React、TypeScript 与 Vite 实现的浏览器端。页面通过同源 `/api/v1` 访问 Gateway，覆盖登录、资料上传、非 OCR 文本提取、知识图谱、复习计划、GalGame 生成和 Render 基础壳体验。

## 本地开发

```powershell
npm ci
npm run dev
```

开发服务器打开 `http://127.0.0.1:5121`，预览服务器使用 `5122`，默认把 `/api` 转发到 `http://localhost:5000`。如 Gateway 使用其他地址，可在 `vite.config.ts` 中调整开发代理；浏览器代码不保存任何业务服务直连地址。

提交前检查：

```powershell
npm run typecheck
npm run build
```

## 页面

| 路径 | 功能 |
| --- | --- |
| `/login`、`/register` | 登录与邀请码注册 |
| `/forgot-password` | 密码重置 |
| `/home` | 功能入口 |
| `/materials` | 上传、解析、构图和创建复习计划 |
| `/knowledge-graph` | 查看章节、知识点和关系 |
| `/review` | 生成 GalGame 并加载 C++ / JS 运行时基础壳；当前只保留本地进度，不提交结果 |

接口字段和状态均以 `docs/contract.md` 为准。本地不再伪造登录或成功结果，Gateway 不可用时会显示真实错误。

## 容器

```powershell
docker build -t galreview-frontend ./frontend
docker run --rm -p 5120:8080 -e GATEWAY_UPSTREAM=http://host.docker.internal:5000 galreview-frontend
```

容器由非 root Node 进程在内部端口 `8080` 提供静态页面和 `/healthz`，上例把宿主
`5120` 发布到该 target。根目录 Compose 使用 `FRONTEND_HOST_PORT` 配置宿主侧，默认
`5120`；只有 published 侧受 `5000-5300` 防火墙范围限制。容器 target 和
`GATEWAY_UPSTREAM` 这类服务间 URL 不受该范围限制。在 Compose 网络中上游应使用 Gateway
服务名和容器端口，例如 `http://gateway:5000`。
