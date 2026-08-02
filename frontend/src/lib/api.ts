import { clearSession, readSession, updateSessionTokens } from './session'
import { createUuidV4 } from './uuid'
import type {
  ApiFailure,
  ApiSuccess,
  AnswerResult,
  AuthSessionResponse,
  Chapter,
  GameGenerationJob,
  GamePackage,
  GamePackageManifest,
  GameStyle,
  Difficulty,
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
  PlanGraph,
  ProgressSnapshot,
  ReviewResult,
  ReviewSession,
  RuntimeManifest,
  TokenPair,
  UserProfile,
  UserPreferences,
  UserPreferencesInput,
} from '../types/api'

const configuredBase = import.meta.env.VITE_API_BASE_URL?.trim() || '/api/v1'
const API_BASE_URL = configuredBase.replace(/\/$/, '')
const DEFAULT_TIMEOUT_MS = 30_000
const UPLOAD_TIMEOUT_MS = 120_000

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

function resolveUrl(path: string): string {
  if (/^https?:\/\//i.test(path)) return path
  if (path.startsWith('/api/')) return path
  return `${API_BASE_URL}${path.startsWith('/') ? path : `/${path}`}`
}

function errorFromPayload(payload: unknown, status: number, responseTraceId?: string): ApiClientError {
  if (payload && typeof payload === 'object' && 'error' in payload) {
    const failure = payload as ApiFailure
    if (failure.error && typeof failure.error.code === 'string' && typeof failure.error.message === 'string') {
      return new ApiClientError(
        failure.error.message,
        failure.error.code,
        status,
        failure.traceId || responseTraceId,
        failure.error.details ?? {},
      )
    }
  }
  return new ApiClientError('请求失败，请稍后再试。', 'HTTP_ERROR', status, responseTraceId)
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
      clearSession()
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

  register(input: { email: string; password: string; displayName: string; invitationCode: string }): Promise<AuthSessionResponse> {
    return request('/auth/registrations', {
      method: 'POST',
      authenticated: false,
      body: json({
        ...input,
        invitationCode: input.invitationCode.trim().toUpperCase(),
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

  listMaterials(cursor?: string): Promise<MaterialPage> {
    return request(`/materials${query({ limit: 100, cursor })}`)
  },

  getAllMaterials(): Promise<Material[]> {
    return collectPages<Material>((cursor) => request(`/materials${query({ limit: 100, cursor })}`))
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

  createGraphBuild(materialId: string, subjectHint?: string): Promise<GraphBuildJob> {
    return request('/knowledge-graph-builds', {
      method: 'POST',
      headers: { 'Idempotency-Key': createUuidV4() },
      body: json({
        materialId,
        subjectHint: subjectHint?.trim().toUpperCase() || undefined,
        segmentationMode: 'AUTO',
        extractorVersion: 'knowledge-extractor-v2',
      }),
    })
  },

  getGraphBuild(buildId: string): Promise<GraphBuildJob> {
    return request(`/knowledge-graph-builds/${encodeURIComponent(buildId)}`)
  },

  getKnowledgeGraph(graphId: string): Promise<KnowledgeGraphSummary> {
    return request(`/knowledge-graphs/${encodeURIComponent(graphId)}`)
  },

  listKnowledgeGraphs(materialId: string, cursor?: string): Promise<KnowledgeGraphPage> {
    return request(`/knowledge-graphs${query({ materialId, limit: 100, cursor })}`)
  },

  getAllKnowledgeGraphs(materialId: string): Promise<KnowledgeGraphSummary[]> {
    return collectPages<KnowledgeGraphSummary>((cursor) =>
      request(`/knowledge-graphs${query({ materialId, limit: 100, cursor })}`),
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

  getRelations(graphId: string, cursor?: string): Promise<KnowledgeRelationPage> {
    return request(`/knowledge-graphs/${encodeURIComponent(graphId)}/relations${query({ limit: 100, cursor })}`)
  },

  getAllRelations(graphId: string): Promise<KnowledgeRelation[]> {
    return collectPages<KnowledgeRelation>((cursor) =>
      request(`/knowledge-graphs/${encodeURIComponent(graphId)}/relations${query({ limit: 100, cursor })}`),
    )
  },

  createAssessmentPlan(graphId: string, chapterIds: string[]): Promise<PlanGraph> {
    return request('/assessment-plans', {
      method: 'POST',
      body: json({ graphId, chapterIds, maxQuestions: 6, coverageTarget: 0.8, maximumInferenceDepth: 3 }),
    })
  },

  createLearningPlan(graphId: string, chapterIds: string[]): Promise<PlanGraph> {
    return request('/learning-plans', {
      method: 'POST',
      body: json({ graphId, chapterIds, maxPoints: 12, maximumDependencyDepth: 5 }),
    })
  },

  getReviewPlan(reviewPlanId: string): Promise<PlanGraph> {
    return request(`/review-plans/${encodeURIComponent(reviewPlanId)}`)
  },

  createGameGeneration(plan: PlanGraph, style: GameStyle, difficulty: Difficulty): Promise<GameGenerationJob> {
    return request('/game-generations', {
      method: 'POST',
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
}
