import { createHash, randomUUID } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { createServer } from 'node:http'

const portText = process.env.PORT || '5106'
const port = Number.parseInt(portText, 10)
if (!/^\d+$/.test(portText) || port < 5000 || port > 5300) {
  throw new RangeError('PORT must be an integer between 5000 and 5300')
}
const runtimeDirectory = new URL('./', import.meta.url)
const adapter = await readFile(new URL('runtime-adapter.js', runtimeDirectory))
const wasm = Buffer.from(
  (await readFile(new URL('runtime.wasm.base64', runtimeDirectory), 'utf8')).trim(),
  'base64',
)
const checksum = createHash('sha256').update(wasm).digest('hex')

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

const server = createServer((request, response) => {
  const correlationId = traceId(request)
  const pathname = new URL(request.url || '/', 'http://render-shell').pathname

  if (request.method === 'GET' && pathname === '/healthz') {
    writeJson(response, 200, success({ status: 'live' }, correlationId), correlationId)
    return
  }
  if (request.method === 'GET' && pathname === '/readyz') {
    writeJson(response, 200, success({
      status: 'ready',
      runtimeMode: 'SHELL',
      executionEngine: 'cpp-js-shell',
      wasmAbiComplete: false,
      reviewSessionsAvailable: false,
    }, correlationId), correlationId)
    return
  }
  if (request.method === 'GET' && pathname === '/api/v1/render-runtime/manifest') {
    writeJson(response, 200, success({
      wasmVersion: 'cpp-js-shell-0.1.0',
      supportedSchemaVersions: ['1.0'],
      wasmUrl: '/api/v1/render-runtime/runtime.wasm',
      jsAdapterUrl: '/api/v1/render-runtime/adapter.js',
      checksum,
      runtimeMode: 'SHELL',
      reviewSessionsAvailable: false,
      wasmAbiComplete: false,
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
    writeJson(response, 501, {
      data: null,
      error: {
        code: 'RENDER_SESSION_NOT_IMPLEMENTED',
        message: 'RenderService 当前仅提供 C++/JS 运行时基础壳。',
        details: {},
      },
      traceId: correlationId,
    }, correlationId)
    return
  }
  writeJson(response, 404, {
    data: null,
    error: { code: 'RESOURCE_NOT_FOUND', message: '资源不存在。', details: {} },
    traceId: correlationId,
  }, correlationId)
})

server.listen(port, '0.0.0.0')
