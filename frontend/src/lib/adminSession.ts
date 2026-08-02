import type { AuthSessionResponse, TokenPair } from '../types/api'

const ADMIN_SESSION_KEY = 'galreview.admin-session'

export function readAdminSession(): AuthSessionResponse | null {
  try {
    const raw = sessionStorage.getItem(ADMIN_SESSION_KEY)
    return raw ? (JSON.parse(raw) as AuthSessionResponse) : null
  } catch {
    return null
  }
}

export function saveAdminSession(session: AuthSessionResponse): void {
  sessionStorage.setItem(ADMIN_SESSION_KEY, JSON.stringify(session))
  window.dispatchEvent(new Event('galreview:admin-session'))
}

export function updateAdminSessionTokens(tokens: TokenPair): void {
  const current = readAdminSession()
  if (current) saveAdminSession({ ...current, tokens })
}

export function clearAdminSession(): void {
  sessionStorage.removeItem(ADMIN_SESSION_KEY)
  window.dispatchEvent(new Event('galreview:admin-session'))
}
