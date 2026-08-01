import type { AuthSessionResponse, TokenPair, UserProfile } from '../types/api'

const SESSION_KEY = 'galreview.session'
const PROFILE_KEY = 'galreview.profile'

export type StoredSession = AuthSessionResponse

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

export function updateSessionTokens(tokens: TokenPair): void {
  const current = readSession()
  if (current) saveSession({ ...current, tokens })
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
