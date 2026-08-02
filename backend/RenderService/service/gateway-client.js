// INTERNAL calls from RenderService to other services, always through the
// API Gateway with the precise service identity (contract.md §1.1/§9.2):
// X-Service-Name + X-Service-Key on the way in; the gateway validates them,
// strips the key and re-injects trusted headers for the target service.
//
// Every method returns a discriminated result instead of throwing:
//   { ok: true, ... }                        on success
//   { ok: false, kind, status, code, message } on failure, where kind is
//     'not_found' | 'invalid' | 'conflict' | 'forbidden' | 'contract' | 'unavailable'
// so the domain layer can map upstream failures to contract status codes
// without string-matching errors.

function classifyStatus(status, code, message) {
  if (status === 404) return { ok: false, kind: 'not_found', status, code, message }
  if (status === 400 || status === 422) return { ok: false, kind: 'invalid', status, code, message }
  if (status === 409) return { ok: false, kind: 'conflict', status, code, message }
  if (status === 403) return { ok: false, kind: 'forbidden', status, code, message }
  return { ok: false, kind: 'unavailable', status, code, message }
}

function contractViolation(message) {
  return { ok: false, kind: 'contract', status: 200, code: 'UPSTREAM_CONTRACT_INVALID', message }
}

function isEnvelope(body) {
  return body !== null && typeof body === 'object' && 'data' in body && 'traceId' in body
}

export function createGatewayClient(config) {
  const baseUrl = config.baseUrl.replace(/\/+$/, '')
  const serviceName = config.serviceName || 'RenderService'
  const serviceKey = config.serviceKey
  const timeoutMs = config.timeoutMs || 10_000
  const fetchImpl = config.fetchImpl || fetch

  async function call(method, path, { body, correlationId } = {}) {
    const headers = {
      'X-Service-Name': serviceName,
      'X-Service-Key': serviceKey,
    }
    if (correlationId) headers['X-Correlation-Id'] = correlationId
    if (body !== undefined) headers['Content-Type'] = 'application/json'
    let response
    try {
      response = await fetchImpl(`${baseUrl}${path}`, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(timeoutMs),
      })
    } catch (cause) {
      return {
        ok: false,
        kind: 'unavailable',
        status: 0,
        code: 'SERVICE_UNAVAILABLE',
        message: `gateway unreachable: ${cause?.message || cause}`,
      }
    }
    let parsed = null
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
        if (!isEnvelope(body) || body.data === null || typeof body.data !== 'object') {
          return contractViolation('game package response is not a valid success envelope')
        }
        const pkg = body.data
        if (pkg.packageId !== packageId
            || typeof pkg.reviewPlanId !== 'string' || pkg.reviewPlanId.length === 0
            || typeof pkg.snapshotVersion !== 'string' || pkg.snapshotVersion.length === 0
            || typeof pkg.entrySceneId !== 'string'
            || !Array.isArray(pkg.scenes)) {
          return contractViolation('game package payload violates schema 1.0 identity fields')
        }
        return { ok: true, package: pkg }
      }
      const code = body?.error?.code || 'UPSTREAM_ERROR'
      const message = body?.error?.message || `game package read failed with HTTP ${status}`
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
        const data = isEnvelope(body) ? body.data : null
        if (data === null || typeof data.valid !== 'boolean' || !Array.isArray(data.errors)) {
          return contractViolation('validation response is not a ValidationResult envelope')
        }
        return { ok: true, valid: data.valid, errors: data.errors }
      }
      const code = body?.error?.code || 'UPSTREAM_ERROR'
      const message = body?.error?.message || `package validation failed with HTTP ${status}`
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
        const receipt = isEnvelope(body) ? body.data : null
        if (receipt === null || typeof receipt !== 'object'
            || (receipt.status !== 'ACCEPTED' && receipt.status !== 'DUPLICATE')) {
          return contractViolation('mastery receipt is not a valid MasteryUpdateReceipt envelope')
        }
        return { ok: true, receipt }
      }
      const code = body?.error?.code || 'UPSTREAM_ERROR'
      const message = body?.error?.message || `review evidence submission failed with HTTP ${status}`
      return classifyStatus(status, code, message)
    },
  }
}
