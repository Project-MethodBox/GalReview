# GalReview 前端

基于 React、TypeScript、React Router 和 Vite 的前端实现，视觉依据 Pixso 中的浅色与深色页面设计，并与仓库现有 Gateway 认证契约连接。

## 启动

```powershell
npm install
npm run dev
```

打开 `http://127.0.0.1:5173`。生产构建使用：

```powershell
npm run typecheck
npm run build
```

开发服务器默认把 `/api` 代理到 `http://localhost:5000`。如需修改 API 地址，复制 `.env.example` 为 `.env.local` 并调整：

```dotenv
VITE_API_BASE_URL=/api/v1
VITE_ENABLE_DEMO_FALLBACK=true
```

`VITE_ENABLE_DEMO_FALLBACK` 只在 Vite 开发模式生效。当 Gateway 未启动时，登录、注册和密码重置会进入可见的本地测试流程，方便独立验证页面和路由；生产构建始终使用真实服务。

## 页面与预留路由

| 路径 | 说明 |
| --- | --- |
| `/login` | 登录，连接 `POST /auth/sessions` |
| `/register` | 注册，连接 `POST /auth/registrations`；设计稿中的“验证码”映射为后端邀请码字段 |
| `/forgot-password` | 发送重置请求并提交新密码 |
| `/home` | Pixso 主页与功能入口 |
| `/review` | “继续”预留页 |
| `/knowledge` | “知识点”预留页 |
| `/materials` | “资料上传”预留页 |
| `/knowledge-graph` | “知识图谱”预留页 |
| `/settings` | 用户资料预留页 |

所有功能卡片、工具栏入口、个人资料、返回、退出和认证页切换控件都已连接到可测试路由。主页同时提供全屏和明暗主题切换。
