import type { AuthSessionResponse, UserProfile } from '../types/api'

const SESSION_KEY = 'galreview.session'
const PROFILE_KEY = 'galreview.profile'

export interface StoredSession extends AuthSessionResponse {
  demo?: boolean
}

export function readSession(): StoredSession | null {
  try {
    const raw = localStorage.getItem(SESSION_KEY)
    return raw ? (JSON.parse(raw) as StoredSession) : null
  } catch {
    return null
  }
}

export function saveSession(session: StoredSession): void {
  localStorage.setItem(SESSION_KEY, JSON.stringify(session))
  window.dispatchEvent(new Event('galreview:session'))
}

export function clearSession(): void {
  localStorage.removeItem(SESSION_KEY)
  localStorage.removeItem(PROFILE_KEY)
  window.dispatchEvent(new Event('galreview:session'))
}

export function readProfile(): UserProfile | null {
  try {
    const raw = localStorage.getItem(PROFILE_KEY)
    return raw ? (JSON.parse(raw) as UserProfile) : null
  } catch {
    return null
  }
}

export function saveProfile(profile: UserProfile): void {
  localStorage.setItem(PROFILE_KEY, JSON.stringify(profile))
}

export function createDemoSession(identity: string): StoredSession {
  const now = new Date()
  const expiresAt = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000)
  const id = crypto.randomUUID()
  return {
    demo: true,
    session: {
      sessionId: id,
      userId: crypto.randomUUID(),
      status: 'ACTIVE',
      createdAt: now.toISOString(),
      expiresAt: expiresAt.toISOString(),
    },
    tokens: {
      accessToken: `demo-${id}`,
      refreshToken: `demo-refresh-${id}`,
      tokenType: 'Bearer',
      expiresInSeconds: 900,
    },
  }
}

export function createDemoProfile(displayName: string, userId: string): UserProfile {
  const now = new Date().toISOString()
  return {
    userId,
    displayName: displayName || '学习者',
    avatarUrl: null,
    locale: 'zh-CN',
    preferredSubjectCodes: [],
    createdAt: now,
    updatedAt: now,
  }
}
