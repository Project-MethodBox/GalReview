// INTERNAL calls from RenderService to other services, always through the
// API Gateway with the precise service identity (contract.md §1.1/§9.2):
// X-Service-Name + X-Service-Key on the way in; the gateway validates them,
// strips the key and re-injects trusted headers for the target service.
//
// Every method returns a discriminated result instead of throwing, so the
// domain layer can map upstream failures to contract status codes without
// string-matching errors.
import type { GamePackage, MasteryUpdateReceipt, ReviewEvidenceSubmission, ValidationIssue } from './contract.js'
import { isRecord } from './contract.js'

export type UpstreamFailureKind =
  | 'not_found' | 'invalid' | 'conflict' | 'forbidden' | 'contract' | 'unavailable'

export interface UpstreamFailure {
  ok: false
  kind: UpstreamFailureKind
  status: number
  code: string
  message: string
}

export type ReadPackageResult = { ok: true; package: GamePackage } | UpstreamFailure
export type ValidatePackageResult =
  | { ok: true; valid: boolean; errors: ValidationIssue[] }
  | UpstreamFailure
export type SubmitEvidenceResult = { ok: true; receipt: MasteryUpdateReceipt } | UpstreamFailure

export interface GatewayClient {
  readGamePackage(packageId: string, ownerUserId: string, correlationId?: string): Promise<ReadPackageResult>
  validateGamePackage(gamePackage: GamePackage, correlationId?: string): Promise<ValidatePackageResult>
  submitEvidence(resultId: string, submission: ReviewEvidenceSubmission, correlationId?: string): Promise<SubmitEvidenceResult>
}

export interface GatewayClientConfig {
  baseUrl: string
  serviceName?: string
  serviceKey: string
  timeoutMs?: number
  fetchImpl?: typeof fetch
}

function classifyStatus(status: number, code: string, message: string): UpstreamFailure {
  if (status === 404) return { ok: false, kind: 'not_found', status, code, message }
  if (status === 400 || status === 422) return { ok: false, kind: 'invalid', status, code, message }
  if (status === 409) return { ok: false, kind: 'conflict', status, code, message }
  if (status === 403) return { ok: false, kind: 'forbidden', status, code, message }
  return { ok: false, kind: 'unavailable', status, code, message }
}

function contractViolation(message: string): UpstreamFailure {
  return { ok: false, kind: 'contract', status: 200, code: 'UPSTREAM_CONTRACT_INVALID', message }
}

interface Envelope {
  data: unknown
  traceId: unknown
  error?: unknown
}

function asEnvelope(body: unknown): Envelope | null {
  return isRecord(body) && 'data' in body && 'traceId' in body ? (body as unknown as Envelope) : null
}

function upstreamError(body: unknown, fallbackMessage: string): { code: string; message: string } {
  const envelope = isRecord(body) ? body : {}
  const error = isRecord(envelope.error) ? envelope.error : {}
  return {
    code: typeof error.code === 'string' ? error.code : 'UPSTREAM_ERROR',
    message: typeof error.message === 'string' ? error.message : fallbackMessage,
  }
}

export function createGatewayClient(config: GatewayClientConfig): GatewayClient {
  const baseUrl = config.baseUrl.replace(/\/+$/, '')
  const serviceName = config.serviceName || 'RenderService'
  const serviceKey = config.serviceKey
  const timeoutMs = config.timeoutMs || 10_000
  const fetchImpl = config.fetchImpl || fetch

  interface CallResult {
    ok: true
    status: number
    body: unknown
  }

  async function call(
    method: string,
    path: string,
    options: { body?: unknown; correlationId?: string } = {},
  ): Promise<CallResult | UpstreamFailure> {
    const headers: Record<string, string> = {
      'X-Service-Name': serviceName,
      'X-Service-Key': serviceKey,
    }
    if (options.correlationId) headers['X-Correlation-Id'] = options.correlationId
    if (options.body !== undefined) headers['Content-Type'] = 'application/json'
    let response: Response
    try {
      response = await fetchImpl(`${baseUrl}${path}`, {
        method,
        headers,
        body: options.body === undefined ? undefined : JSON.stringify(options.body),
        signal: AbortSignal.timeout(timeoutMs),
      })
    } catch (cause) {
      const message = cause instanceof Error ? cause.message : String(cause)
      return {
        ok: false,
        kind: 'unavailable',
        status: 0,
        code: 'SERVICE_UNAVAILABLE',
        message: `gateway unreachable: ${message}`,
      }
    }
    let parsed: unknown = null
    try {
      parsed = await response.json()
    } catch {
      parsed = null
    }
    return { ok: true, status: response.status, body: parsed }
  }

  return {
    // GET /internal/v1/game-packages/{packageId}?ownerUserId=... — only the
    // authoritative package may seed a session (contract.md §7.1).
    async readGamePackage(packageId, ownerUserId, correlationId) {
      const query = new URLSearchParams({ ownerUserId }).toString()
      const result = await call('GET', `/internal/v1/game-packages/${encodeURIComponent(packageId)}?${query}`, { correlationId })
      if (!result.ok) return result
      const { status, body } = result
      if (status === 200) {
        const envelope = asEnvelope(body)
        if (!envelope || !isRecord(envelope.data)) {
          return contractViolation('game package response is not a valid success envelope')
        }
        const pkg = envelope.data
        if (pkg.packageId !== packageId
            || typeof pkg.reviewPlanId !== 'string' || pkg.reviewPlanId.length === 0
            || typeof pkg.snapshotVersion !== 'string' || pkg.snapshotVersion.length === 0
            || typeof pkg.entrySceneId !== 'string'
            || !Array.isArray(pkg.scenes)) {
          return contractViolation('game package payload violates schema 1.0 identity fields')
        }
        return { ok: true, package: pkg as unknown as GamePackage }
      }
      const { code, message } = upstreamError(body, `game package read failed with HTTP ${status}`)
      return classifyStatus(status, code, message)
    },

    // POST /internal/v1/game-package-validations — the shared validator run
    // demanded by docs/galgame-owner-tbd.md for the complete Render flow.
    async validateGamePackage(gamePackage, correlationId) {
      const result = await call('POST', '/internal/v1/game-package-validations', {
        body: { package: gamePackage },
        correlationId,
      })
      if (!result.ok) return result
      const { status, body } = result
      if (status === 200 || status === 422) {
        const envelope = asEnvelope(body)
        const data = envelope && isRecord(envelope.data) ? envelope.data : null
        if (data === null || typeof data.valid !== 'boolean' || !Array.isArray(data.errors)) {
          return contractViolation('validation response is not a ValidationResult envelope')
        }
        return { ok: true, valid: data.valid, errors: data.errors as ValidationIssue[] }
      }
      const { code, message } = upstreamError(body, `package validation failed with HTTP ${status}`)
      return classifyStatus(status, code, message)
    },

    // PUT /internal/v1/review-evidence/{resultId} — the URGENT §8.2.1
    // mastery evidence submission consumed by KnowledgeService.
    async submitEvidence(resultId, submission, correlationId) {
      const result = await call('PUT', `/internal/v1/review-evidence/${encodeURIComponent(resultId)}`, {
        body: submission,
        correlationId,
      })
      if (!result.ok) return result
      const { status, body } = result
      if (status === 200) {
        const envelope = asEnvelope(body)
        const receipt = envelope && isRecord(envelope.data) ? envelope.data : null
        if (receipt === null
            || (receipt.status !== 'ACCEPTED' && receipt.status !== 'DUPLICATE')) {
          return contractViolation('mastery receipt is not a valid MasteryUpdateReceipt envelope')
        }
        return { ok: true, receipt: receipt as unknown as MasteryUpdateReceipt }
      }
      const { code, message } = upstreamError(body, `review evidence submission failed with HTTP ${status}`)
      return classifyStatus(status, code, message)
    },
  }
}
