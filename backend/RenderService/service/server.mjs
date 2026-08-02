// RenderService HTTP service.
//
// Always serves the public runtime resources of contract.md §8.1 (manifest /
// runtime.wasm / adapter.js). The five ReviewSession endpoints activate only
// when the gateway callback identity is configured (Gateway__BaseUrl +
// Gateway__ServiceKey, contract.md §9.5); without it the service stays an
// honest SHELL and answers them with 501 RENDER_SESSION_NOT_IMPLEMENTED.
//
// The manifest is derived from the actual artifacts: wasmAbiComplete comes
// from compiling the served runtime.wasm at boot, reviewSessionsAvailable
// from the session configuration, runtimeMode is FULL only when both hold.
import { createHash, randomUUID, timingSafeEqual } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { createServer } from 'node:http'

import { createGatewayClient } from './gateway-client.js'
import { createSessionService } from './sessions.js'

// Project port policy (scripts/Test-PortPolicy.ps1): configured ports must
// stay inside 5000-5300.
const portText = process.env.PORT || '5106'
const port = Number.parseInt(portText, 10)
if (!/^\d+$/.test(portText) || port < 5000 || port > 5300) {
  throw new RangeError('PORT must be an integer between 5000 and 5300')
}
const gatewayBaseUrl = process.env.Gateway__BaseUrl || ''
const gatewayServiceName = process.env.Gateway__ServiceName || 'RenderService'
const gatewayServiceKey = process.env.Gateway__ServiceKey || ''
const internalTimeoutMs = Number.parseInt(process.env.Gateway__TimeoutMs || '10000', 10)
const sessionsEnabled = gatewayBaseUrl.length > 0 && gatewayServiceKey.length > 0

const runtimeDirectory = new URL('./', import.meta.url)
const adapter = await readFile(new URL('adapter.js', runtimeDirectory))
const wasm = Buffer.from(
  (await readFile(new URL('runtime.wasm.base64', runtimeDirectory), 'utf8')).trim(),
  'base64',
)
const checksum = createHash('sha256').update(wasm).digest('hex')

const REQUIRED_ABI_EXPORTS = [
  'memory', 'initialize', 'loadPackage', 'startSession', 'dispatchInput',
  'renderFrame', 'serializeState', 'getLastError', 'dispose',
  'rtAbiVersion', 'rtVersion', 'rtAlloc', 'rtFree',
]

async function probeWasmArtifact(bytes) {
  const fallback = {
    wasmAbiComplete: false,
    wasmVersion: 'cpp-js-shell-0.1.0',
    executionEngine: 'cpp-js-shell',
  }
  try {
    const module = await WebAssembly.compile(bytes)
    const names = new Set(WebAssembly.Module.exports(module).map((entry) => entry.name))
    if (!REQUIRED_ABI_EXPORTS.every((name) => names.has(name))) {
      return fallback
    }
    const imports = {}
    for (const descriptor of WebAssembly.Module.imports(module)) {
      if (descriptor.kind === 'function') {
        imports[descriptor.module] = imports[descriptor.module] || {}
        imports[descriptor.module][descriptor.name] = () => 0
      }
    }
    const instance = await WebAssembly.instantiate(module, imports)
    instance.exports._initialize?.()
    const memory = new Uint8Array(instance.exports.memory.buffer)
    const pointer = instance.exports.rtVersion()
    let end = pointer
    while (memory[end] !== 0) end += 1
    const wasmVersion = new TextDecoder().decode(memory.subarray(pointer, end))
    return { wasmAbiComplete: true, wasmVersion, executionEngine: 'cpp-wasm-shell' }
  } catch {
    return fallback
  }
}

const artifact = await probeWasmArtifact(wasm)
const runtimeMode = sessionsEnabled && artifact.wasmAbiComplete ? 'FULL' : 'SHELL'

const sessionService = sessionsEnabled
  ? createSessionService({
      gateway: createGatewayClient({
        baseUrl: gatewayBaseUrl,
        serviceName: gatewayServiceName,
        serviceKey: gatewayServiceKey,
        timeoutMs: internalTimeoutMs,
      }),
    })
  : null

const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const MAX_BODY_BYTES = 1024 * 1024

function traceId(request) {
  const supplied = request.headers['x-correlation-id']
  const value = Array.isArray(supplied) ? supplied[0] : supplied
  return typeof value === 'string' && value.trim() && value.length <= 128
    ? value.trim()
    : randomUUID()
}

function writeJson(response, status, body, correlationId) {
  const content = Buffer.from(JSON.stringify(body))
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': content.length,
    'X-Correlation-Id': correlationId,
  })
  response.end(content)
}

function success(data, correlationId) {
  return { data, meta: {}, traceId: correlationId }
}

function apiFailure(response, status, code, message, correlationId, details = {}) {
  writeJson(response, status, {
    data: null,
    error: { code, message, details },
    traceId: correlationId,
  }, correlationId)
}

function headerValue(request, name) {
  const value = request.headers[name]
  return Array.isArray(value) ? value[0] : value
}

function safeEqual(a, b) {
  const bufferA = Buffer.from(String(a))
  const bufferB = Buffer.from(String(b))
  if (bufferA.length !== bufferB.length) return false
  return timingSafeEqual(bufferA, bufferB)
}

function readBody(request) {
  return new Promise((resolve) => {
    const chunks = []
    let received = 0
    let aborted = false
    request.on('data', (chunk) => {
      if (aborted) return
      received += chunk.length
      if (received > MAX_BODY_BYTES) {
        aborted = true
        resolve({ ok: false })
        request.destroy()
        return
      }
      chunks.push(chunk)
    })
    request.on('end', () => {
      if (!aborted) resolve({ ok: true, raw: Buffer.concat(chunks) })
    })
    request.on('error', () => {
      if (!aborted) resolve({ ok: false })
    })
  })
}

async function readJson(request) {
  const body = await readBody(request)
  if (!body.ok) return { ok: false, reason: '请求体过大或读取失败' }
  if (body.raw.length === 0) return { ok: false, reason: '请求体不能为空' }
  try {
    return { ok: true, value: JSON.parse(body.raw.toString('utf8')) }
  } catch {
    return { ok: false, reason: '请求体不是合法 JSON' }
  }
}

function respondDomain(response, result, correlationId) {
  if (result.ok) {
    writeJson(response, result.status, success(result.body, correlationId), correlationId)
  } else {
    apiFailure(response, result.status, result.code, result.message, correlationId, result.details || {})
  }
}

// Routes /api/v1/review-sessions... Returns true when the request was handled.
async function handleReviewSessions(request, response, pathname, correlationId) {
  if (!sessionsEnabled) {
    apiFailure(response, 501, 'RENDER_SESSION_NOT_IMPLEMENTED',
      'RenderService 当前仅提供 C++/JS 运行时基础壳。', correlationId)
    return true
  }

  // Only requests that came through the gateway carry our service key.
  const suppliedKey = headerValue(request, 'x-gateway-key')
  if (!suppliedKey || !safeEqual(suppliedKey, gatewayServiceKey)) {
    apiFailure(response, 401, 'AUTH_REQUIRED', '该接口只允许经 API Gateway 访问', correlationId)
    return true
  }
  const userId = headerValue(request, 'x-user-id')
  if (typeof userId !== 'string' || !UUID_V4.test(userId)) {
    apiFailure(response, 401, 'AUTH_REQUIRED', '缺少可信用户身份', correlationId)
    return true
  }

  const segments = pathname.split('/').filter((part) => part.length > 0)
  // segments: ['api', 'v1', 'review-sessions', ...rest]
  const rest = segments.slice(3)

  if (rest.length === 0 && request.method === 'POST') {
    const body = await readJson(request)
    if (!body.ok) {
      apiFailure(response, 400, 'VALIDATION_ERROR', body.reason, correlationId)
      return true
    }
    const result = await sessionService.create({ userId, body: body.value, correlationId })
    respondDomain(response, result, correlationId)
    return true
  }
  if (rest.length === 1 && request.method === 'GET') {
    respondDomain(response, sessionService.get({ userId, sessionId: rest[0] }), correlationId)
    return true
  }
  if (rest.length === 2 && rest[1] === 'progress' && request.method === 'PUT') {
    const body = await readJson(request)
    if (!body.ok) {
      apiFailure(response, 400, 'VALIDATION_ERROR', body.reason, correlationId)
      return true
    }
    respondDomain(response,
      sessionService.saveProgress({ userId, sessionId: rest[0], body: body.value }), correlationId)
    return true
  }
  if (rest.length === 2 && rest[1] === 'events' && request.method === 'POST') {
    const body = await readJson(request)
    if (!body.ok) {
      apiFailure(response, 400, 'VALIDATION_ERROR', body.reason, correlationId)
      return true
    }
    respondDomain(response,
      sessionService.appendEvents({ userId, sessionId: rest[0], body: body.value }), correlationId)
    return true
  }
  if (rest.length === 2 && rest[1] === 'result' && request.method === 'PUT') {
    const body = await readJson(request)
    if (!body.ok) {
      apiFailure(response, 400, 'VALIDATION_ERROR', body.reason, correlationId)
      return true
    }
    const result = await sessionService.submitResult({
      userId, sessionId: rest[0], body: body.value, correlationId,
    })
    respondDomain(response, result, correlationId)
    return true
  }

  apiFailure(response, 404, 'RESOURCE_NOT_FOUND', '资源不存在。', correlationId)
  return true
}

async function handle(request, response) {
  const correlationId = traceId(request)
  const pathname = new URL(request.url || '/', 'http://render-service').pathname

  if (request.method === 'GET' && pathname === '/healthz') {
    writeJson(response, 200, success({ status: 'live' }, correlationId), correlationId)
    return
  }
  if (request.method === 'GET' && pathname === '/readyz') {
    writeJson(response, 200, success({
      status: 'ready',
      runtimeMode,
      executionEngine: artifact.executionEngine,
      wasmAbiComplete: artifact.wasmAbiComplete,
      reviewSessionsAvailable: sessionsEnabled,
      storage: 'ephemeral-memory',
      activeSessions: sessionService ? sessionService.stats().sessions : 0,
    }, correlationId), correlationId)
    return
  }
  if (request.method === 'GET' && pathname === '/api/v1/render-runtime/manifest') {
    writeJson(response, 200, success({
      wasmVersion: artifact.wasmVersion,
      supportedSchemaVersions: ['1.0'],
      wasmUrl: '/api/v1/render-runtime/runtime.wasm',
      jsAdapterUrl: '/api/v1/render-runtime/adapter.js',
      checksum,
      runtimeMode,
      reviewSessionsAvailable: sessionsEnabled,
      wasmAbiComplete: artifact.wasmAbiComplete,
    }, correlationId), correlationId)
    return
  }
  if (request.method === 'GET' && pathname === '/api/v1/render-runtime/runtime.wasm') {
    response.writeHead(200, {
      'Content-Type': 'application/wasm',
      'Content-Length': wasm.length,
      'X-Correlation-Id': correlationId,
    })
    response.end(wasm)
    return
  }
  if (request.method === 'GET' && pathname === '/api/v1/render-runtime/adapter.js') {
    response.writeHead(200, {
      'Content-Type': 'application/javascript; charset=utf-8',
      'Content-Length': adapter.length,
      'X-Correlation-Id': correlationId,
    })
    response.end(adapter)
    return
  }
  if (pathname.startsWith('/api/v1/review-sessions')) {
    await handleReviewSessions(request, response, pathname, correlationId)
    return
  }
  apiFailure(response, 404, 'RESOURCE_NOT_FOUND', '资源不存在。', correlationId)
}

const server = createServer((request, response) => {
  handle(request, response).catch((cause) => {
    const correlationId = traceId(request)
    console.error(`unhandled error (${correlationId}):`, cause)
    if (!response.headersSent) {
      apiFailure(response, 500, 'INTERNAL_ERROR', '服务内部错误', correlationId)
    } else {
      response.destroy()
    }
  })
})

server.listen(port, '0.0.0.0', () => {
  const address = server.address()
  console.log(`render-service shell listening on port ${address.port} `
    + `(engine=${artifact.executionEngine}, wasmAbiComplete=${artifact.wasmAbiComplete}, `
    + `reviewSessions=${sessionsEnabled ? 'enabled' : 'disabled'})`)
})
