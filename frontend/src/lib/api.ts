import { readSession } from './session'
import type {
  ApiFailure,
  ApiSuccess,
  AuthSessionResponse,
  UserProfile,
} from '../types/api'

const configuredBase = import.meta.env.VITE_API_BASE_URL?.trim() || '/api/v1'
const API_BASE_URL = configuredBase.replace(/\/$/, '')

export const demoFallbackEnabled =
  import.meta.env.DEV && import.meta.env.VITE_ENABLE_DEMO_FALLBACK !== 'false'

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

export function isNetworkError(error: unknown): boolean {
  return error instanceof TypeError
    || (error instanceof DOMException && error.name === 'AbortError')
    || (error instanceof ApiClientError && error.code === 'HTTP_ERROR' && error.status >= 500)
}

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const controller = new AbortController()
  const timeout = window.setTimeout(() => controller.abort(), 15_000)
  const token = readSession()?.tokens.accessToken
  const headers = new Headers(init.headers)
  headers.set('Accept', 'application/json')
  headers.set('X-Correlation-Id', crypto.randomUUID())
  if (init.body && !(init.body instanceof FormData)) headers.set('Content-Type', 'application/json')
  if (token && !token.startsWith('demo-')) headers.set('Authorization', `Bearer ${token}`)

  try {
    const response = await fetch(`${API_BASE_URL}${path}`, {
      ...init,
      headers,
      signal: controller.signal,
    })

    if (response.status === 204) return undefined as T

    const payload = (await response.json().catch(() => null)) as ApiSuccess<T> | ApiFailure | null
    if (!response.ok) {
      if (payload && 'error' in payload) {
        throw new ApiClientError(
          payload.error.message,
          payload.error.code,
          response.status,
          payload.traceId,
          payload.error.details,
        )
      }
      throw new ApiClientError('服务暂时不可用，请稍后再试。', 'HTTP_ERROR', response.status)
    }

    if (!payload || !('data' in payload)) {
      throw new ApiClientError('服务响应格式不正确。', 'UPSTREAM_CONTRACT_INVALID', 502)
    }
    return payload.data as T
  } finally {
    window.clearTimeout(timeout)
  }
}

function json(body: unknown): string {
  return JSON.stringify(body)
}

export const api = {
  login(email: string, password: string): Promise<AuthSessionResponse> {
    return request('/auth/sessions', {
      method: 'POST',
      body: json({ email, password, deviceName: navigator.userAgent.slice(0, 120) }),
    })
  },

  register(input: { email: string; password: string; displayName: string; invitationCode: string }): Promise<AuthSessionResponse> {
    return request('/auth/registrations', {
      method: 'POST',
      body: json({ ...input, invitationCode: input.invitationCode.trim().toUpperCase(), deviceName: navigator.userAgent.slice(0, 120) }),
    })
  },

  requestPasswordReset(email: string): Promise<void> {
    return request('/auth/password-reset-requests', {
      method: 'POST',
      body: json({ email }),
    })
  },

  resetPassword(resetToken: string, newPassword: string): Promise<void> {
    return request('/auth/password-resets', {
      method: 'POST',
      body: json({ resetToken, newPassword }),
    })
  },

  getCurrentUser(): Promise<UserProfile> {
    return request('/users/me')
  },
}
