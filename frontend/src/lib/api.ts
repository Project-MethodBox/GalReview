import { clearSession, readSession, updateSessionTokens } from './session'
import { clearAdminSession, readAdminSession, updateAdminSessionTokens } from './adminSession'
import { createUuidV4 } from './uuid'
import type {
  ApiFailure,
  ApiSuccess,
  AdminCreditCode,
  AdminUser,
  AnswerResult,
  AuthSession,
  AuthSessionResponse,
  Chapter,
  GameGenerationJob,
  GamePackage,
  GamePackageManifest,
  GameStyle,
  Difficulty,
  ExtractedTextDocument,
  GraphBuildJob,
  IngestionJob,
  KnowledgeGraphSummary,
  KnowledgeGraphPage,
  KnowledgePoint,
  KnowledgePointPage,
  KnowledgeRelation,
  KnowledgeRelationPage,
  Material,
  MaterialPage,
  MasteryRecord,
  MasteryRecordPage,
  PlanGraph,
  ProgressSnapshot,
  ReviewResult,
  ReviewSession,
  RuntimeManifest,
  TokenPair,
  UserProfile,
  UserPreferences,
  UserPreferencesInput,
  CreateCreditCodeBatchInput,
  CreditBalance,
  StudyProject,
  PracticeProjectDetails,
  PracticeQuestion,
  PracticeQuestionKind,
  PracticeSession,
  PracticeAnswer,
  ExamPaper,
  PracticeJob,
  QuestionHelp,
  SharedPracticePackage,
} from '../types/api'

const configuredBase = import.meta.env.VITE_API_BASE_URL?.trim() || '/api/v1'
const API_BASE_URL = configuredBase.replace(/\/$/, '')
const DEFAULT_TIMEOUT_MS = 30_000
const UPLOAD_TIMEOUT_MS = 120_000
const QUESTION_BANK_TIMEOUT_MS = 600_000

export class ApiClientError extends Error {
  readonly code: string
  readonly status: number
  readonly traceId?: string
  readonly details: Record<string, unknown>

  constructor(message: string, code: string, status: number, traceId?: string, details: Record<string, unknown> = {}) {
    super(message)
    this.name = 'ApiClientError'
    this.code = code
    this.status = status
    this.traceId = traceId
    this.details = details
  }
}

interface RequestOptions extends RequestInit {
  authenticated?: boolean
  retryAfterRefresh?: boolean
  timeoutMs?: number
}

let refreshPromise: Promise<TokenPair> | null = null

const ERROR_MESSAGES: Record<string, string> = {
  AUTH_REQUIRED: '登录状态已失效，请重新登录。',
  TOKEN_EXPIRED: '登录状态已失效，请重新登录。',
  FORBIDDEN: '当前账户没有执行此操作的权限。',
  RESOURCE_NOT_FOUND: '请求的数据不存在或已被删除。',
  NOT_FOUND: '请求的数据不存在或已被删除。',
  VALIDATION_ERROR: '提交内容格式不正确，请检查后重试。',
  BUSINESS_RULE_VIOLATION: '当前内容不符合业务规则，请检查操作条件。',
  STATE_CONFLICT: '数据状态已经发生变化，请刷新后重试。',
  RATE_LIMITED: '操作过于频繁，请稍后再试。',
  FILE_TOO_LARGE: '文件大小超过允许上限。',
  MEDIA_TYPE_UNSUPPORTED: '暂不支持这种文件格式。',
  MATERIAL_TEXT_NOT_READY: '资料文字尚未提取完成，请稍后重试。',
  MATERIAL_TEXT_EXTRACTION_FAILED: '资料文字提取失败，请检查文件或 OCR 设置。',
  MATERIAL_ACCESS_DENIED: '当前账户无权访问这份资料。',
  FILE_SERVICE_UNAVAILABLE: '资料服务暂时不可用，请稍后重试。',
  REVIEW_PLAN_NOT_FOUND: '复习计划不存在或已失效。',
  REVIEW_PLAN_SNAPSHOT_MISMATCH: '复习计划版本已变化，请重新创建计划。',
  IDEMPOTENCY_KEY_REUSED: '请求标识已被用于不同操作，请重新发起。',
  CLIENT_CLOSED_REQUEST: '请求已取消。',
  SERVICE_UNAVAILABLE: '服务暂时不可用，请稍后重试。',
  UPSTREAM_CONTRACT_INVALID: '服务返回的数据格式异常，请联系维护人员。',
  PROFILE_DELETE_FAILED: '账户资料删除失败，账户尚未注销。',
  CREDITS_INSUFFICIENT: 'credits 不足，需要先兑换 credits。',
  REDEMPTION_CODE_UNAVAILABLE: '兑换码无效、已使用、已撤销或已过期。',
  INTERNAL_ERROR: '服务处理失败，请稍后重试。',
}

const STATUS_MESSAGES: Record<number, string> = {
  402: 'credits 不足，需要先兑换 credits。',
  400: '提交内容格式不正确，请检查后重试。',
  401: '登录状态已失效，请重新登录。',
  403: '当前账户没有执行此操作的权限。',
  404: '请求的数据不存在或已被删除。',
  409: '数据状态已经发生变化，请刷新后重试。',
  413: '文件大小超过允许上限。',
  415: '暂不支持这种文件格式。',
  422: '当前操作条件不满足，请检查输入内容。',
  429: '操作过于频繁，请稍后再试。',
  502: '上游服务响应异常，请稍后重试。',
  503: '服务暂时不可用，请稍后重试。',
  504: '服务响应超时，请稍后重试。',
}

function localizedErrorMessage(code: string, message: string, status: number): string {
  if (/[\u3400-\u9fff]/.test(message)) return message
  return ERROR_MESSAGES[code] || STATUS_MESSAGES[status] || '请求失败，请稍后重试。'
}

function resolveUrl(path: string): string {
  if (/^https?:\/\//i.test(path)) return path
  if (path.startsWith('/api/')) return path
  return `${API_BASE_URL}${path.startsWith('/') ? path : `/${path}`}`
}

/**
 * 该错误是否表示"服务端明确认定凭证无效"。只有这种情况才应清除本地会话；
 * 网络中断、超时、网关重启等瞬时故障（503/502）下刷新令牌通常仍然有效。
 */
function isAuthRejection(error: unknown): boolean {
  if (!(error instanceof ApiClientError)) return false
  if (error.status === 401 || error.status === 403) return true
  return error.code === 'AUTH_REQUIRED' || error.code === 'TOKEN_EXPIRED'
}

function errorFromPayload(payload: unknown, status: number, responseTraceId?: string): ApiClientError {
  if (payload && typeof payload === 'object' && 'error' in payload) {
    const failure = payload as ApiFailure
    if (failure.error && typeof failure.error.code === 'string' && typeof failure.error.message === 'string') {
      return new ApiClientError(
        localizedErrorMessage(failure.error.code, failure.error.message, status),
        failure.error.code,
        status,
        failure.traceId || responseTraceId,
        failure.error.details ?? {},
      )
    }
  }
  return new ApiClientError(STATUS_MESSAGES[status] || '请求失败，请稍后再试。', 'HTTP_ERROR', status, responseTraceId)
}

function traceIdFromResponse(response: Response): string | undefined {
  return response.headers.get('X-Correlation-Id')?.trim() || undefined
}

function nonJsonHttpError(response: Response, bodyText: string): ApiClientError {
  const status = response.status
  const traceId = traceIdFromResponse(response)
  let code = 'HTTP_ERROR'
  let message = `请求失败（HTTP ${status}）。`

  if (status === 413) {
    code = 'PAYLOAD_TOO_LARGE'
    message = '请求体超过入口代理允许的大小（HTTP 413）。'
  } else if (status === 502) {
    code = 'UPSTREAM_HTTP_ERROR'
    message = '入口代理无法连接上游服务（HTTP 502）。'
  } else if (status === 503) {
    code = 'SERVICE_UNAVAILABLE'
    message = '服务暂时不可用（HTTP 503）。'
  } else if (status === 504) {
    code = 'SERVICE_UNAVAILABLE'
    message = '入口代理等待上游服务超时（HTTP 504）。'
  }

  const normalizedBody = bodyText.replace(/\s+/g, ' ').trim()
  return new ApiClientError(message, code, status, traceId, {
    contentType: response.headers.get('Content-Type') || 'unknown',
    responseKind: /bad gateway/i.test(normalizedBody) ? 'BAD_GATEWAY' : 'NON_JSON',
  })
}

function parseResponseJson(response: Response, bodyText: string): unknown {
  try {
    return JSON.parse(bodyText) as unknown
  } catch {
    if (!response.ok) throw nonJsonHttpError(response, bodyText)
    throw new ApiClientError(
      '服务响应格式不符合契约。',
      'UPSTREAM_CONTRACT_INVALID',
      502,
      traceIdFromResponse(response),
      { contentType: response.headers.get('Content-Type') || 'unknown' },
    )
  }
}

async function refreshAccessToken(): Promise<TokenPair> {
  const refreshToken = readSession()?.tokens.refreshToken
  if (!refreshToken) throw new ApiClientError('登录状态已失效，请重新登录。', 'AUTH_REQUIRED', 401)
  if (!refreshPromise) {
    refreshPromise = request<TokenPair>('/auth/tokens', {
      method: 'POST',
      body: JSON.stringify({ refreshToken }),
      authenticated: false,
      retryAfterRefresh: false,
    }).then((tokens) => {
      updateSessionTokens(tokens)
      return tokens
    }).catch((error) => {
      // 只有服务端明确拒绝刷新令牌才清除会话。网关重启、超时等瞬时故障会被
      // 映射成 503，此时刷新令牌通常仍然有效，清除会话等于把用户无故踢下线。
      if (isAuthRejection(error)) clearSession()
      throw error
    }).finally(() => {
      refreshPromise = null
    })
  }
  return refreshPromise
}

async function request<T>(path: string, options: RequestOptions = {}): Promise<T> {
  const {
    authenticated = true,
    retryAfterRefresh = true,
    timeoutMs = DEFAULT_TIMEOUT_MS,
    ...init
  } = options
  const controller = new AbortController()
  const timeout = window.setTimeout(() => controller.abort(), timeoutMs)
  const headers = new Headers(init.headers)
  headers.set('Accept', 'application/json')
  headers.set('X-Correlation-Id', createUuidV4())
  if (init.body && !(init.body instanceof FormData)) headers.set('Content-Type', 'application/json')
  const token = readSession()?.tokens.accessToken
  if (authenticated && token) headers.set('Authorization', `Bearer ${token}`)

  try {
    const response = await fetch(resolveUrl(path), { ...init, headers, signal: controller.signal })
    const bodyText = response.status === 204 ? '' : await response.text()
    const payload = bodyText
      ? (parseResponseJson(response, bodyText) as ApiSuccess<T> | ApiFailure)
      : null

    if (response.status === 401 && authenticated && retryAfterRefresh) {
      await refreshAccessToken()
      return request<T>(path, { ...options, retryAfterRefresh: false })
    }
    if (!response.ok) {
      if (!payload) throw nonJsonHttpError(response, bodyText)
      throw errorFromPayload(payload, response.status, traceIdFromResponse(response))
    }
    if (!bodyText) return undefined as T
    if (!payload || typeof payload !== 'object' || !('data' in payload)) {
      throw new ApiClientError('服务响应格式不符合契约。', 'UPSTREAM_CONTRACT_INVALID', 502)
    }
    return payload.data as T
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') {
      throw new ApiClientError('请求超时，请稍后重试。', 'SERVICE_UNAVAILABLE', 503)
    }
    if (error instanceof TypeError) {
      throw new ApiClientError('无法连接服务，请确认后端已经启动。', 'SERVICE_UNAVAILABLE', 503)
    }
    throw error
  } finally {
    window.clearTimeout(timeout)
  }
}

async function requestRawJson<T>(path: string): Promise<T> {
  const controller = new AbortController()
  const timeout = window.setTimeout(() => controller.abort(), DEFAULT_TIMEOUT_MS)
  const headers = new Headers({
    Accept: 'application/json',
    'X-Correlation-Id': createUuidV4(),
  })
  const token = readSession()?.tokens.accessToken
  if (token) headers.set('Authorization', `Bearer ${token}`)
  try {
    const response = await fetch(resolveUrl(path), { headers, signal: controller.signal })
    const bodyText = response.status === 204 ? '' : await response.text()
    const payload = bodyText ? parseResponseJson(response, bodyText) : null
    if (!response.ok) {
      if (!payload) throw nonJsonHttpError(response, bodyText)
      throw errorFromPayload(payload, response.status, traceIdFromResponse(response))
    }
    if (!payload || typeof payload !== 'object') {
      throw new ApiClientError('游戏包响应格式不符合契约。', 'UPSTREAM_CONTRACT_INVALID', 502)
    }
    return payload as T
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') {
      throw new ApiClientError('请求超时，请稍后重试。', 'SERVICE_UNAVAILABLE', 503)
    }
    if (error instanceof TypeError) {
      throw new ApiClientError('无法连接服务，请确认后端已经启动。', 'SERVICE_UNAVAILABLE', 503)
    }
    throw error
  } finally {
    window.clearTimeout(timeout)
  }
}

async function requestBlob(path: string, retryAfterRefresh = true, accept = 'application/octet-stream', label = '文件'): Promise<Blob> {
  const controller = new AbortController()
  const timeout = window.setTimeout(() => controller.abort(), DEFAULT_TIMEOUT_MS)
  const headers = new Headers({
    Accept: accept,
    'X-Correlation-Id': createUuidV4(),
  })
  const token = readSession()?.tokens.accessToken
  if (token) headers.set('Authorization', `Bearer ${token}`)
  try {
    const response = await fetch(resolveUrl(path), { headers, signal: controller.signal })
    if (response.status === 401 && retryAfterRefresh) {
      await refreshAccessToken()
      return requestBlob(path, false, accept, label)
    }
    if (!response.ok) {
      const bodyText = await response.text()
      const contentType = response.headers.get('Content-Type') || ''
      const payload = bodyText && contentType.includes('json')
        ? parseResponseJson(response, bodyText)
        : null
      if (!payload) throw nonJsonHttpError(response, bodyText)
      throw errorFromPayload(payload, response.status, traceIdFromResponse(response))
    }
    return await response.blob()
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') {
      throw new ApiClientError(`${label}加载超时，请稍后重试。`, 'SERVICE_UNAVAILABLE', 503)
    }
    if (error instanceof TypeError) {
      throw new ApiClientError(`无法连接${label}服务。`, 'SERVICE_UNAVAILABLE', 503)
    }
    throw error
  } finally {
    window.clearTimeout(timeout)
  }
}

function json(body: unknown): string {
  return JSON.stringify(body)
}

function query(params: Record<string, string | number | undefined>): string {
  const search = new URLSearchParams()
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined) search.set(key, String(value))
  }
  const result = search.toString()
  return result ? `?${result}` : ''
}

function adminHeaders(): HeadersInit {
  const token = readAdminSession()?.tokens.accessToken
  return token ? { Authorization: `Bearer ${token}` } : {}
}

async function adminRequest<T>(path: string, options: RequestOptions = {}, retry = true): Promise<T> {
  try {
    return await request<T>(path, {
      ...options,
      authenticated: false,
      retryAfterRefresh: false,
      headers: { ...adminHeaders(), ...options.headers },
    })
  } catch (reason) {
    const refreshToken = readAdminSession()?.tokens.refreshToken
    if (!(reason instanceof ApiClientError) || reason.status !== 401 || !retry || !refreshToken) throw reason
    try {
      const tokens = await request<TokenPair>('/auth/tokens', {
        method: 'POST', authenticated: false, retryAfterRefresh: false, body: json({ refreshToken }),
      })
      updateAdminSessionTokens(tokens)
      return adminRequest<T>(path, options, false)
    } catch (refreshError) {
      // 同 refreshAccessToken：瞬时故障不等于刷新令牌失效，不能清除管理端会话
      if (isAuthRejection(refreshError)) clearAdminSession()
      throw refreshError
    }
  }
}

async function collectPages<T>(load: (cursor?: string) => Promise<{ items: T[]; nextCursor: string | null }>): Promise<T[]> {
  const items: T[] = []
  const seenCursors = new Set<string>()
  let cursor: string | undefined

  do {
    const page = await load(cursor)
    items.push(...page.items)
    if (!page.nextCursor) break
    if (seenCursors.has(page.nextCursor)) {
      throw new ApiClientError('分页游标重复，无法继续读取。', 'UPSTREAM_CONTRACT_INVALID', 502)
    }
    seenCursors.add(page.nextCursor)
    cursor = page.nextCursor
  } while (cursor)

  return items
}

export const api = {
  login(email: string, password: string): Promise<AuthSessionResponse> {
    return request('/auth/sessions', {
      method: 'POST',
      authenticated: false,
      body: json({ email, password, deviceName: navigator.userAgent.slice(0, 120) }),
    })
  },

  register(input: { email: string; password: string; displayName: string }): Promise<AuthSessionResponse> {
    return request('/auth/registrations', {
      method: 'POST',
      authenticated: false,
      body: json({
        ...input,
        deviceName: navigator.userAgent.slice(0, 120),
      }),
    })
  },

  requestPasswordReset(email: string): Promise<void> {
    return request('/auth/password-reset-requests', {
      method: 'POST',
      authenticated: false,
      body: json({ email }),
    })
  },

  resetPassword(resetToken: string, newPassword: string): Promise<void> {
    return request('/auth/password-resets', {
      method: 'POST',
      authenticated: false,
      body: json({ resetToken, newPassword }),
    })
  },

  logout(sessionId: string): Promise<void> {
    return request(`/auth/sessions/${encodeURIComponent(sessionId)}`, { method: 'DELETE' })
  },

  getSession(sessionId: string): Promise<AuthSession> {
    return request(`/auth/sessions/${encodeURIComponent(sessionId)}`)
  },

  getCurrentUser(): Promise<UserProfile> {
    return request('/users/me')
  },

  updateCurrentUser(input: { displayName?: string; locale?: string; preferredSubjectCodes?: string[] }): Promise<UserProfile> {
    return request('/users/me', { method: 'PATCH', body: json(input) })
  },

  getUserPreferences(): Promise<UserPreferences> {
    return request('/users/me/preferences')
  },

  updateUserPreferences(input: UserPreferencesInput): Promise<UserPreferences> {
    return request('/users/me/preferences', { method: 'PUT', body: json(input) })
  },

  changePassword(currentPassword: string, newPassword: string): Promise<void> {
    return request('/auth/password-changes', { method: 'POST', body: json({ currentPassword, newPassword }) })
  },

  deleteAccount(currentPassword: string): Promise<void> {
    return request('/auth/account', { method: 'DELETE', body: json({ currentPassword }) })
  },

  listMaterials(cursor?: string, filters: { status?: string; subjectCode?: string } = {}): Promise<MaterialPage> {
    return request(`/materials${query({ limit: 100, cursor, status: filters.status, subjectCode: filters.subjectCode })}`)
  },

  getAllMaterials(): Promise<Material[]> {
    return collectPages<Material>((cursor) => request(`/materials${query({ limit: 100, cursor })}`))
  },

  getMaterial(materialId: string): Promise<Material> {
    return request(`/materials/${encodeURIComponent(materialId)}`)
  },

  getExtractedTextPreview(materialId: string): Promise<ExtractedTextDocument> {
    return request(`/materials/${encodeURIComponent(materialId)}/extracted-text-preview`)
  },

  uploadMaterial(file: File, displayName?: string, subjectCode?: string): Promise<Material> {
    const body = new FormData()
    body.append('file', file)
    if (displayName?.trim()) body.append('displayName', displayName.trim())
    if (subjectCode?.trim()) body.append('subjectCode', subjectCode.trim().toUpperCase())
    return request('/materials', { method: 'POST', body, timeoutMs: UPLOAD_TIMEOUT_MS })
  },

  deleteMaterial(materialId: string): Promise<void> {
    return request(`/materials/${encodeURIComponent(materialId)}`, { method: 'DELETE' })
  },

  createIngestionJob(
    materialId: string,
    options: { force?: boolean; enableOcr?: boolean; ocrMode?: 'quick' | 'standard' } = {},
  ): Promise<IngestionJob> {
    return request(`/materials/${encodeURIComponent(materialId)}/ingestion-jobs`, {
      method: 'POST',
      body: json({
        parserVersion: options.enableOcr ? 'files-ocr-v1' : 'files-text-v1',
        force: options.force ?? false,
        enableOcr: options.enableOcr ?? false,
        ocrMode: options.ocrMode ?? 'standard',
      }),
    })
  },

  getIngestionJob(jobId: string): Promise<IngestionJob> {
    return request(`/ingestion-jobs/${encodeURIComponent(jobId)}`)
  },

  createGraphBuild(studyProjectId: string, materialId: string, subjectHint?: string): Promise<GraphBuildJob> {
    return request('/knowledge-graph-builds', {
      method: 'POST',
      headers: { 'Idempotency-Key': createUuidV4() },
      body: json({
        materialId,
        studyProjectId,
        subjectHint: subjectHint?.trim().toUpperCase() || undefined,
        segmentationMode: 'AUTO',
        extractorVersion: 'knowledge-extractor-v3',
      }),
    })
  },

  getGraphBuild(buildId: string): Promise<GraphBuildJob> {
    return request(`/knowledge-graph-builds/${encodeURIComponent(buildId)}`)
  },

  getKnowledgeGraph(graphId: string): Promise<KnowledgeGraphSummary> {
    return request(`/knowledge-graphs/${encodeURIComponent(graphId)}`)
  },

  listKnowledgeGraphs(studyProjectId: string, cursor?: string): Promise<KnowledgeGraphPage> {
    return request(`/knowledge-graphs${query({ studyProjectId, limit: 100, cursor })}`)
  },

  getAllKnowledgeGraphs(studyProjectId: string): Promise<KnowledgeGraphSummary[]> {
    return collectPages<KnowledgeGraphSummary>((cursor) =>
      request(`/knowledge-graphs${query({ studyProjectId, limit: 100, cursor })}`),
    )
  },

  getChapters(graphId: string): Promise<Chapter[]> {
    return request(`/knowledge-graphs/${encodeURIComponent(graphId)}/chapters`)
  },

  getPoints(graphId: string, cursor?: string): Promise<KnowledgePointPage> {
    return request(`/knowledge-graphs/${encodeURIComponent(graphId)}/points${query({ limit: 100, cursor })}`)
  },

  getAllPoints(graphId: string): Promise<KnowledgePoint[]> {
    return collectPages<KnowledgePoint>((cursor) =>
      request(`/knowledge-graphs/${encodeURIComponent(graphId)}/points${query({ limit: 100, cursor })}`),
    )
  },

  getKnowledgePoint(pointId: string): Promise<KnowledgePoint> {
    return request(`/knowledge-points/${encodeURIComponent(pointId)}`)
  },

  getRelations(graphId: string, cursor?: string): Promise<KnowledgeRelationPage> {
    return request(`/knowledge-graphs/${encodeURIComponent(graphId)}/relations${query({ limit: 100, cursor })}`)
  },

  getAllRelations(graphId: string): Promise<KnowledgeRelation[]> {
    return collectPages<KnowledgeRelation>((cursor) =>
      request(`/knowledge-graphs/${encodeURIComponent(graphId)}/relations${query({ limit: 100, cursor })}`),
    )
  },

  getMasteryRecords(graphId: string, cursor?: string): Promise<MasteryRecordPage> {
    return request(`/mastery-records${query({ graphId, limit: 100, cursor })}`)
  },

  getAllMasteryRecords(graphId: string): Promise<MasteryRecord[]> {
    return collectPages<MasteryRecord>((cursor) =>
      request(`/mastery-records${query({ graphId, limit: 100, cursor })}`),
    )
  },

  createAssessmentPlan(
    graphId: string,
    chapterIds: string[],
    options: { maxQuestions?: number; coverageTarget?: number; maximumInferenceDepth?: number } = {},
  ): Promise<PlanGraph> {
    return request('/assessment-plans', {
      method: 'POST',
      body: json({
        graphId,
        chapterIds,
        maxQuestions: options.maxQuestions ?? 6,
        coverageTarget: options.coverageTarget ?? 0.8,
        maximumInferenceDepth: options.maximumInferenceDepth ?? 3,
      }),
    })
  },

  createLearningPlan(
    graphId: string,
    chapterIds: string[],
    options: { maxPoints?: number; maximumDependencyDepth?: number } = {},
  ): Promise<PlanGraph> {
    return request('/learning-plans', {
      method: 'POST',
      body: json({
        graphId,
        chapterIds,
        maxPoints: options.maxPoints ?? 12,
        maximumDependencyDepth: options.maximumDependencyDepth ?? 5,
      }),
    })
  },

  getReviewPlan(reviewPlanId: string): Promise<PlanGraph> {
    return request(`/review-plans/${encodeURIComponent(reviewPlanId)}`)
  },

  createGameGeneration(plan: PlanGraph, style: GameStyle, difficulty: Difficulty): Promise<GameGenerationJob> {
    return request('/game-generations', {
      method: 'POST',
      // 比 Gateway 超时略长，优先展示后端的结构化失败信息。
      timeoutMs: 65_000,
      body: json({
        reviewPlanId: plan.reviewPlanId,
        snapshotVersion: plan.snapshotVersion,
        style,
        difficulty,
        locale: 'zh-CN',
      }),
    })
  },

  getGameGeneration(generationId: string): Promise<GameGenerationJob> {
    return request(`/game-generations/${encodeURIComponent(generationId)}`)
  },

  getGamePackage(packageId: string): Promise<GamePackageManifest> {
    return request(`/game-packages/${encodeURIComponent(packageId)}`)
  },

  getGamePackageContent(contentUrl: string): Promise<GamePackage> {
    return requestRawJson<GamePackage>(contentUrl)
  },

  getGameAudio(audioUrl: string): Promise<Blob> {
    return requestBlob(audioUrl, true, 'audio/wav, audio/*', '语音')
  },

  getRuntimeManifest(): Promise<RuntimeManifest> {
    return request('/render-runtime/manifest', { authenticated: false })
  },

  createReviewSession(packageId: string, clientRuntimeVersion: string): Promise<ReviewSession> {
    return request('/review-sessions', {
      method: 'POST',
      body: json({ packageId, clientRuntimeVersion }),
    })
  },

  getReviewSession(sessionId: string): Promise<ReviewSession> {
    return request(`/review-sessions/${encodeURIComponent(sessionId)}`)
  },

  saveProgress(
    sessionId: string,
    input: { expectedVersion: number; currentSceneId: string; visitedSceneIds: string[]; runtimeState: Record<string, unknown> },
  ): Promise<ProgressSnapshot> {
    return request(`/review-sessions/${encodeURIComponent(sessionId)}/progress`, {
      method: 'PUT',
      body: json(input),
    })
  },

  appendEvents(sessionId: string, events: Array<{ clientEventId: string; type: string; occurredAt: string; payload: Record<string, unknown> }>): Promise<{ accepted: number; duplicates: number }> {
    return request(`/review-sessions/${encodeURIComponent(sessionId)}/events`, {
      method: 'POST',
      body: json({ events }),
    })
  },

  submitReviewResult(
    sessionId: string,
    input: {
      expectedProgressVersion: number
      idempotencyKey: string
      reviewPlanId: string
      snapshotVersion: string
      answerResults: AnswerResult[]
      durationSeconds: number
    },
  ): Promise<ReviewResult> {
    return request(`/review-sessions/${encodeURIComponent(sessionId)}/result`, {
      method: 'PUT',
      body: json(input),
    })
  },

  listPracticeProjects(): Promise<{ items: StudyProject[]; nextCursor: string | null }> {
    return request('/practice-projects')
  },

  createPracticeProject(input: { name: string; subjectCode?: string; materialIds: string[]; graphId?: null }): Promise<StudyProject> {
    return request('/practice-projects', { method: 'POST', body: json(input) })
  },

  updatePracticeProject(project: StudyProject, input: { name?: string; subjectCode?: string; materialIds?: string[]; graphId?: string }): Promise<StudyProject> {
    return request(`/practice-projects/${encodeURIComponent(project.projectId)}`, {
      method: 'PATCH', body: json({ ...input, version: project.version }),
    })
  },

  getPracticeProject(projectId: string): Promise<PracticeProjectDetails> {
    return request(`/practice-projects/${encodeURIComponent(projectId)}`)
  },

  listPracticeQuestions(projectId: string): Promise<{ items: PracticeQuestion[]; nextCursor: string | null }> {
    return request(`/practice-projects/${encodeURIComponent(projectId)}/questions`)
  },

  createPracticeQuestion(projectId: string, input: {
    kind: PracticeQuestionKind; prompt: string; options: Array<{ id: string; text: string }>; correctAnswers: string[]
    explanation?: string; score: number; difficulty: number; knowledgePointId?: string; status: 'DRAFT' | 'READY'
  }): Promise<PracticeQuestion> {
    return request(`/practice-projects/${encodeURIComponent(projectId)}/questions`, { method: 'POST', body: json({ ...input, sourceReferences: [] }) })
  },

  updatePracticeQuestion(question: PracticeQuestion, status: 'DRAFT' | 'READY'): Promise<PracticeQuestion> {
    return request(`/practice-questions/${encodeURIComponent(question.questionId)}`, {
      method: 'PATCH', body: json({ kind: question.kind, prompt: question.prompt, options: question.options,
        correctAnswers: question.correctAnswers, explanation: question.explanation, score: question.score,
        difficulty: question.difficulty, knowledgePointId: question.knowledgePointId,
        sourceReferences: question.sourceReferences, status, version: question.version }),
    })
  },

  createPracticeSession(input: { projectId: string; mode: 'RANDOM' | 'SMART_REVIEW' | 'EXAM'; questionCount?: number; examPaperId?: string; reviewPlanId?: string; snapshotVersion?: string }): Promise<PracticeSession> {
    return request('/practice-sessions', { method: 'POST', body: json({ ...input, kinds: [] }) })
  },

  getPracticeSession(sessionId: string): Promise<PracticeSession> {
    return request(`/practice-sessions/${encodeURIComponent(sessionId)}`)
  },

  savePracticeAnswer(sessionId: string, questionId: string, answer: string[], responseTimeMs: number, attemptNumber = 1): Promise<PracticeAnswer> {
    return request(`/practice-sessions/${encodeURIComponent(sessionId)}/answers/${encodeURIComponent(questionId)}`, {
      method: 'PUT', body: json({ answer, responseTimeMs, attemptNumber, idempotencyKey: createUuidV4() }),
    })
  },

  completePracticeSession(sessionId: string): Promise<{ session: PracticeSession; evidence: unknown }> {
    return request(`/practice-sessions/${encodeURIComponent(sessionId)}/completion`, { method: 'POST', body: json({ idempotencyKey: createUuidV4() }) })
  },

  createExamPaper(projectId: string, input: { title: string; questionCount: number; durationSeconds: number; reviewPlanId: string; snapshotVersion: string }): Promise<ExamPaper> {
    return request(`/practice-projects/${encodeURIComponent(projectId)}/exam-papers`, { method: 'POST', body: json(input) })
  },

  generatePracticeQuestions(projectId: string, input: { reviewPlanId: string; snapshotVersion: string; kinds: PracticeQuestionKind[]; targetCount?: number }): Promise<PracticeJob> {
    return request(`/practice-projects/${encodeURIComponent(projectId)}/question-generations`, {
      method: 'POST', body: json({ ...input, idempotencyKey: createUuidV4(), generatorVersion: 'recite-question-v2' }), timeoutMs: QUESTION_BANK_TIMEOUT_MS,
    })
  },

  importExam(projectId: string, materialId: string): Promise<PracticeJob> {
    return request('/exam-import-jobs', { method: 'POST', body: json({ projectId, materialId, idempotencyKey: createUuidV4() }), timeoutMs: UPLOAD_TIMEOUT_MS })
  },

  getQuestionHelp(questionId: string, generateExplanation = false): Promise<QuestionHelp> {
    return request(`/practice-questions/${encodeURIComponent(questionId)}/help`, { method: 'POST', body: json({ generateExplanation }) })
  },

  importPracticePackage(file: File, materialIds: string[]): Promise<{ project: StudyProject; importedQuestionCount: number; importedFromSchema: string; diagnostics: string[] }> {
    const body = new FormData(); body.append('file', file); materialIds.forEach((id) => body.append('materialIds', id))
    return request('/practice-packages/imports', { method: 'POST', body, timeoutMs: UPLOAD_TIMEOUT_MS })
  },

  exportPracticePackage(projectId: string): Promise<Blob> {
    return requestBlob(`/practice-projects/${encodeURIComponent(projectId)}/package`)
  },

  publishPracticePackage(projectId: string, version: string, visibility: 'PRIVATE' | 'UNLISTED' | 'PUBLIC'): Promise<SharedPracticePackage> {
    return request(`/practice-projects/${encodeURIComponent(projectId)}/publications`, { method: 'POST', body: json({ version, visibility }) })
  },

  listSharedPracticePackages(query?: string): Promise<{ items: SharedPracticePackage[]; nextCursor: string | null }> {
    const params = new URLSearchParams(); if (query?.trim()) params.set('query', query.trim())
    return request(`/shared-practice-packages${params.size ? `?${params}` : ''}`)
  },

  getSharedPracticePackageContent(packageId: string): Promise<Blob> {
    return requestBlob(`/shared-practice-packages/${encodeURIComponent(packageId)}/content`)
  },

  adminLogin(username: string, password: string): Promise<AuthSessionResponse> {
    return request('/admin/sessions', {
      method: 'POST',
      authenticated: false,
      body: json({ username, password }),
    })
  },

  adminLogout(sessionId: string): Promise<void> {
    return adminRequest(`/auth/sessions/${encodeURIComponent(sessionId)}`, {
      method: 'DELETE',
    })
  },

  listAdminUsers(): Promise<AdminUser[]> {
    return adminRequest('/admin/users')
  },

  deleteAdminUser(userId: string): Promise<void> {
    return adminRequest(`/admin/users/${encodeURIComponent(userId)}`, {
      method: 'DELETE',
    })
  },

  resetAdminUserPassword(userId: string, newPassword: string): Promise<void> {
    return adminRequest(`/admin/users/${encodeURIComponent(userId)}/password`, {
      method: 'POST', body: json({ newPassword }),
    })
  },

  getCreditBalance(): Promise<CreditBalance> {
    return request('/credits/balance')
  },

  redeemCredits(code: string): Promise<CreditBalance> {
    return request('/credits/redemptions', { method: 'POST', body: json({ code }) })
  },

  listAdminCreditCodes(): Promise<{ items: AdminCreditCode[] }> {
    return adminRequest('/admin/credit-codes')
  },

  createAdminCreditCodeBatch(input: CreateCreditCodeBatchInput): Promise<{ items: AdminCreditCode[] }> {
    return adminRequest('/admin/credit-codes/batches', {
      method: 'POST', body: json(input),
    })
  },

  revokeAdminCreditCode(codeId: string): Promise<void> {
    return adminRequest(`/admin/credit-codes/${encodeURIComponent(codeId)}`, {
      method: 'DELETE',
    })
  },
}
