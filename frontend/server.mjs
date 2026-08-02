import { createReadStream } from 'node:fs'
import { stat } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'
import { createServer, request as httpRequest } from 'node:http'
import { extname, join, normalize } from 'node:path'
import { fileURLToPath } from 'node:url'

const port = Number.parseInt(process.env.PORT || '8080', 10)
const staticRoot = fileURLToPath(new URL('./dist/', import.meta.url))
const gateway = new URL(process.env.GATEWAY_UPSTREAM || 'http://gateway:5000')

const contentTypes = new Map([
  ['.css', 'text/css; charset=utf-8'],
  ['.html', 'text/html; charset=utf-8'],
  ['.ico', 'image/x-icon'],
  ['.jpeg', 'image/jpeg'],
  ['.jpg', 'image/jpeg'],
  ['.js', 'text/javascript; charset=utf-8'],
  ['.json', 'application/json; charset=utf-8'],
  ['.png', 'image/png'],
  ['.svg', 'image/svg+xml; charset=utf-8'],
  ['.webp', 'image/webp'],
  ['.woff', 'font/woff'],
  ['.woff2', 'font/woff2'],
])

function getCorrelationId(request) {
  const value = request.headers['x-correlation-id']
  const candidate = Array.isArray(value) ? value[0] : value
  const sanitized = typeof candidate === 'string'
    ? candidate.replace(/[\x00-\x1F\x7F]/g, '').trim()
    : ''
  return sanitized.length > 0 && sanitized.length <= 128 ? sanitized : randomUUID()
}

function requestPath(request) {
  try {
    return new URL(request.url || '/', 'http://frontend').pathname
  } catch {
    return '/'
  }
}

function logProxyFailure(event, request, traceId, details) {
  console.error(JSON.stringify({
    timestamp: new Date().toISOString(),
    level: 'error',
    event,
    traceId,
    method: request.method || 'UNKNOWN',
    path: requestPath(request),
    upstream: gateway.origin,
    ...details,
  }))
}

function proxyToGateway(request, response) {
  const target = new URL(request.url || '/', gateway)
  const traceId = getCorrelationId(request)
  const headers = { ...request.headers, host: target.host, 'x-correlation-id': traceId }
  const upstream = httpRequest(target, { method: request.method, headers }, (upstreamResponse) => {
    const status = upstreamResponse.statusCode || 502
    if (status >= 500) {
      logProxyFailure('frontend_gateway_response_error', request, traceId, { status })
    }
    response.writeHead(status, upstreamResponse.headers)
    upstreamResponse.pipe(response)
  })
  upstream.setTimeout(180_000, () => upstream.destroy(new Error('Gateway request timed out')))
  upstream.on('error', (error) => {
    logProxyFailure('frontend_gateway_transport_error', request, traceId, {
      code: typeof error.code === 'string' ? error.code : 'UNKNOWN',
    })
    if (response.headersSent) {
      response.destroy()
      return
    }
    response.writeHead(503, {
      'Content-Type': 'application/json; charset=utf-8',
      'X-Correlation-Id': traceId,
    })
    response.end(JSON.stringify({
      data: null,
      error: { code: 'SERVICE_UNAVAILABLE', message: 'API Gateway 暂时不可用。', details: {} },
      traceId,
    }))
  })
  request.pipe(upstream)
}

async function serveFrontend(request, response) {
  const pathname = decodeURIComponent(new URL(request.url || '/', 'http://frontend').pathname)
  const relative = normalize(pathname).replace(/^([/\\])+/, '')
  let filePath = join(staticRoot, relative)
  if (!filePath.startsWith(staticRoot)) filePath = join(staticRoot, 'index.html')

  try {
    const info = await stat(filePath)
    if (info.isDirectory()) filePath = join(filePath, 'index.html')
    await stat(filePath)
  } catch {
    filePath = join(staticRoot, 'index.html')
  }

  const extension = extname(filePath).toLowerCase()
  response.writeHead(200, {
    'Content-Type': contentTypes.get(extension) || 'application/octet-stream',
    'Cache-Control': filePath.endsWith('index.html')
      ? 'no-cache'
      : 'public, max-age=604800, immutable',
  })
  createReadStream(filePath).on('error', () => response.destroy()).pipe(response)
}

const server = createServer((request, response) => {
  if (request.url === '/healthz') {
    response.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' })
    response.end('ok\n')
    return
  }
  if (request.url?.startsWith('/api/')) {
    proxyToGateway(request, response)
    return
  }
  void serveFrontend(request, response)
})

server.requestTimeout = 190_000
server.headersTimeout = 195_000
server.listen(port, '0.0.0.0')
