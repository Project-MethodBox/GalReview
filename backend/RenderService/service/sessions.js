// ReviewSession domain logic (contract.md §8.1/§8.2/§8.2.1).
//
// Storage is ephemeral-memory by explicit v1 decision (same baseline as
// GalGameService): sessions, progress and result receipts live in process
// memory and are lost on restart. /readyz reports storage=ephemeral-memory;
// production persistence is a later, documented milestone.
//
// Every method returns { ok: true, status, body } for success or
// { ok: false, status, code, message, details? } for failures; the HTTP
// layer wraps these into the contract envelopes.

import { randomUUID, createHash } from 'node:crypto'

const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const ANSWER_KINDS = new Set(['CHOICE', 'FILL_BLANK', 'TRUE_FALSE', 'SHORT_ANSWER', 'OTHER'])
const EVENT_TYPES = new Set(['SCENE_ENTERED', 'CHOICE_SELECTED', 'RUNTIME_ERROR'])

const LIMITS = Object.freeze({
  maxAnswerResults: 100,
  maxEventBatch: 100,
  maxStoredEventIds: 10_000,
  maxVisitedScenes: 500,
  maxRuntimeStateBytes: 256 * 1024,
  maxDurationSeconds: 86_400,
  maxResponseTimeMs: 86_400_000,
})

const isUuidV4 = (value) => typeof value === 'string' && UUID_V4.test(value)
const isNonEmptyString = (value) => typeof value === 'string' && value.trim().length > 0
const isInt = (value) => typeof value === 'number' && Number.isInteger(value)
const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value)

function failure(status, code, message, details = {}) {
  return { ok: false, status, code, message, details }
}

function validationError(message, details = {}) {
  return failure(400, 'VALIDATION_ERROR', message, details)
}

// Canonical JSON with sorted object keys, so logically identical payloads
// hash identically regardless of member order.
function canonicalize(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalize).join(',')}]`
  if (isObject(value)) {
    const keys = Object.keys(value).sort()
    return `{${keys.map((key) => `${JSON.stringify(key)}:${canonicalize(value[key])}`).join(',')}}`
  }
  return JSON.stringify(value)
}

const checksumOf = (value) => createHash('sha256').update(canonicalize(value)).digest('hex')

// Digest of the authoritative package: everything the session endpoints need
// to verify client claims without re-reading GalGameService.
function digestPackage(pkg) {
  const sceneIds = new Set()
  const questions = new Map() // questionId -> { knowledgePointId, sceneId, choices: Map<choiceId, correct> }
  for (const scene of pkg.scenes) {
    if (!isObject(scene) || typeof scene.sceneId !== 'string') continue
    sceneIds.add(scene.sceneId)
    const bindings = Array.isArray(scene.knowledgeBindings) ? scene.knowledgeBindings : []
    const questionBinding = bindings.find((binding) => isObject(binding) && binding.purpose === 'QUESTION')
    if (!questionBinding) continue
    const choices = new Map()
    for (const choice of Array.isArray(scene.choices) ? scene.choices : []) {
      if (isObject(choice) && typeof choice.choiceId === 'string') {
        choices.set(choice.choiceId, choice.correct === true)
      }
    }
    questions.set(questionBinding.questionId, {
      knowledgePointId: questionBinding.knowledgePointId,
      sceneId: scene.sceneId,
      choices,
    })
  }
  return { entrySceneId: pkg.entrySceneId, sceneIds, questions, hasQuestions: questions.size > 0 }
}

function sessionView(record) {
  return {
    sessionId: record.sessionId,
    userId: record.userId,
    packageId: record.packageId,
    reviewPlanId: record.reviewPlanId,
    snapshotVersion: record.snapshotVersion,
    status: record.status,
    currentSceneId: record.currentSceneId,
    progressVersion: record.progressVersion,
    startedAt: record.startedAt,
    completedAt: record.completedAt,
  }
}

export function createSessionService({ gateway, now = () => new Date(), newId = randomUUID }) {
  const sessions = new Map() // sessionId -> record

  function findOwned(sessionId, userId) {
    const record = sessions.get(sessionId)
    // Missing and not-owned are indistinguishable to the caller (§5.1 style).
    if (!record || record.userId !== userId) return null
    return record
  }

  function markRunning(record) {
    if (record.status === 'CREATED') {
      record.status = 'RUNNING'
      record.startedAt = now().toISOString()
    }
  }

  function mapUpstreamFailure(result, context) {
    switch (result.kind) {
      case 'not_found':
        return failure(422, 'GAME_PACKAGE_NOT_FOUND', `${context}：游戏包不存在或不属于当前用户`)
      case 'contract':
        return failure(502, 'UPSTREAM_CONTRACT_INVALID', `${context}：上游返回违反契约的数据（${result.message}）`)
      case 'forbidden':
        return failure(503, 'SERVICE_UNAVAILABLE', `${context}：服务身份配置不可用`)
      case 'invalid':
        return failure(502, 'UPSTREAM_CONTRACT_INVALID', `${context}：上游拒绝了本服务构造的请求（${result.code}）`)
      default:
        return failure(503, 'SERVICE_UNAVAILABLE', `${context}：依赖暂不可用`)
    }
  }

  return {
    async create({ userId, body, correlationId }) {
      if (!isObject(body)) return validationError('请求体必须是 JSON 对象')
      if (!isUuidV4(body.packageId)) return validationError('packageId 必须是小写 UUID v4')
      if (!isNonEmptyString(body.clientRuntimeVersion)) {
        return validationError('clientRuntimeVersion 必须是非空字符串')
      }

      const read = await gateway.readGamePackage(body.packageId, userId, correlationId)
      if (!read.ok) return mapUpstreamFailure(read, '读取权威游戏包失败')

      const validation = await gateway.validateGamePackage(read.package, correlationId)
      if (!validation.ok) return mapUpstreamFailure(validation, '校验权威游戏包失败')
      if (!validation.valid) {
        return failure(502, 'UPSTREAM_CONTRACT_INVALID',
          '权威游戏包未通过共同校验器', { errors: validation.errors.slice(0, 5) })
      }

      const record = {
        sessionId: newId(),
        userId,
        packageId: body.packageId,
        // Frozen from the authoritative package; result submissions must
        // echo these exact values (§8.2.1).
        reviewPlanId: read.package.reviewPlanId,
        snapshotVersion: read.package.snapshotVersion,
        clientRuntimeVersion: body.clientRuntimeVersion.trim(),
        status: 'CREATED',
        currentSceneId: null,
        progressVersion: 0,
        startedAt: null,
        completedAt: null,
        createdAt: now().toISOString(),
        digest: digestPackage(read.package),
        snapshot: null,
        snapshotChecksum: null,
        eventIds: new Set(),
        result: null, // { resultId, idempotencyKey, checksum, status, submittedAt }
        pendingResult: null, // { idempotencyKey, checksum, resultId }
      }
      sessions.set(record.sessionId, record)
      return { ok: true, status: 201, body: sessionView(record) }
    },

    get({ userId, sessionId }) {
      if (!isUuidV4(sessionId)) return validationError('sessionId 必须是小写 UUID v4')
      const record = findOwned(sessionId, userId)
      if (!record) return failure(404, 'RESOURCE_NOT_FOUND', '复习会话不存在')
      return { ok: true, status: 200, body: sessionView(record) }
    },

    saveProgress({ userId, sessionId, body }) {
      if (!isUuidV4(sessionId)) return validationError('sessionId 必须是小写 UUID v4')
      if (!isObject(body)) return validationError('请求体必须是 JSON 对象')
      if (!isInt(body.expectedVersion) || body.expectedVersion < 0) {
        return validationError('expectedVersion 必须是非负整数')
      }
      if (!isNonEmptyString(body.currentSceneId)) return validationError('currentSceneId 必须是非空字符串')
      if (!Array.isArray(body.visitedSceneIds) || body.visitedSceneIds.some((id) => !isNonEmptyString(id))) {
        return validationError('visitedSceneIds 必须是非空字符串数组')
      }
      if (!isObject(body.runtimeState)) return validationError('runtimeState 必须是 JSON 对象')

      const record = findOwned(sessionId, userId)
      if (!record) return failure(404, 'RESOURCE_NOT_FOUND', '复习会话不存在')

      if (body.visitedSceneIds.length > LIMITS.maxVisitedScenes) {
        return failure(422, 'BUSINESS_RULE_VIOLATION', `visitedSceneIds 不能超过 ${LIMITS.maxVisitedScenes} 项`)
      }
      const stateBytes = Buffer.byteLength(JSON.stringify(body.runtimeState))
      if (stateBytes > LIMITS.maxRuntimeStateBytes) {
        return failure(422, 'PROGRESS_STATE_TOO_LARGE',
          `runtimeState 序列化后不能超过 ${LIMITS.maxRuntimeStateBytes} 字节`, { actualBytes: stateBytes })
      }
      if (!record.digest.sceneIds.has(body.currentSceneId)) {
        return failure(422, 'PROGRESS_SCENE_UNKNOWN', 'currentSceneId 不属于本会话的游戏包')
      }
      for (const sceneId of body.visitedSceneIds) {
        if (!record.digest.sceneIds.has(sceneId)) {
          return failure(422, 'PROGRESS_SCENE_UNKNOWN', `visitedSceneIds 含未知场景 ${sceneId}`)
        }
      }

      const inputChecksum = checksumOf({
        currentSceneId: body.currentSceneId,
        visitedSceneIds: body.visitedSceneIds,
        runtimeState: body.runtimeState,
      })
      // Idempotent replay: the retry of the immediately previous save (same
      // content, same expectedVersion) returns the stored snapshot instead
      // of a version conflict (§8.1 幂等保存进度).
      if (record.snapshot
          && body.expectedVersion === record.snapshot.version - 1
          && inputChecksum === record.snapshotChecksum) {
        return { ok: true, status: 200, body: record.snapshot }
      }
      if (record.status === 'COMPLETED' || record.status === 'ABANDONED') {
        return failure(409, 'STATE_CONFLICT', '会话已结束，无法继续保存进度')
      }
      if (body.expectedVersion !== record.progressVersion) {
        return failure(409, 'VERSION_CONFLICT', '进度版本不一致',
          { expectedVersion: record.progressVersion })
      }

      markRunning(record)
      record.progressVersion += 1
      record.currentSceneId = body.currentSceneId
      record.snapshot = {
        sessionId: record.sessionId,
        version: record.progressVersion,
        currentSceneId: body.currentSceneId,
        visitedSceneIds: [...body.visitedSceneIds],
        runtimeState: body.runtimeState,
        savedAt: now().toISOString(),
      }
      record.snapshotChecksum = inputChecksum
      return { ok: true, status: 200, body: record.snapshot }
    },

    appendEvents({ userId, sessionId, body }) {
      if (!isUuidV4(sessionId)) return validationError('sessionId 必须是小写 UUID v4')
      if (!isObject(body) || !Array.isArray(body.events) || body.events.length === 0) {
        return validationError('events 必须是非空数组')
      }
      if (body.events.length > LIMITS.maxEventBatch) {
        return failure(422, 'EVENT_BATCH_TOO_LARGE', `单批事件不能超过 ${LIMITS.maxEventBatch} 条`)
      }
      for (const [index, event] of body.events.entries()) {
        if (!isObject(event)) return validationError(`events[${index}] 必须是对象`)
        if (!isUuidV4(event.clientEventId)) return validationError(`events[${index}].clientEventId 必须是小写 UUID v4`)
        if (!EVENT_TYPES.has(event.type)) return validationError(`events[${index}].type 不受支持`)
        if (!isNonEmptyString(event.occurredAt) || Number.isNaN(Date.parse(event.occurredAt))) {
          return validationError(`events[${index}].occurredAt 必须是 ISO 8601 时间`)
        }
        if (!isObject(event.payload)) return validationError(`events[${index}].payload 必须是 JSON 对象`)
      }

      const record = findOwned(sessionId, userId)
      if (!record) return failure(404, 'RESOURCE_NOT_FOUND', '复习会话不存在')
      if (record.status === 'COMPLETED' || record.status === 'ABANDONED') {
        return failure(409, 'STATE_CONFLICT', '会话已结束，无法追加事件')
      }
      if (record.eventIds.size >= LIMITS.maxStoredEventIds) {
        return failure(422, 'BUSINESS_RULE_VIOLATION', '本会话的事件数量已达到上限')
      }

      let accepted = 0
      let duplicates = 0
      for (const event of body.events) {
        if (record.eventIds.has(event.clientEventId)) {
          duplicates += 1
        } else {
          record.eventIds.add(event.clientEventId)
          accepted += 1
        }
      }
      if (accepted > 0) markRunning(record)
      return { ok: true, status: 202, body: { accepted, duplicates } }
    },

    async submitResult({ userId, sessionId, body, correlationId }) {
      if (!isUuidV4(sessionId)) return validationError('sessionId 必须是小写 UUID v4')
      if (!isObject(body)) return validationError('请求体必须是 JSON 对象')
      if (!isInt(body.expectedProgressVersion) || body.expectedProgressVersion < 0) {
        return validationError('expectedProgressVersion 必须是非负整数')
      }
      if (!isUuidV4(body.idempotencyKey)) return validationError('idempotencyKey 必须是小写 UUID v4')
      if (!isUuidV4(body.reviewPlanId)) return validationError('reviewPlanId 必须是小写 UUID v4')
      if (!isNonEmptyString(body.snapshotVersion)) return validationError('snapshotVersion 必须是非空字符串')
      if (!Array.isArray(body.answerResults)) return validationError('answerResults 必须是数组')
      if (!isInt(body.durationSeconds)) return validationError('durationSeconds 必须是整数')

      // Shape of each answer first (400), ranges and consistency later (422).
      for (const [index, answer] of body.answerResults.entries()) {
        const path = `answerResults[${index}]`
        if (!isObject(answer)) return validationError(`${path} 必须是对象`)
        if (!isUuidV4(answer.attemptId)) return validationError(`${path}.attemptId 必须是小写 UUID v4`)
        if (!isUuidV4(answer.questionId)) return validationError(`${path}.questionId 必须是小写 UUID v4`)
        if (!isUuidV4(answer.knowledgePointId)) return validationError(`${path}.knowledgePointId 必须是小写 UUID v4`)
        if (!ANSWER_KINDS.has(answer.answerKind)) return validationError(`${path}.answerKind 不受支持`)
        if (answer.choiceId !== null && !isNonEmptyString(answer.choiceId)) {
          return validationError(`${path}.choiceId 必须是 null 或非空字符串`)
        }
        if (typeof answer.correct !== 'boolean') return validationError(`${path}.correct 必须是布尔值`)
        if (!isInt(answer.quality)) return validationError(`${path}.quality 必须是整数`)
        if (!isInt(answer.responseTimeMs)) return validationError(`${path}.responseTimeMs 必须是整数`)
        if (!isInt(answer.hintsUsed)) return validationError(`${path}.hintsUsed 必须是整数`)
        if (!isInt(answer.attemptNumber)) return validationError(`${path}.attemptNumber 必须是整数`)
        if (!isNonEmptyString(answer.occurredAt) || Number.isNaN(Date.parse(answer.occurredAt))) {
          return validationError(`${path}.occurredAt 必须是 ISO 8601 时间`)
        }
      }

      const record = findOwned(sessionId, userId)
      if (!record) return failure(404, 'RESOURCE_NOT_FOUND', '复习会话不存在')

      // Range and consistency checks (422).
      if (body.durationSeconds < 0 || body.durationSeconds > LIMITS.maxDurationSeconds) {
        return failure(422, 'RESULT_EVIDENCE_INVALID', 'durationSeconds 超出允许范围')
      }
      if (body.answerResults.length > LIMITS.maxAnswerResults) {
        return failure(422, 'RESULT_EVIDENCE_INVALID', `answerResults 不能超过 ${LIMITS.maxAnswerResults} 项`)
      }
      const attemptIds = new Set()
      for (const [index, answer] of body.answerResults.entries()) {
        const path = `answerResults[${index}]`
        if (attemptIds.has(answer.attemptId)) {
          return failure(422, 'RESULT_EVIDENCE_INVALID', `${path}.attemptId 在本次提交内重复`)
        }
        attemptIds.add(answer.attemptId)
        if (answer.quality < 0 || answer.quality > 5) {
          return failure(422, 'RESULT_EVIDENCE_INVALID', `${path}.quality 必须在 0-5 之间`)
        }
        if (answer.responseTimeMs < 0 || answer.responseTimeMs > LIMITS.maxResponseTimeMs) {
          return failure(422, 'RESULT_EVIDENCE_INVALID', `${path}.responseTimeMs 超出允许范围`)
        }
        if (answer.hintsUsed < 0 || answer.hintsUsed > 100) {
          return failure(422, 'RESULT_EVIDENCE_INVALID', `${path}.hintsUsed 超出允许范围`)
        }
        if (answer.attemptNumber < 1 || answer.attemptNumber > 100) {
          return failure(422, 'RESULT_EVIDENCE_INVALID', `${path}.attemptNumber 超出允许范围`)
        }
        // The fixed quality mapping of §6.4, enforced before evidence leaves
        // this service: wrong answers cap at 2, right answers start at 3,
        // hint usage caps at 3.
        if (!answer.correct && answer.quality > 2) {
          return failure(422, 'RESULT_EVIDENCE_INVALID', `${path} 错误作答的 quality 不得高于 2`)
        }
        if (answer.correct && answer.quality < 3) {
          return failure(422, 'RESULT_EVIDENCE_INVALID', `${path} 正确作答的 quality 不得低于 3`)
        }
        if (answer.hintsUsed > 0 && answer.quality > 3) {
          return failure(422, 'RESULT_EVIDENCE_INVALID', `${path} 使用提示后的 quality 不得高于 3`)
        }
        // Package-binding truth: the question must exist, the point must
        // match its binding, and CHOICE answers must reference a real choice
        // whose correct flag matches the claim (§7.3.1 / §6.4 义务).
        const question = record.digest.questions.get(answer.questionId)
        if (!question) {
          return failure(422, 'ANSWER_QUESTION_NOT_IN_PACKAGE', `${path}.questionId 不在本会话的游戏包中`)
        }
        if (question.knowledgePointId !== answer.knowledgePointId) {
          return failure(422, 'ANSWER_POINT_MISMATCH', `${path}.knowledgePointId 与游戏包绑定不一致`)
        }
        if (answer.answerKind === 'CHOICE') {
          if (answer.choiceId === null || !question.choices.has(answer.choiceId)) {
            return failure(422, 'ANSWER_CHOICE_UNKNOWN', `${path}.choiceId 不在题目场景的选项中`)
          }
          if (question.choices.get(answer.choiceId) !== answer.correct) {
            return failure(422, 'ANSWER_CORRECT_MISMATCH', `${path}.correct 与游戏包选项不一致`)
          }
        }
      }
      if (!record.digest.hasQuestions && body.answerResults.length > 0) {
        return failure(422, 'RESULT_ANSWERS_NOT_ALLOWED', '纯讲解包的 answerResults 必须为空')
      }

      const resultChecksum = checksumOf({
        reviewPlanId: body.reviewPlanId,
        snapshotVersion: body.snapshotVersion,
        durationSeconds: body.durationSeconds,
        answerResults: body.answerResults.map((answer) => ({
          attemptId: answer.attemptId,
          questionId: answer.questionId,
          knowledgePointId: answer.knowledgePointId,
          answerKind: answer.answerKind,
          choiceId: answer.choiceId,
          correct: answer.correct,
          quality: answer.quality,
          scoreDelta: answer.scoreDelta ?? null,
          responseTimeMs: answer.responseTimeMs,
          hintsUsed: answer.hintsUsed,
          attemptNumber: answer.attemptNumber,
          occurredAt: new Date(answer.occurredAt).toISOString(),
        })),
      })

      // Read-only idempotency pre-check before any state validation, mirroring
      // KnowledgeService §6.4: an exact replay must succeed even after the
      // session closed.
      if (record.result) {
        if (record.result.idempotencyKey === body.idempotencyKey
            && record.result.checksum === resultChecksum) {
          return {
            ok: true,
            status: 200,
            body: {
              resultId: record.result.resultId,
              sessionId: record.sessionId,
              status: 'DUPLICATE',
              submittedAt: record.result.submittedAt,
            },
          }
        }
        return failure(409, 'IDEMPOTENCY_CONFLICT', '本会话已提交过不同的结果载荷')
      }
      if (record.pendingResult && record.pendingResult.idempotencyKey === body.idempotencyKey
          && record.pendingResult.checksum !== resultChecksum) {
        return failure(409, 'IDEMPOTENCY_CONFLICT', '同一幂等键不能携带不同的结果载荷')
      }

      // The browser cannot substitute the frozen plan identity (§8.2.1).
      if (body.reviewPlanId !== record.reviewPlanId) {
        return failure(422, 'RESULT_PLAN_MISMATCH', 'reviewPlanId 与会话冻结值不一致')
      }
      if (body.snapshotVersion !== record.snapshotVersion) {
        return failure(409, 'SNAPSHOT_VERSION_CONFLICT', 'snapshotVersion 与会话冻结值不一致')
      }
      if (record.status === 'ABANDONED') {
        return failure(409, 'STATE_CONFLICT', '会话已放弃，无法提交结果')
      }
      if (body.expectedProgressVersion !== record.progressVersion) {
        return failure(409, 'VERSION_CONFLICT', '进度版本不一致',
          { expectedVersion: record.progressVersion })
      }

      // resultId must stay stable across retries of the same submission
      // (§8.2.1: retries must not mint new resultIds).
      let resultId
      if (record.pendingResult && record.pendingResult.idempotencyKey === body.idempotencyKey) {
        resultId = record.pendingResult.resultId
      } else {
        resultId = newId()
        record.pendingResult = { idempotencyKey: body.idempotencyKey, checksum: resultChecksum, resultId }
      }

      const submittedAt = now().toISOString()
      let receiptStatus = 'ACCEPTED'
      if (body.answerResults.length > 0) {
        const submission = {
          resultId,
          idempotencyKey: body.idempotencyKey,
          reviewPlanId: record.reviewPlanId,
          snapshotVersion: record.snapshotVersion,
          sessionId: record.sessionId,
          packageId: record.packageId,
          userId: record.userId,
          completedAt: submittedAt,
          durationSeconds: body.durationSeconds,
          answerResults: body.answerResults.map((answer) => ({
            attemptId: answer.attemptId,
            questionId: answer.questionId,
            knowledgePointId: answer.knowledgePointId,
            answerKind: answer.answerKind,
            correct: answer.correct,
            quality: answer.quality,
            responseTimeMs: answer.responseTimeMs,
            hintsUsed: answer.hintsUsed,
            attemptNumber: answer.attemptNumber,
            occurredAt: answer.occurredAt,
          })),
        }
        const evidence = await gateway.submitEvidence(resultId, submission, correlationId)
        if (!evidence.ok) {
          // The session stays open and pendingResult keeps the resultId, so
          // a retry reuses the same identity instead of minting a new one.
          switch (evidence.kind) {
            case 'conflict':
              return failure(409, evidence.code || 'STATE_CONFLICT',
                `KnowledgeService 拒绝了学习证据：${evidence.message}`)
            case 'not_found':
              return failure(422, 'REVIEW_PLAN_NOT_FOUND', '复习计划不存在或已失效')
            case 'invalid':
              return failure(422, evidence.code || 'REVIEW_EVIDENCE_INVALID',
                `KnowledgeService 拒绝了学习证据：${evidence.message}`)
            case 'contract':
              return failure(502, 'UPSTREAM_CONTRACT_INVALID',
                `KnowledgeService 返回违反契约的数据（${evidence.message}）`)
            case 'forbidden':
              return failure(503, 'SERVICE_UNAVAILABLE', '服务身份配置不可用')
            default:
              return failure(503, 'SERVICE_UNAVAILABLE', 'KnowledgeService 暂不可用，请稍后重试')
          }
        }
        receiptStatus = 'ACCEPTED'
      }
      // 纯讲解包（或没有任何实际作答）：按 §8.2.1 不调用 evidence 接口，
      // 掌握度保持不变，会话仍可正常完成。

      record.status = 'COMPLETED'
      record.completedAt = submittedAt
      record.result = {
        resultId,
        idempotencyKey: body.idempotencyKey,
        checksum: resultChecksum,
        status: receiptStatus,
        submittedAt,
      }
      record.pendingResult = null

      return {
        ok: true,
        status: 200,
        body: { resultId, sessionId: record.sessionId, status: receiptStatus, submittedAt },
      }
    },

    // Diagnostics for /readyz and tests.
    stats() {
      return { sessions: sessions.size, storage: 'ephemeral-memory' }
    },
  }
}

export { LIMITS as SESSION_LIMITS }
