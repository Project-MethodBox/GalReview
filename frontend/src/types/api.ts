export interface ApiSuccess<T> {
  data: T
  meta: Record<string, unknown>
  traceId: string
}

export interface ApiErrorDetail {
  code: string
  message: string
  details: Record<string, unknown>
}

export interface ApiFailure {
  data: null
  error: ApiErrorDetail
  traceId: string
}

export interface AuthSession {
  sessionId: string
  userId: string
  status: 'ACTIVE' | 'REVOKED' | 'EXPIRED'
  createdAt: string
  expiresAt: string
}

export interface TokenPair {
  accessToken: string
  refreshToken: string
  tokenType: 'Bearer'
  expiresInSeconds: number
}

export interface AuthSessionResponse {
  session: AuthSession
  tokens: TokenPair
}

export interface UserProfile {
  userId: string
  displayName: string
  avatarUrl: string | null
  locale: string
  preferredSubjectCodes: string[]
  createdAt: string
  updatedAt: string
}
