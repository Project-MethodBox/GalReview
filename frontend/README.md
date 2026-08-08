# GalReview 前端

React、TypeScript 与 Vite 实现的浏览器端。页面通过同源 `/api/v1` 访问 Gateway。迁移后以 ReciteHelper 的学习项目、五类题库、日常练习和试卷为主流程，并继续接入资料、知识图谱、复习计划、GalGame 与 Render 剧情复习。

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
| `/login`、`/register` | 登录与无邀请码注册；注册后获得初始 credits |
| `/forgot-password` | 密码重置 |
| `/home` | 学习入口与 AI 辅助解析、题库、图谱/SM-2 复习流程说明 |
| `/projects`、`/projects/:projectId` | 学习项目、题库与组卷入口 |
| `/practice/:sessionId` | 五类题目作答、显式判分结果与会话完成 |
| `/materials` | 上传、解析、构图和创建复习计划 |
| `/knowledge-graph` | 查看章节、知识点和关系 |
| `/review` | 生成 GalGame 并加载 C++/WASM runtime，会话结果经受信服务提交 KnowledgeService |
| `/settings` | 查看 credits、输入兑换码和确认前往购买页；不展示内部 token 换算 |
| `/admin` | 管理用户并批量创建、查看状态和撤销 credits 兑换码 |

## UI 约束

新增页面必须沿用 GalReview 现有浅灰画布、表面层级、克制蓝色主操作、圆角和中文排版，
不得复刻 ReciteHelper 的 AI 风格。导航、按钮、空态、状态和正文禁止使用 emoji；不使用
机器人/星光/魔法棒、发光渐变或聊天气泡式普通表单。图标只复用现有中性 SVG 体系。
产品名称固定为“千知万理”。首页可以说明 AI 辅助语义整理、候选内容生成与解析过程，
但必须同时说明资料来源、人工确认、确定性判分和知识图谱/SM-2 调度边界，不能用视觉包装替代能力说明。

接口字段和状态均以 `docs/contract.md` 为准。本地不再伪造登录或成功结果，Gateway 不可用时会显示真实错误。
复习题目或游戏生成遇到 `402 CREDITS_INSUFFICIENT` 时，页面显示可用与最低所需 credits，
经用户确认后才跳转购买页；不会自动跳转，也不会在 UI 中解释内部计量单位。

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
