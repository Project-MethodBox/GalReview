// End-to-end drive of the Render session closed loop against the running
// integration compose (gateway on :5000 by default):
//   register -> upload -> extract -> knowledge graph -> assessment plan ->
//   galgame package -> review session -> events/progress -> result ->
//   mastery updated in KnowledgeService.
// Usage: node scripts/e2e-session.mjs [gatewayBaseUrl]
import { randomUUID } from 'node:crypto'

const BASE = (process.argv[2] || process.env.GATEWAY_URL || 'http://127.0.0.1:5000').replace(/\/+$/, '')
const ADMIN_USERNAME = process.env.E2E_ADMIN_USERNAME || 'integration-admin'
const ADMIN_PASSWORD = process.env.E2E_ADMIN_PASSWORD || 'integration-admin-password'

const log = (message) => console.log(`[e2e] ${message}`)
const fail = (message) => {
  console.error(`[e2e][FAIL] ${message}`)
  process.exit(1)
}
const assert = (condition, message) => {
  if (!condition) fail(message)
}

async function api(path, { method = 'GET', token, body, headers = {}, raw = false } = {}) {
  const requestHeaders = { ...headers }
  if (token) requestHeaders.Authorization = `Bearer ${token}`
  let requestBody
  if (body instanceof FormData) {
    requestBody = body
  } else if (body !== undefined) {
    requestHeaders['Content-Type'] = 'application/json'
    requestBody = JSON.stringify(body)
  }
  const response = await fetch(`${BASE}${path}`, { method, headers: requestHeaders, body: requestBody })
  if (raw) return response
  const text = await response.text()
  let parsed = null
  try {
    parsed = JSON.parse(text)
  } catch {
    fail(`${method} ${path} -> HTTP ${response.status}, non-JSON body: ${text.slice(0, 200)}`)
  }
  return { status: response.status, body: parsed }
}

function expectSuccess(result, context) {
  if (result.status >= 400 || result.body?.data === undefined || result.body?.data === null) {
    fail(`${context} -> HTTP ${result.status} ${JSON.stringify(result.body).slice(0, 400)}`)
  }
  return result.body.data
}

async function poll(context, fetchOnce, isDone, timeoutMs = 180_000) {
  const startedAt = Date.now()
  for (;;) {
    const value = await fetchOnce()
    if (isDone(value)) return value
    if (Date.now() - startedAt > timeoutMs) fail(`${context} 超时`)
    await new Promise((resolve) => setTimeout(resolve, 1500))
  }
}

const studyMaterial = `# 作物栽培学复习题库

第一章 作物栽培学总论

一、名词解释

1. 作物栽培学：研究作物生长发育规律及其与环境条件的关系，并据此制定高产、优质、高效栽培技术措施的科学。
2. 作物生育期：作物从播种出苗到成熟收获所经历的总天数，是安排农事活动的重要依据。
3. 叶面积指数：单位土地面积上作物叶片总面积与土地面积的比值，反映群体光合面积的大小。
4. 经济系数：作物经济产量与生物产量的比值，反映光合产物向经济器官转运分配的效率。

第二章 水稻栽培

一、名词解释

1. 分蘖：水稻茎基部节位上的腋芽在适宜条件下萌发形成分枝的现象，是构成穗数的基础。
2. 有效分蘖：能够正常抽穗结实并形成产量的分蘖，通常在够苗期之前发生的分蘖成穗率较高。
3. 分蘖期管理目标：协调群体数量与个体生长的关系，通过水肥调控促进有效分蘖并控制无效分蘖。
4. 晒田：在分蘖末期排水落干稻田，控制无效分蘖、改善土壤通气并促进根系下扎的措施。

第三章 小麦栽培

一、名词解释

1. 冬性品种：需要经过较长时间低温春化阶段才能正常抽穗结实的小麦品种类型。
2. 分蘖节：小麦近地表密集节间形成的节群，是发生分蘖和不定根的部位，其入土深度影响抗寒抗倒能力。
3. 拔节期：小麦基部第一节间伸长离地约两厘米的时期，是促控转化和肥水管理的关键时期。
4. 灌浆期管理：小麦开花后保持根系活力与叶片功能，通过适量水肥延长灌浆时间并提高粒重的管理环节。
`

async function main() {
  log(`gateway = ${BASE}`)

  // 0. runtime manifest must already advertise server sessions
  const manifest = expectSuccess(await api('/api/v1/render-runtime/manifest'), '读取 runtime manifest')
  assert(manifest.reviewSessionsAvailable === true, 'manifest.reviewSessionsAvailable 应为 true')
  assert(manifest.runtimeMode === 'FULL', 'manifest.runtimeMode 应为 FULL')
  assert(manifest.wasmAbiComplete === true, 'manifest.wasmAbiComplete 应为 true')
  log(`runtime manifest: ${manifest.wasmVersion}, mode=${manifest.runtimeMode}`)

  // 1. admin -> invitation -> register -> login token
  const adminSession = expectSuccess(await api('/api/v1/admin/sessions', {
    method: 'POST', body: { username: ADMIN_USERNAME, password: ADMIN_PASSWORD },
  }), '管理员登录')
  const adminToken = adminSession.tokens.accessToken
  const invitation = expectSuccess(await api('/api/v1/admin/invitations', {
    method: 'POST', token: adminToken, body: { type: 'single-use' },
  }), '创建邀请码')

  const email = `render-e2e-${Date.now()}@example.com`
  const registration = expectSuccess(await api('/api/v1/auth/registrations', {
    method: 'POST',
    body: {
      email, password: 'render-e2e-password', displayName: 'RenderE2E',
      invitationCode: invitation.code, deviceName: 'render-e2e-script',
    },
  }), '注册用户')
  const token = registration.tokens.accessToken
  const userId = registration.session.userId
  log(`registered ${email} (${userId})`)

  // 2. upload material and extract text (no OCR)
  const form = new FormData()
  form.append('file', new Blob([studyMaterial], { type: 'text/markdown' }), 'render-e2e.md')
  form.append('displayName', 'Render E2E 复习题库')
  form.append('subjectCode', 'AGRONOMY')
  const material = expectSuccess(await api('/api/v1/materials', {
    method: 'POST', token, body: form,
  }), '上传资料')

  const job = expectSuccess(await api(`/api/v1/materials/${material.materialId}/ingestion-jobs`, {
    method: 'POST', token,
    body: { parserVersion: 'files-text-v1', force: false, enableOcr: false, ocrMode: 'standard' },
  }), '创建解析任务')
  const finishedJob = await poll('解析任务', async () =>
    expectSuccess(await api(`/api/v1/ingestion-jobs/${job.jobId}`, { token }), '查询解析任务'),
    (value) => value.status === 'SUCCEEDED' || value.status === 'FAILED')
  assert(finishedJob.status === 'SUCCEEDED', `解析任务失败: ${JSON.stringify(finishedJob.error)}`)
  assert(finishedJob.ocrUsed === false, '本轮不应触发 OCR')
  log('material text extracted')

  // 3. knowledge graph build
  const build = expectSuccess(await api('/api/v1/knowledge-graph-builds', {
    method: 'POST', token, headers: { 'Idempotency-Key': randomUUID() },
    body: { materialId: material.materialId, subjectHint: 'AGRONOMY' },
  }), '创建构图任务')
  const finishedBuild = await poll('构图任务', async () =>
    expectSuccess(await api(`/api/v1/knowledge-graph-builds/${build.buildId}`, { token }), '查询构图任务'),
    (value) => value.status === 'SUCCEEDED' || value.status === 'FAILED')
  assert(finishedBuild.status === 'SUCCEEDED', `构图失败: ${JSON.stringify(finishedBuild.error)}`)
  const graphId = finishedBuild.graphId
  const graph = expectSuccess(await api(`/api/v1/knowledge-graphs/${graphId}`, { token }), '读取图谱摘要')
  log(`graph ready: ${graph.chapterCount} chapters, ${graph.pointCount} points, ${graph.relationCount} relations`)
  assert(graph.pointCount > 0, '图谱应至少包含一个知识点')

  // 4. assessment plan
  const plan = expectSuccess(await api('/api/v1/assessment-plans', {
    method: 'POST', token, body: { graphId, maxQuestions: 5 },
  }), '创建测试计划')
  const questionTargets = plan.nodes.filter((node) => node.questionTarget)
  log(`plan ${plan.reviewPlanId}: ${plan.nodes.length} nodes, ${questionTargets.length} question targets`)
  assert(questionTargets.length > 0, '测试计划应至少包含一个出题点')

  // 5. galgame generation
  const generation = expectSuccess(await api('/api/v1/game-generations', {
    method: 'POST', token,
    body: {
      reviewPlanId: plan.reviewPlanId, snapshotVersion: plan.snapshotVersion,
      style: 'CAMPUS', difficulty: 'STANDARD', locale: 'zh-CN', seed: 42,
    },
  }), '创建游戏生成任务')
  const finishedGeneration = await poll('游戏生成', async () =>
    expectSuccess(await api(`/api/v1/game-generations/${generation.generationId}`, { token }), '查询游戏生成'),
    (value) => value.status === 'SUCCEEDED' || value.status === 'FAILED')
  assert(finishedGeneration.status === 'SUCCEEDED', `游戏生成失败: ${JSON.stringify(finishedGeneration.error)}`)

  const packageManifest = expectSuccess(
    await api(`/api/v1/game-packages/${finishedGeneration.packageId}`, { token }), '读取游戏包清单')
  const contentResponse = await api(packageManifest.contentUrl, { token, raw: true })
  assert(contentResponse.ok, `下载游戏包失败: HTTP ${contentResponse.status}`)
  const gamePackage = await contentResponse.json()
  assert(gamePackage.reviewPlanId === plan.reviewPlanId, '游戏包 reviewPlanId 与计划一致')
  assert(gamePackage.snapshotVersion === plan.snapshotVersion, '游戏包 snapshotVersion 与计划一致')

  const questionScenes = gamePackage.scenes.filter((scene) =>
    (scene.knowledgeBindings || []).some((binding) => binding.purpose === 'QUESTION'))
  log(`game package ${gamePackage.packageId}: ${gamePackage.scenes.length} scenes, ${questionScenes.length} questions`)
  assert(questionScenes.length > 0, '游戏包应至少包含一道题')

  // 6. review session against RenderService
  const session = expectSuccess(await api('/api/v1/review-sessions', {
    method: 'POST', token,
    body: { packageId: gamePackage.packageId, clientRuntimeVersion: manifest.wasmVersion },
  }), '创建复习会话')
  assert(session.reviewPlanId === plan.reviewPlanId, '会话冻结 reviewPlanId')
  assert(session.snapshotVersion === plan.snapshotVersion, '会话冻结 snapshotVersion')
  assert(session.status === 'CREATED' && session.progressVersion === 0, '会话初始状态')
  log(`review session ${session.sessionId} created`)

  // baseline mastery for the points we are about to answer
  const answeredPointIds = new Set()
  const answers = []
  let responseTime = 5000
  for (const scene of questionScenes) {
    const binding = scene.knowledgeBindings.find((entry) => entry.purpose === 'QUESTION')
    const correctChoice = scene.choices.find((choice) => choice.correct === true)
    assert(correctChoice, `场景 ${scene.sceneId} 缺少正确选项`)
    answeredPointIds.add(binding.knowledgePointId)
    answers.push({
      attemptId: randomUUID(),
      questionId: binding.questionId,
      knowledgePointId: binding.knowledgePointId,
      answerKind: 'CHOICE',
      choiceId: correctChoice.choiceId,
      correct: true,
      quality: 5,
      scoreDelta: correctChoice.scoreDelta,
      responseTimeMs: (responseTime += 811),
      hintsUsed: 0,
      attemptNumber: 1,
      occurredAt: new Date().toISOString(),
    })
  }

  async function masteryByPoint() {
    const scores = new Map()
    let cursor = null
    do {
      const query = cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''
      const page = expectSuccess(
        await api(`/api/v1/mastery-records?graphId=${graphId}&limit=100${query}`, { token }), '读取掌握度')
      for (const record of page.items) scores.set(record.pointId, record)
      cursor = page.nextCursor
    } while (cursor)
    return scores
  }
  const masteryBefore = await masteryByPoint()
  for (const pointId of answeredPointIds) {
    assert((masteryBefore.get(pointId)?.score ?? 0) === 0, '作答前掌握度应为 0')
  }

  // 7. events (with duplicate redelivery) + progress (with idempotent replay)
  const eventBatch = {
    events: answers.map((answer) => ({
      clientEventId: randomUUID(),
      type: 'CHOICE_SELECTED',
      occurredAt: new Date().toISOString(),
      payload: { questionId: answer.questionId, choiceId: answer.choiceId },
    })),
  }
  const receipt = expectSuccess(await api(`/api/v1/review-sessions/${session.sessionId}/events`, {
    method: 'POST', token, body: eventBatch,
  }), '追加事件')
  assert(receipt.accepted === answers.length && receipt.duplicates === 0, '事件首投全部接受')
  const redelivered = expectSuccess(await api(`/api/v1/review-sessions/${session.sessionId}/events`, {
    method: 'POST', token, body: eventBatch,
  }), '事件重投')
  assert(redelivered.accepted === 0 && redelivered.duplicates === answers.length, '事件重投全部去重')

  const visited = gamePackage.scenes.map((scene) => scene.sceneId)
  const progressInput = {
    expectedVersion: 0,
    currentSceneId: visited[visited.length - 1],
    visitedSceneIds: visited,
    runtimeState: { schemaVersion: 'render-runtime-state-1', sessionId: session.sessionId },
  }
  const savedProgress = expectSuccess(await api(`/api/v1/review-sessions/${session.sessionId}/progress`, {
    method: 'PUT', token, body: progressInput,
  }), '保存进度')
  assert(savedProgress.version === 1, '进度版本推进到 1')
  const replayedProgress = expectSuccess(await api(`/api/v1/review-sessions/${session.sessionId}/progress`, {
    method: 'PUT', token, body: progressInput,
  }), '进度重投')
  assert(replayedProgress.version === 1, '进度重投幂等返回原快照')

  // 8. result: accepted -> duplicate -> conflict
  const resultInput = {
    expectedProgressVersion: 1,
    idempotencyKey: randomUUID(),
    reviewPlanId: plan.reviewPlanId,
    snapshotVersion: plan.snapshotVersion,
    answerResults: answers,
    durationSeconds: 186,
  }
  const result = expectSuccess(await api(`/api/v1/review-sessions/${session.sessionId}/result`, {
    method: 'PUT', token, body: resultInput,
  }), '提交结果')
  assert(result.status === 'ACCEPTED', '首次结果 ACCEPTED')
  log(`result ${result.resultId} accepted`)

  const duplicate = expectSuccess(await api(`/api/v1/review-sessions/${session.sessionId}/result`, {
    method: 'PUT', token, body: resultInput,
  }), '结果重放')
  assert(duplicate.status === 'DUPLICATE' && duplicate.resultId === result.resultId,
    '相同载荷重放返回 DUPLICATE 与原 resultId')

  const conflict = await api(`/api/v1/review-sessions/${session.sessionId}/result`, {
    method: 'PUT', token, body: { ...resultInput, durationSeconds: 187 },
  })
  assert(conflict.status === 409 && conflict.body.error?.code === 'IDEMPOTENCY_CONFLICT',
    `冲突载荷应返回 409 IDEMPOTENCY_CONFLICT，实际 ${conflict.status} ${conflict.body.error?.code}`)

  const finalSession = expectSuccess(
    await api(`/api/v1/review-sessions/${session.sessionId}`, { token }), '读取最终会话')
  assert(finalSession.status === 'COMPLETED' && finalSession.completedAt, '会话已完成')

  // 9. mastery actually moved in KnowledgeService
  const masteryAfter = await masteryByPoint()
  for (const pointId of answeredPointIds) {
    const before = masteryBefore.get(pointId)
    const after = masteryAfter.get(pointId)
    assert(after && after.score > 0, `知识点 ${pointId} 掌握度应大于 0`)
    assert(after.version > (before?.version ?? 0), `知识点 ${pointId} 乐观版本应递增`)
    log(`mastery ${pointId}: ${before?.score ?? 0} -> ${after.score} (version ${after.version})`)
  }

  log(`PASS: ${answers.length} answers accepted, ${answeredPointIds.size} mastery records updated`)
}

main().catch((cause) => fail(cause?.stack || String(cause)))
