# RenderService 开发说明

> 负责人：`@Zopiclone`
> 权威接口来源：`docs/contract.md` §8
> 更新时间：2026-08-02

RenderService 的交付物是复习会话的浏览器运行时与服务端会话 API。当前版本
`cpp-wasm-0.2.0` 已把 §8.3 的八个 ABI 函数在 C++ 中真实实现并编译为 WebAssembly：
游戏包校验、会话状态机、导航、计分、作答记录与状态序列化全部运行在 WASM 内；
JS Adapter 只做字符串编解码与生命周期管理。

§8.1 的五个 ReviewSession REST 接口与 §8.2.1 的 URGENT 学习证据回传均已实现，
由 Gateway 回调身份配置门控：设置 `Gateway__BaseUrl` + `Gateway__ServiceKey`
（contract.md §9.5 预留的变量）后，manifest 上报 `runtimeMode="FULL"`、
`reviewSessionsAvailable=true`；未配置时保持诚实 SHELL，
`/api/v1/review-sessions*` 返回 `501 RENDER_SESSION_NOT_IMPLEMENTED`。

会话服务端行为（v1 冻结，同时解决 §8.5 第 5 项恢复语义）：

- 创建会话时以精确 `X-Service-Name: RenderService` 经 Gateway 读取 GalGameService
  权威游戏包并调用共同校验接口，`reviewPlanId + snapshotVersion` 从包中冻结，
  浏览器提交值只作核对，不被信任；
- 进度使用 `progressVersion` 乐观并发；对"上一次保存"的完全相同重放幂等返回原快照，
  其余版本错配返回 `409 VERSION_CONFLICT`；`runtimeState` 上限 256 KiB；
- 事件按 `clientEventId` 会话内去重，回执 `{accepted, duplicates}`；
- 结果幂等：相同 `idempotencyKey` + 规范化载荷 → `200 DUPLICATE` 与原 `resultId`；
  载荷或键变化 → `409 IDEMPOTENCY_CONFLICT`；`resultId` 在 KnowledgeService
  故障重试间保持稳定（先登记后提交）；证据接受后会话进入 `COMPLETED`；
- 证据映射为 `ReviewEvidenceSubmission` 提交
  `PUT /internal/v1/review-evidence/{resultId}`；`scoreDelta` 与 `choiceId`
  永不出现在证据中；质量一致性（错误≤2、正确≥3、用提示≤3）与
  `questionId/knowledgePointId/choiceId/correct` 的游戏包绑定真实性在本服务先行校验；
- 纯讲解包（或没有任何实际作答）`answerResults` 必须为空：本地完成会话，
  不调用 evidence 接口，掌握度不变；
- 存储为 `ephemeral-memory`（与 GalGameService 现状一致）；`/readyz` 仅返回最小化的
  `status=ready`，不公开存储、执行引擎或活动会话等内部诊断信息；
  持久化是文末路线图中的后续里程碑。

## 目录结构

```text
RenderService/
├─ src/
│  ├─ core/            # C++ 运行时核心：json / package(校验) / runtime(状态机)
│  ├─ abi/             # §8.3 extern "C" ABI 与内存辅助导出
│  ├─ tests/           # 原生自检套件（129 项断言）
│  └─ main.cpp         # 原生入口：自检 + `--validate <file>` CLI
├─ service/            # TypeScript 服务层（与 gateway 同一套工具链：tsc + vitest）
│  ├─ package.json / tsconfig.json
│  ├─ src/
│  │  ├─ server.ts         # HTTP 服务：runtime 资源 + ReviewSession 五接口
│  │  ├─ sessions.ts       # 会话领域逻辑：冻结、乐观并发、去重、结果幂等
│  │  ├─ gateway-client.ts # 经 Gateway 的 INTERNAL 调用（读包/校验/证据）
│  │  ├─ adapter.ts        # 浏览器 Adapter（仅 import type，编译产物零运行时导入）
│  │  └─ contract.ts       # 契约类型与公共校验助手
│  ├─ tests/               # vitest：adapter / sessions + support/testPorts
│  └─ runtime.wasm.base64  # 提交的 WASM 产物（emcc -Oz，约 176 KiB）
├─ scripts/            # build-wasm.*：重建并嵌入 WASM；e2e-session.mjs：全链路验证
├─ mocks/runtime-state/    # RuntimeState / RuntimeError Mock（§12.1 交付物）
├─ build_support/      # 自管 xmake 工具链框架（含 fixture 回归套件）
└─ xmake.lua           # 默认平台显式为 wasm；宿主平台仅构建自检二进制
```

## 构建与测试

```bash
# 原生自检（129 项断言；Docker 构建阶段同样执行）
g++ -std=c++23 -O2 -Wall -Wextra src/core/*.cpp src/abi/*.cpp src/tests/*.cpp src/main.cpp -o render-selftest
./render-selftest

# 校验任意游戏包（与浏览器 WASM 走同一条 ABI 路径；退出码 0 合法 / 2 非法）
./render-selftest --validate ../GalGameService/mocks/golden.json

# 重建 WASM 并刷新 service/runtime.wasm.base64（需要 emsdk 4.0.13+）
pwsh scripts/build-wasm.ps1        # 或 scripts/build-wasm.sh

# 服务层：安装依赖后一键构建+测试（pretest 先 tsc，再 vitest 全套）
cd service && npm install && npm test

# 集成环境全链路验证（需 compose 栈已启动；注册→构图→GalGame→会话→mastery）
node scripts/e2e-session.mjs http://127.0.0.1:5000

# 工具链框架自身的 fixture 回归
xmake lua build_support/tests/run_all.lua
```

xmake 侧默认平台已显式定为 `wasm`（见 `xmake.lua`）：`GalReview.RenderService.Runtime`
目标只在 wasm/emscripten 平台启用，宿主平台目标只产出自检二进制，防止把宿主可执行
文件误当作服务本体。托管工具链尚未就绪时，可用 `xmake f --toolchains_auto=false` 关闭
自动引导，改用 `scripts/build-wasm.*` 的 emcc 直连路径（当前发布产物即来源于此）。

Docker 镜像构建阶段会：原生编译核心并跑完整自检 → 对提交的 WASM 产物跑服务层
测试 → 仅把二进制与 `service/` 装入最终镜像。`server.mjs` 启动时对实际服务的
WASM 做导出自省，只有完整 runtime-abi v1 存在时才报告 `wasmAbiComplete=true`，
损坏或占位产物自动回退为 `cpp-js-shell` 报告，不会虚报能力。

## 已冻结决议（解决 contract.md §8.5 OWNER-TBD，v1）

以下决议以本模块为准落地；同步回 `docs/contract.md` §8.5 勾选项与 §8.3 版本描述
需经 PM `@Arabidopsis` 合并契约文档（见文末协作备注）。

### 1. WASM 内存所有权与字符串规则（runtime-abi v1）

- 入参字符串：调用方所有。调用方用导出的 `rtAlloc(n)` 申请内存、写入 UTF-8 +
  NUL，调用 ABI 函数后用 `rtFree(ptr)` 释放；运行时在返回前完成拷贝。
- 返回的 `const char*`：运行时所有，仅在下一次返回字符串的 ABI 调用或 `dispose()`
  之前有效；调用方必须立即拷贝，禁止对返回指针调用 `rtFree`。
- `int32` 型函数返回 `0` 成功、非 `0` 失败；字符串型函数不返回空指针（拒绝时返回
  `[]` / `"null"` / `valid:false` 的合法 JSON）。详情一律通过 `getLastError()` 读取，
  其返回 `{"code","message","details":{}}`，空闲态为 `NO_ERROR`。
- 能力自描述导出：`rtAbiVersion()`（当前 `1`）、`rtVersion()`（当前
  `cpp-wasm-0.2.0`）。运行时为单线程，并发调用未定义。
- 稳定错误码：`JSON_PARSE_ERROR`、`CONFIG_INVALID`、`RUNTIME_NOT_INITIALIZED`、
  `PACKAGE_NOT_LOADED`、`PACKAGE_INVALID`、`SESSION_JSON_INVALID`、
  `SESSION_PACKAGE_MISMATCH`、`SESSION_STATUS_INVALID`、`SESSION_SCENE_UNKNOWN`、
  `SESSION_NOT_STARTED`、`SESSION_ALREADY_COMPLETED`、`INPUT_JSON_INVALID`、
  `INPUT_TYPE_UNSUPPORTED`、`INPUT_CHOICE_UNKNOWN`、`INPUT_CHOICE_REQUIRED`、`NO_ERROR`。

### 2. RuntimeState schema（`render-runtime-state-1`）

样例见 [`mocks/runtime-state/`](mocks/runtime-state/)。字段：`schemaVersion`、
`runtimeVersion`、`abiVersion`、`sessionId`、`userId`、`packageId`、`reviewPlanId`、
`snapshotVersion`（后三者从已校验游戏包冻结，浏览器无法替换——§8.2.1 义务的
运行时侧基础）、`status`（`RUNNING|COMPLETED`）、`currentSceneId`、
`visitedSceneIds`、`score`（游戏计分，禁止换算 mastery）、`elapsedMs`、`answers[]`
（`sceneId/questionId/knowledgePointId/choiceId/answerKind/correct/scoreDelta/
attemptNumber/attemptId|null/occurredAt|null`）。`attemptId` 与 `occurredAt` 由调用方
经 RuntimeInput 传入（运行时无时钟、无随机源，保持确定性）。

### 3. RuntimeInput / RenderEvent v1

- 输入：`{"type":"CHOICE_SELECTED","choiceId","attemptId"?,"occurredAt"?}` 与
  `{"type":"ADVANCE"}`（仅无选项场景合法，触发完成）。未知字段忽略；非法输入整体
  拒绝、状态不变。
- 事件：`SCENE_ENTERED{sceneId}`、`ANSWER_RECORDED{sceneId,questionId,
  knowledgePointId,choiceId,correct,scoreDelta,attemptNumber}`、
  `SESSION_COMPLETED{score,answeredQuestionCount,attemptCount,visitedSceneCount,
  elapsedMs}`。
- 在契约文档正式勾选前，前端仍按 §8.3 要求把这些对象当作透传 JSON，不得据此新增
  跨服务证据字段。

### 4. 版本兼容策略

Adapter 声明支持的 ABI 版本集合（当前 `{1}`），实例化后核对 `rtAbiVersion()`：
版本不受支持或导出不完整时回退本地 JS 壳并告警，保证 SHELL 体验不因产物偏斜而
中断。破坏性 ABI 变更必须递增 `rtAbiVersion` 并同步 Adapter 支持集合；
`RuntimeManifest.wasmVersion` 由服务端对产物自省得出，禁止手工硬编码虚报。

### 5. 保存频率与恢复行为（沿用既有基线，其余仍待冻结）

- 保存频率维持 §12.2 决策：场景切换或选择后保存，不逐帧上传。
- 页面刷新/断网/重复提交的完整恢复语义与 ReviewSession 服务端实现一并冻结
  （见路线图）；当前 SHELL 模式仅浏览器本地体验，无服务端状态可恢复。

## 校验器奇偶策略

游戏包合法性存在两份实现：C++ 核心（WASM 内）与 `adapter.js` 里的 JS 参考实现
（占位回退与诊断用）。两者逐检查对齐——包括 JS 的怪癖语义（`trim()` 全量 Unicode
空白、`undefined !== null`、多 QUESTION 绑定时同时触发 `SCORING_WITHOUT_QUESTION`
分支等）。奇偶由双侧测试保障：原生套件内置变异夹具，`service/tests/adapter.test.ts`
把 `backend/GalGameService/mocks/` 全部包同时喂给两个校验器并断言 `valid` 与
`(path, code)` 集合一致。修改任一侧校验逻辑必须同步另一侧并让两套测试通过。

## 路线图（按契约优先级）

1. ~~**URGENT §8.2.1**：证据幂等提交~~ 已完成（同步 INTERNAL 路径）；
2. ~~§8.1 五个 REST 接口~~ 已完成，`reviewSessionsAvailable` 随配置翻转；
3. ~~渲染侧真实呈现~~ 首版完成：`src/stage.ts` WebGPU 视觉小说舞台
   （WGSL 程序化背景×3 风格、噪声溶解转场、粒子、情绪色调，WebGPU 不可用时
   Canvas2D 兜底），经 `/api/v1/render-runtime/stage.js` 公开；
   自包含演示页 `/api/v1/render-runtime/stage-demo` 用真实 WASM 会话驱动完整
   VN 体验。对白文字采用 DOM 叠加层（CJK 清晰度与可访问性），画面走 GPU；
4. `ReviewCompleted v2` 事件生产（待团队消息总线基线；同步闭环不冒充消息完成）；
5. 会话持久化存储（当前 ephemeral-memory，重启丢失进行中会话）；
6. 舞台资源纹理通道：`AssetRef` 的 BACKGROUND/CHARACTER 贴图渲染
   （待 `@F15EX` 生成器产出资源引用后接入；当前零素材由着色器程序化补足）；
7. 前端 `/review` 挂载 stage.js 替换文字卡片（`@甲烷` 集成，接口已就绪）。

### 会话接口错误码（v1）

`VALIDATION_ERROR`(400)、`AUTH_REQUIRED`(401)、`RESOURCE_NOT_FOUND`(404)、
`VERSION_CONFLICT`/`STATE_CONFLICT`/`IDEMPOTENCY_CONFLICT`/`SNAPSHOT_VERSION_CONFLICT`(409)、
`GAME_PACKAGE_NOT_FOUND`、`PROGRESS_SCENE_UNKNOWN`、`PROGRESS_STATE_TOO_LARGE`、
`EVENT_BATCH_TOO_LARGE`、`RESULT_PLAN_MISMATCH`、`RESULT_EVIDENCE_INVALID`、
`RESULT_ANSWERS_NOT_ALLOWED`、`ANSWER_QUESTION_NOT_IN_PACKAGE`、`ANSWER_POINT_MISMATCH`、
`ANSWER_CHOICE_UNKNOWN`、`ANSWER_CORRECT_MISMATCH`、`REVIEW_PLAN_NOT_FOUND`(422)、
`UPSTREAM_CONTRACT_INVALID`(502)、`SERVICE_UNAVAILABLE`(503)、
`RENDER_SESSION_NOT_IMPLEMENTED`(501，仅未配置回调身份时)。
KnowledgeService 的 `409/422` 稳定错误码（如 `STALE_REVIEW_EVIDENCE`）原样透传。

## 协作备注

- JS Adapter 的最终设计责任在 `@甲烷`（contract.md §8.3 职责表）。当前
  `service/adapter.js` 保持冻结的 `createWasmAdapter` 工厂面并新增 WASM 驱动路径，
  属于运行时交付的一部分；后续 Adapter 层面的改动（保存节流、错误提示、Gateway
  调用）请 `@甲烷` 在此基础上继续，双方改动互相通报。
- `docs/contract.md` §8.3 的"当前可执行版本 cpp-js-shell-0.1.0"描述与 §8.5 勾选项
  需要 PM 同步为本文件的 v1 决议；在合并前，本服务对外报告的 `runtimeMode` 与
  `reviewSessionsAvailable` 不变，行为向后兼容。
