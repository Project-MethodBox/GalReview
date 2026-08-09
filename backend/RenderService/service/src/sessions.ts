// ReviewSession domain logic (contract.md §8.1/§8.2/§8.2.1).
//
// Storage is ephemeral-memory by explicit v1 decision (same baseline as
// GalGameService): sessions, progress and result receipts live in process
// memory and are lost on restart. /readyz reports storage=ephemeral-memory;
// production persistence is a later, documented milestone.
//
// Every method returns { ok: true, status, body } for success or
// { ok: false, status, code, message, details } for failures; the HTTP
// layer wraps these into the contract envelopes.
import { createHash, randomUUID } from 'node:crypto'

import type {
  EventReceipt,
  GamePackage,
  KnowledgeAnswerEvidence,
  ProgressSnapshot,
  ReviewResult,
  ReviewResultStatus,
  ReviewSession,
  ReviewSessionStatus,
} from './contract.js'
import { isNonEmptyString, isRecord, isUuidV4 } from './contract.js'
import type { GatewayClient, UpstreamFailure } from './gateway-client.js'

export const SESSION_LIMITS = Object.freeze({
  maxAnswerResults: 100,
  maxEventBatch: 100,
  maxStoredEventIds: 10_000,
  maxVisitedScenes: 500,
  maxRuntimeStateBytes: 256 * 1024,
  maxDurationSeconds: 86_400,
  maxResponseTimeMs: 86_400_000,
})

const MAX_SESSIONS = 1000

const ANSWER_KINDS = new Set(['CHOICE', 'FILL_BLANK', 'TRUE_FALSE', 'SHORT_ANSWER', 'OTHER'])
const EVENT_TYPES = new Set(['SCENE_ENTERED', 'CHOICE_SELECTED', 'RUNTIME_ERROR'])

export type DomainResult<T> =
  | { ok: true; status: number; body: T }
  | { ok: false; status: number; code: string; message: string; details: Record<string, unknown> }

interface QuestionDigest {
  knowledgePointId: string
  sceneId: string
  choices: Map<string, boolean>
}

interface PackageDigest {
  entrySceneId: string
  sceneIds: Set<string>
  questions: Map<string, QuestionDigest>
  hasQuestions: boolean
}

interface StoredResult {
  resultId: string
  idempotencyKey: string
  checksum: string
  status: ReviewResultStatus
  submittedAt: string
}

interface SessionRecord {
  sessionId: string
  userId: string
  packageId: string
  reviewPlanId: string
  snapshotVersion: string
  clientRuntimeVersion: string
  status: ReviewSessionStatus
  currentSceneId: string | null
  progressVersion: number
  startedAt: string | null
  completedAt: string | null
  createdAt: string
  updatedAt: number
  digest: PackageDigest
  snapshot: ProgressSnapshot | null
  snapshotChecksum: string | null
  eventIds: Set<string>
  result: StoredResult | null
  pendingResult: { idempotencyKey: string; checksum: string; resultId: string } | null
  isSubmitting: boolean
}

interface ValidatedAnswer {
  attemptId: string
  questionId: string
  knowledgePointId: string
  answerKind: string
  choiceId: string | null
  correct: boolean
  quality: number
  scoreDelta: number | null
  responseTimeMs: number
  hintsUsed: number
  attemptNumber: number
  occurredAt: string
}

export interface SessionServiceOptions {
  gateway: GatewayClient
  now?: () => Date
  newId?: () => string
}

function failure(
  status: number, code: string, message: string, details: Record<string, unknown> = {},
): { ok: false; status: number; code: string; message: string; details: Record<string, unknown> } {
  return { ok: false, status, code, message, details }
}

function validationError(message: string, details: Record<string, unknown> = {}) {
  return failure(400, 'VALIDATION_ERROR', message, details)
}

const isInt = (value: unknown): value is number =>
  typeof value === 'number' && Number.isInteger(value)

// Canonical JSON with sorted object keys, so logically identical payloads
// hash identically regardless of member order.
function canonicalize(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalize).join(',')}]`
  if (isRecord(value)) {
    const keys = Object.keys(value).sort()
    return `{${keys.map((key) => `${JSON.stringify(key)}:${canonicalize(value[key])}`).join(',')}}`
  }
  return JSON.stringify(value)
}

const checksumOf = (value: unknown): string =>
  createHash('sha256').update(canonicalize(value)).digest('hex')

// Digest of the authoritative package: everything the session endpoints need
// to verify client claims without re-reading GalGameService.
function digestPackage(pkg: GamePackage): PackageDigest {
  const sceneIds = new Set<string>()
  const questions = new Map<string, QuestionDigest>()
  for (const scene of pkg.scenes) {
    if (!isRecord(scene) || typeof scene.sceneId !== 'string') continue
    sceneIds.add(scene.sceneId)
    const bindings = Array.isArray(scene.knowledgeBindings) ? scene.knowledgeBindings : []
    const questionBinding = bindings.find(
      (binding) => isRecord(binding) && binding.purpose === 'QUESTION')
    if (!questionBinding || typeof questionBinding.questionId !== 'string') continue
    const choices = new Map<string, boolean>()
    for (const choice of Array.isArray(scene.choices) ? scene.choices : []) {
      if (isRecord(choice) && typeof choice.choiceId === 'string') {
        choices.set(choice.choiceId, choice.correct === true)
      }
    }
    questions.set(questionBinding.questionId, {
      knowledgePointId: String(questionBinding.knowledgePointId),
      sceneId: scene.sceneId,
      choices,
    })
  }
  return { entrySceneId: pkg.entrySceneId, sceneIds, questions, hasQuestions: questions.size > 0 }
}

function sessionView(record: SessionRecord): ReviewSession {
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

export interface SessionService {
  create(input: { userId: string; body: unknown; correlationId?: string }): Promise<DomainResult<ReviewSession>>
  get(input: { userId: string; sessionId: string }): DomainResult<ReviewSession>
  saveProgress(input: { userId: string; sessionId: string; body: unknown }): DomainResult<ProgressSnapshot>
  appendEvents(input: { userId: string; sessionId: string; body: unknown }): DomainResult<EventReceipt>
  submitResult(input: {
    userId: string; sessionId: string; body: unknown; correlationId?: string
  }): Promise<DomainResult<ReviewResult>>
  stats(): { sessions: number; storage: 'ephemeral-memory' }
}

export function createSessionService(options: SessionServiceOptions): SessionService {
  const { gateway } = options
  const now = options.now ?? (() => new Date())
  const newId = options.newId ?? randomUUID
  const sessions = new Map<string, SessionRecord>()

  function evictOldSessions(): void {
    if (sessions.size > MAX_SESSIONS) {
      const oldest = [...sessions.entries()]
        .sort(([, a], [, b]) => a.updatedAt - b.updatedAt)
        .slice(0, sessions.size - MAX_SESSIONS)
      for (const [id] of oldest) {
        sessions.delete(id)
      }
    }
  }

  function findOwned(sessionId: string, userId: string): SessionRecord | null {
    const record = sessions.get(sessionId)
    // Missing and not-owned are indistinguishable to the caller (§5.1 style).
    if (!record || record.userId !== userId) return null
    return record
  }

  function markRunning(record: SessionRecord): void {
    if (record.status === 'CREATED') {
      record.status = 'RUNNING'
      record.startedAt = now().toISOString()
    }
    record.updatedAt = Date.now()
  }

  function mapUpstreamFailure(result: UpstreamFailure, context: string) {
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
      if (!isRecord(body)) return validationError('请求体必须是 JSON 对象')
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

      const record: SessionRecord = {
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
        updatedAt: Date.now(),
        digest: digestPackage(read.package),
        snapshot: null,
        snapshotChecksum: null,
        eventIds: new Set(),
        result: null,
        pendingResult: null,
        isSubmitting: false,
      }
      sessions.set(record.sessionId, record)
      evictOldSessions()
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
      if (!isRecord(body)) return validationError('请求体必须是 JSON 对象')
      if (!isInt(body.expectedVersion) || body.expectedVersion < 0) {
        return validationError('expectedVersion 必须是非负整数')
      }
      if (!isNonEmptyString(body.currentSceneId)) return validationError('currentSceneId 必须是非空字符串')
      if (!Array.isArray(body.visitedSceneIds)
          || body.visitedSceneIds.some((id: unknown) => !isNonEmptyString(id))) {
        return validationError('visitedSceneIds 必须是非空字符串数组')
      }
      const visitedSceneIds = body.visitedSceneIds as string[]
      if (!isRecord(body.runtimeState)) return validationError('runtimeState 必须是 JSON 对象')

      const record = findOwned(sessionId, userId)
      if (!record) return failure(404, 'RESOURCE_NOT_FOUND', '复习会话不存在')

      if (visitedSceneIds.length > SESSION_LIMITS.maxVisitedScenes) {
        return failure(422, 'BUSINESS_RULE_VIOLATION',
          `visitedSceneIds 不能超过 ${SESSION_LIMITS.maxVisitedScenes} 项`)
      }
      const stateBytes = Buffer.byteLength(JSON.stringify(body.runtimeState))
      if (stateBytes > SESSION_LIMITS.maxRuntimeStateBytes) {
        return failure(422, 'PROGRESS_STATE_TOO_LARGE',
          `runtimeState 序列化后不能超过 ${SESSION_LIMITS.maxRuntimeStateBytes} 字节`,
          { actualBytes: stateBytes })
      }
      if (!record.digest.sceneIds.has(body.currentSceneId)) {
        return failure(422, 'PROGRESS_SCENE_UNKNOWN', 'currentSceneId 不属于本会话的游戏包')
      }
      for (const sceneId of visitedSceneIds) {
        if (!record.digest.sceneIds.has(sceneId)) {
          return failure(422, 'PROGRESS_SCENE_UNKNOWN', `visitedSceneIds 含未知场景 ${sceneId}`)
        }
      }

      const inputChecksum = checksumOf({
        currentSceneId: body.currentSceneId,
        visitedSceneIds,
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
        visitedSceneIds: [...visitedSceneIds],
        runtimeState: body.runtimeState,
        savedAt: now().toISOString(),
      }
      record.snapshotChecksum = inputChecksum
      return { ok: true, status: 200, body: record.snapshot }
    },

    appendEvents({ userId, sessionId, body }) {
      if (!isUuidV4(sessionId)) return validationError('sessionId 必须是小写 UUID v4')
      if (!isRecord(body) || !Array.isArray(body.events) || body.events.length === 0) {
        return validationError('events 必须是非空数组')
      }
      const events = body.events as unknown[]
      if (events.length > SESSION_LIMITS.maxEventBatch) {
        return failure(422, 'EVENT_BATCH_TOO_LARGE',
          `单批事件不能超过 ${SESSION_LIMITS.maxEventBatch} 条`)
      }
      const clientEventIds: string[] = []
      for (const [index, event] of events.entries()) {
        if (!isRecord(event)) return validationError(`events[${index}] 必须是对象`)
        if (!isUuidV4(event.clientEventId)) {
          return validationError(`events[${index}].clientEventId 必须是小写 UUID v4`)
        }
        if (typeof event.type !== 'string' || !EVENT_TYPES.has(event.type)) {
          return validationError(`events[${index}].type 不受支持`)
        }
        if (!isNonEmptyString(event.occurredAt) || Number.isNaN(Date.parse(event.occurredAt))) {
          return validationError(`events[${index}].occurredAt 必须是 ISO 8601 时间`)
        }
        if (!isRecord(event.payload)) return validationError(`events[${index}].payload 必须是 JSON 对象`)
        clientEventIds.push(event.clientEventId)
      }

      const record = findOwned(sessionId, userId)
      if (!record) return failure(404, 'RESOURCE_NOT_FOUND', '复习会话不存在')
      if (record.status === 'COMPLETED' || record.status === 'ABANDONED') {
        return failure(409, 'STATE_CONFLICT', '会话已结束，无法追加事件')
      }
      if (record.eventIds.size >= SESSION_LIMITS.maxStoredEventIds) {
        return failure(422, 'BUSINESS_RULE_VIOLATION', '本会话的事件数量已达到上限')
      }

      let accepted = 0
      let duplicates = 0
      for (const clientEventId of clientEventIds) {
        if (record.eventIds.has(clientEventId)) {
          duplicates += 1
        } else {
          record.eventIds.add(clientEventId)
          accepted += 1
        }
      }
      if (accepted > 0) markRunning(record)
      return { ok: true, status: 202, body: { accepted, duplicates } }
    },

    async submitResult({ userId, sessionId, body, correlationId }) {
      if (!isUuidV4(sessionId)) return validationError('sessionId 必须是小写 UUID v4')
      if (!isRecord(body)) return validationError('请求体必须是 JSON 对象')
      if (!isInt(body.expectedProgressVersion) || body.expectedProgressVersion < 0) {
        return validationError('expectedProgressVersion 必须是非负整数')
      }
      if (!isUuidV4(body.idempotencyKey)) return validationError('idempotencyKey 必须是小写 UUID v4')
      if (!isUuidV4(body.reviewPlanId)) return validationError('reviewPlanId 必须是小写 UUID v4')
      if (!isNonEmptyString(body.snapshotVersion)) return validationError('snapshotVersion 必须是非空字符串')
      if (!Array.isArray(body.answerResults)) return validationError('answerResults 必须是数组')
      if (!isInt(body.durationSeconds)) return validationError('durationSeconds 必须是整数')

      // Shape of each answer first (400), ranges and consistency later (422).
      const answers: ValidatedAnswer[] = []
      for (const [index, raw] of (body.answerResults as unknown[]).entries()) {
        const path = `answerResults[${index}]`
        if (!isRecord(raw)) return validationError(`${path} 必须是对象`)
        if (!isUuidV4(raw.attemptId)) return validationError(`${path}.attemptId 必须是小写 UUID v4`)
        if (!isUuidV4(raw.questionId)) return validationError(`${path}.questionId 必须是小写 UUID v4`)
        if (!isUuidV4(raw.knowledgePointId)) {
          return validationError(`${path}.knowledgePointId 必须是小写 UUID v4`)
        }
        if (typeof raw.answerKind !== 'string' || !ANSWER_KINDS.has(raw.answerKind)) {
          return validationError(`${path}.answerKind 不受支持`)
        }
        if (raw.choiceId !== null && !isNonEmptyString(raw.choiceId)) {
          return validationError(`${path}.choiceId 必须是 null 或非空字符串`)
        }
        if (typeof raw.correct !== 'boolean') return validationError(`${path}.correct 必须是布尔值`)
        if (!isInt(raw.quality)) return validationError(`${path}.quality 必须是整数`)
        if (!isInt(raw.responseTimeMs)) return validationError(`${path}.responseTimeMs 必须是整数`)
        if (!isInt(raw.hintsUsed)) return validationError(`${path}.hintsUsed 必须是整数`)
        if (!isInt(raw.attemptNumber)) return validationError(`${path}.attemptNumber 必须是整数`)
        if (!isNonEmptyString(raw.occurredAt) || Number.isNaN(Date.parse(raw.occurredAt))) {
          return validationError(`${path}.occurredAt 必须是 ISO 8601 时间`)
        }
        answers.push({
          attemptId: raw.attemptId,
          questionId: raw.questionId,
          knowledgePointId: raw.knowledgePointId,
          answerKind: raw.answerKind,
          choiceId: raw.choiceId === null ? null : (raw.choiceId as string),
          correct: raw.correct,
          quality: raw.quality,
          scoreDelta: typeof raw.scoreDelta === 'number' ? raw.scoreDelta : null,
          responseTimeMs: raw.responseTimeMs,
          hintsUsed: raw.hintsUsed,
          attemptNumber: raw.attemptNumber,
          occurredAt: raw.occurredAt,
        })
      }

      const record = findOwned(sessionId, userId)
      if (!record) return failure(404, 'RESOURCE_NOT_FOUND', '复习会话不存在')

      // Range and consistency checks (422).
      if (body.durationSeconds < 0 || body.durationSeconds > SESSION_LIMITS.maxDurationSeconds) {
        return failure(422, 'RESULT_EVIDENCE_INVALID', 'durationSeconds 超出允许范围')
      }
      if (answers.length > SESSION_LIMITS.maxAnswerResults) {
        return failure(422, 'RESULT_EVIDENCE_INVALID',
          `answerResults 不能超过 ${SESSION_LIMITS.maxAnswerResults} 项`)
      }
      const attemptIds = new Set<string>()
      for (const [index, answer] of answers.entries()) {
        const path = `answerResults[${index}]`
        if (attemptIds.has(answer.attemptId)) {
          return failure(422, 'RESULT_EVIDENCE_INVALID', `${path}.attemptId 在本次提交内重复`)
        }
        attemptIds.add(answer.attemptId)
        if (answer.quality < 0 || answer.quality > 5) {
          return failure(422, 'RESULT_EVIDENCE_INVALID', `${path}.quality 必须在 0-5 之间`)
        }
        if (answer.responseTimeMs < 0 || answer.responseTimeMs > SESSION_LIMITS.maxResponseTimeMs) {
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
          return failure(422, 'ANSWER_QUESTION_NOT_IN_PACKAGE',
            `${path}.questionId 不在本会话的游戏包中`)
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
      if (!record.digest.hasQuestions && answers.length > 0) {
        return failure(422, 'RESULT_ANSWERS_NOT_ALLOWED', '纯讲解包的 answerResults 必须为空')
      }

      const resultChecksum = checksumOf({
        reviewPlanId: body.reviewPlanId,
        snapshotVersion: body.snapshotVersion,
        durationSeconds: body.durationSeconds,
        answerResults: answers.map((answer) => ({
          ...answer,
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

      if (record.isSubmitting) {
        return failure(409, 'STATE_CONFLICT', '会话正在提交结果，请勿重复提交')
      }
      record.isSubmitting = true
      try {
        // resultId must stay stable across retries of the same submission
        // (§8.2.1: retries must not mint new resultIds).
        let resultId: string
        if (record.pendingResult && record.pendingResult.idempotencyKey === body.idempotencyKey) {
          resultId = record.pendingResult.resultId
        } else {
          resultId = newId()
          record.pendingResult = { idempotencyKey: body.idempotencyKey, checksum: resultChecksum, resultId }
        }

        const submittedAt = now().toISOString()
        if (answers.length > 0) {
          const evidence = await gateway.submitEvidence(resultId, {
            resultId,
            idempotencyKey: body.idempotencyKey,
            reviewPlanId: record.reviewPlanId,
            snapshotVersion: record.snapshotVersion,
            sessionId: record.sessionId,
            packageId: record.packageId,
            userId: record.userId,
            completedAt: submittedAt,
            durationSeconds: body.durationSeconds,
            answerResults: answers.map((answer): KnowledgeAnswerEvidence => ({
              attemptId: answer.attemptId,
              questionId: answer.questionId,
              knowledgePointId: answer.knowledgePointId,
              answerKind: answer.answerKind as KnowledgeAnswerEvidence['answerKind'],
              correct: answer.correct,
              quality: answer.quality,
              responseTimeMs: answer.responseTimeMs,
              hintsUsed: answer.hintsUsed,
              attemptNumber: answer.attemptNumber,
              occurredAt: answer.occurredAt,
            })),
          }, correlationId)
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
        }
        // 纯讲解包（或没有任何实际作答）：按 §8.2.1 不调用 evidence 接口，
        // 掌握度保持不变，会话仍可正常完成。

        record.status = 'COMPLETED'
        record.completedAt = submittedAt
        record.updatedAt = Date.now()
        record.result = {
          resultId,
          idempotencyKey: body.idempotencyKey,
          checksum: resultChecksum,
          status: 'ACCEPTED',
          submittedAt,
        }
        record.pendingResult = null

        return {
          ok: true,
          status: 200,
          body: { resultId, sessionId: record.sessionId, status: 'ACCEPTED', submittedAt },
        }
      } finally {
        record.isSubmitting = false
      }
    },

    // Diagnostics for /readyz and tests.
    stats() {
      return { sessions: sessions.size, storage: 'ephemeral-memory' }
    },
  }
}
