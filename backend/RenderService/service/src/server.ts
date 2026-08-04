// RenderService HTTP service.
//
// Always serves the public runtime resources of contract.md §8.1 (manifest /
// runtime.wasm / adapter.js). The five ReviewSession endpoints activate only
// when the gateway callback identity is configured (Gateway__BaseUrl +
// Gateway__ServiceKey, contract.md §9.5); without it the service stays an
// honest SHELL and answers them with 501 RENDER_SESSION_NOT_IMPLEMENTED.
//
// The manifest is derived from the actual artifacts: wasmAbiComplete comes
// from compiling runtime.wasm at boot, reviewSessionsAvailable from the
// session configuration, runtimeMode is FULL only when both hold.
import { createHash, randomUUID, timingSafeEqual } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { createServer } from 'node:http'

import { createGatewayClient } from './gateway-client.js'
import type { SessionService } from './sessions.js'
import { createSessionService } from './sessions.js'
import { createSessionStore } from './sessionStore.js'
import { UUID_V4 } from './contract.js'

const portText = process.env.PORT || '5106'
const port = Number.parseInt(portText, 10)
if (!/^\d+$/.test(portText) || port < 0 || port > 65_535) {
  throw new RangeError('PORT must be an integer between 0 and 65535')
}
const gatewayBaseUrl = process.env.Gateway__BaseUrl || ''
const gatewayServiceName = process.env.Gateway__ServiceName || 'RenderService'
const gatewayServiceKey = process.env.Gateway__ServiceKey || ''
const internalTimeoutMs = Number.parseInt(process.env.Gateway__TimeoutMs || '10000', 10)
const sessionsEnabled = gatewayBaseUrl.length > 0 && gatewayServiceKey.length > 0

// dist/server.js serves its sibling dist/adapter.js; the wasm artifact stays
// at the package root next to package.json.
const distDirectory = new URL('./', import.meta.url)
const adapter = await readFile(new URL('adapter.js', distDirectory))
const stage = await readFile(new URL('stage.js', distDirectory))
const stageDemo = await readFile(new URL('../demo/stage-demo.html', distDirectory))
const wasm = Buffer.from(
  (await readFile(new URL('../runtime.wasm.base64', distDirectory), 'utf8')).trim(),
  'base64',
)
const checksum = createHash('sha256').update(wasm).digest('hex')

const REQUIRED_ABI_EXPORTS = [
  'memory', 'initialize', 'loadPackage', 'startSession', 'dispatchInput',
  'renderFrame', 'serializeState', 'getLastError', 'dispose',
  'rtAbiVersion', 'rtVersion', 'rtAlloc', 'rtFree',
]

interface ArtifactProbe {
  wasmAbiComplete: boolean
  wasmVersion: string
  executionEngine: string
}

async function probeWasmArtifact(bytes: Buffer): Promise<ArtifactProbe> {
  const fallback: ArtifactProbe = {
    wasmAbiComplete: false,
    wasmVersion: 'cpp-js-shell-0.1.0',
    executionEngine: 'cpp-js-shell',
  }
  try {
    // Copy into a fresh Uint8Array: node Buffer's ArrayBufferLike generic is
    // not assignable to the DOM BufferSource type WebAssembly.compile wants.
    const module = await WebAssembly.compile(new Uint8Array(bytes))
    const names = new Set(WebAssembly.Module.exports(module).map((entry) => entry.name))
    if (!REQUIRED_ABI_EXPORTS.every((name) => names.has(name))) {
      return fallback
    }
    const imports: Record<string, Record<string, () => number>> = {}
    for (const descriptor of WebAssembly.Module.imports(module)) {
      if (descriptor.kind === 'function') {
        imports[descriptor.module] = imports[descriptor.module] || {}
        imports[descriptor.module]![descriptor.name] = () => 0
      }
    }
    const instance = await WebAssembly.instantiate(module, imports)
    const abi = instance.exports as unknown as {
      _initialize?: () => void
      memory: WebAssembly.Memory
      rtVersion(): number
    }
    abi._initialize?.()
    const memory = new Uint8Array(abi.memory.buffer)
    const pointer = abi.rtVersion()
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

// Session store is pluggable: MongoDB (RENDER_SESSION_MONGODB_URI) for
// production, in-memory for development. Resolves before the service binds
// so a MongoDB connection failure stops the process at boot rather than
// dropping sessions silently.
const sessionStore = await createSessionStore()

const sessionService: SessionService | null = sessionsEnabled
  ? createSessionService({
      gateway: createGatewayClient({
        baseUrl: gatewayBaseUrl,
        serviceName: gatewayServiceName,
        serviceKey: gatewayServiceKey,
        timeoutMs: internalTimeoutMs,
      }),
      store: sessionStore,
    })
  : null

const MAX_BODY_BYTES = 1024 * 1024

function traceId(request: IncomingMessage): string {
  const supplied = request.headers['x-correlation-id']
  const value = Array.isArray(supplied) ? supplied[0] : supplied
  return typeof value === 'string' && value.trim() && value.length <= 128
    ? value.trim()
    : randomUUID()
}

function writeJson(
  response: ServerResponse, status: number, body: unknown, correlationId: string,
): void {
  const content = Buffer.from(JSON.stringify(body))
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': content.length,
    'X-Correlation-Id': correlationId,
  })
  response.end(content)
}

function success(data: unknown, correlationId: string): unknown {
  return { data, meta: {}, traceId: correlationId }
}

function apiFailure(
  response: ServerResponse, status: number, code: string, message: string,
  correlationId: string, details: Record<string, unknown> = {},
): void {
  writeJson(response, status, {
    data: null,
    error: { code, message, details },
    traceId: correlationId,
  }, correlationId)
}

function headerValue(request: IncomingMessage, name: string): string | undefined {
  const value = request.headers[name]
  return Array.isArray(value) ? value[0] : value
}

function safeEqual(a: string, b: string): boolean {
  const bufferA = Buffer.from(a)
  const bufferB = Buffer.from(b)
  if (bufferA.length !== bufferB.length) return false
  return timingSafeEqual(bufferA, bufferB)
}

type BodyResult = { ok: true; raw: Buffer } | { ok: false }

function readBody(request: IncomingMessage): Promise<BodyResult> {
  return new Promise((resolve) => {
    const chunks: Buffer[] = []
    let received = 0
    let aborted = false
    request.on('data', (chunk: Buffer) => {
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

type JsonResult = { ok: true; value: unknown } | { ok: false; reason: string }

async function readJson(request: IncomingMessage): Promise<JsonResult> {
  const body = await readBody(request)
  if (!body.ok) return { ok: false, reason: '请求体过大或读取失败' }
  if (body.raw.length === 0) return { ok: false, reason: '请求体不能为空' }
  try {
    return { ok: true, value: JSON.parse(body.raw.toString('utf8')) }
  } catch {
    return { ok: false, reason: '请求体不是合法 JSON' }
  }
}

interface DomainResultLike {
  ok: boolean
  status: number
  body?: unknown
  code?: string
  message?: string
  details?: Record<string, unknown>
}

function respondDomain(
  response: ServerResponse, result: DomainResultLike, correlationId: string,
): void {
  if (result.ok) {
    writeJson(response, result.status, success(result.body, correlationId), correlationId)
  } else {
    apiFailure(response, result.status, result.code ?? 'INTERNAL_ERROR',
      result.message ?? '服务内部错误', correlationId, result.details ?? {})
  }
}

// Routes /api/v1/review-sessions...; always handles the request.
async function handleReviewSessions(
  request: IncomingMessage, response: ServerResponse, pathname: string, correlationId: string,
): Promise<void> {
  if (!sessionsEnabled || sessionService === null) {
    apiFailure(response, 501, 'RENDER_SESSION_NOT_IMPLEMENTED',
      'RenderService 当前仅提供 C++/JS 运行时基础壳。', correlationId)
    return
  }

  // Only requests that came through the gateway carry our service key.
  const suppliedKey = headerValue(request, 'x-gateway-key')
  if (!suppliedKey || !safeEqual(suppliedKey, gatewayServiceKey)) {
    apiFailure(response, 401, 'AUTH_REQUIRED', '该接口只允许经 API Gateway 访问', correlationId)
    return
  }
  const userId = headerValue(request, 'x-user-id')
  if (typeof userId !== 'string' || !UUID_V4.test(userId)) {
    apiFailure(response, 401, 'AUTH_REQUIRED', '缺少可信用户身份', correlationId)
    return
  }

  const segments = pathname.split('/').filter((part) => part.length > 0)
  // segments: ['api', 'v1', 'review-sessions', ...rest]
  const rest = segments.slice(3)

  if (rest.length === 0 && request.method === 'POST') {
    const body = await readJson(request)
    if (!body.ok) {
      apiFailure(response, 400, 'VALIDATION_ERROR', body.reason, correlationId)
      return
    }
    respondDomain(response,
      await sessionService.create({ userId, body: body.value, correlationId }), correlationId)
    return
  }
  if (rest.length === 1 && request.method === 'GET') {
    respondDomain(response,
      await sessionService.get({ userId, sessionId: rest[0]! }), correlationId)
    return
  }
  if (rest.length === 2 && rest[1] === 'progress' && request.method === 'PUT') {
    const body = await readJson(request)
    if (!body.ok) {
      apiFailure(response, 400, 'VALIDATION_ERROR', body.reason, correlationId)
      return
    }
    respondDomain(response,
      await sessionService.saveProgress({ userId, sessionId: rest[0]!, body: body.value }), correlationId)
    return
  }
  if (rest.length === 2 && rest[1] === 'events' && request.method === 'POST') {
    const body = await readJson(request)
    if (!body.ok) {
      apiFailure(response, 400, 'VALIDATION_ERROR', body.reason, correlationId)
      return
    }
    respondDomain(response,
      await sessionService.appendEvents({ userId, sessionId: rest[0]!, body: body.value }), correlationId)
    return
  }
  if (rest.length === 2 && rest[1] === 'result' && request.method === 'PUT') {
    const body = await readJson(request)
    if (!body.ok) {
      apiFailure(response, 400, 'VALIDATION_ERROR', body.reason, correlationId)
      return
    }
    respondDomain(response, await sessionService.submitResult({
      userId, sessionId: rest[0]!, body: body.value, correlationId,
    }), correlationId)
    return
  }

  apiFailure(response, 404, 'RESOURCE_NOT_FOUND', '资源不存在。', correlationId)
}

async function handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
  const correlationId = traceId(request)
  const pathname = new URL(request.url || '/', 'http://render-service').pathname

  if (request.method === 'GET' && pathname === '/healthz') {
    writeJson(response, 200, success({ status: 'live' }, correlationId), correlationId)
    return
  }
  if (request.method === 'GET' && pathname === '/readyz') {
    const stats = sessionService ? await sessionService.stats() : { sessions: 0, storage: sessionStore.kind }
    writeJson(response, 200, success({
      status: 'ready',
      runtimeMode,
      executionEngine: artifact.executionEngine,
      wasmAbiComplete: artifact.wasmAbiComplete,
      reviewSessionsAvailable: sessionsEnabled,
      storage: stats.storage,
      activeSessions: stats.sessions,
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
  // Visual-novel stage engine (WebGPU + procedural shaders) and its
  // self-contained demo page; both are public runtime resources like the
  // adapter and reuse the same-origin adapter/wasm via relative imports.
  if (request.method === 'GET' && pathname === '/api/v1/render-runtime/stage.js') {
    response.writeHead(200, {
      'Content-Type': 'application/javascript; charset=utf-8',
      'Content-Length': stage.length,
      'X-Correlation-Id': correlationId,
    })
    response.end(stage)
    return
  }
  if (request.method === 'GET' && pathname === '/api/v1/render-runtime/stage-demo') {
    response.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Content-Length': stageDemo.length,
      'X-Correlation-Id': correlationId,
    })
    response.end(stageDemo)
    return
  }
  if (pathname.startsWith('/api/v1/review-sessions')) {
    await handleReviewSessions(request, response, pathname, correlationId)
    return
  }
  apiFailure(response, 404, 'RESOURCE_NOT_FOUND', '资源不存在。', correlationId)
}

const server = createServer((request, response) => {
  handle(request, response).catch((cause: unknown) => {
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
  const boundPort = address !== null && typeof address === 'object' ? address.port : port
  console.log(`render-service shell listening on port ${boundPort} `
    + `(engine=${artifact.executionEngine}, wasmAbiComplete=${artifact.wasmAbiComplete}, `
    + `reviewSessions=${sessionsEnabled ? 'enabled' : 'disabled'})`)
})
