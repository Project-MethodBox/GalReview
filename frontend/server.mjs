import { createReadStream } from 'node:fs'
import { stat } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'
import { createServer, request as httpRequest } from 'node:http'
import { extname, join, normalize } from 'node:path'
import { fileURLToPath } from 'node:url'

const port = Number.parseInt(process.env.PORT || '8080', 10)
const host = process.env.HOST || '0.0.0.0'
const staticRoot = fileURLToPath(new URL('./dist/', import.meta.url))
const gateway = new URL(process.env.GATEWAY_UPSTREAM || 'http://gateway:5000')
const trustLoopbackProxy = process.env.TRUST_REVERSE_PROXY === 'loopback'
const publicScheme = process.env.PUBLIC_SCHEME === 'https' ? 'https' : 'http'

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

function isLoopbackAddress(address) {
  const normalized = String(address || '').toLowerCase().replace(/^::ffff:/, '')
  return normalized === '127.0.0.1' || normalized === '::1'
}

function lastForwardedAddress(value) {
  const header = Array.isArray(value) ? value[0] : value
  if (typeof header !== 'string') return ''
  return header.split(',').map((part) => part.trim()).filter(Boolean).at(-1) || ''
}

const DRAIN_MAX_BYTES = 12 * 1024 * 1024
const DRAIN_TIMEOUT_MS = 10_000

function endAfterDrain(request, response, upstream) {
  if (request.complete || request.readableEnded || request.destroyed) {
    response.end()
    return
  }
  request.unpipe(upstream)
  let drained = 0
  let settled = false
  const finish = (forceClose) => () => {
    if (settled) return
    settled = true
    clearTimeout(timer)
    request.removeListener('data', onData)
    request.removeListener('end', graceful)
    request.removeListener('close', graceful)
    response.end(() => {
      if (forceClose && !request.destroyed) {
        setImmediate(() => request.socket?.destroy())
      }
    })
  }
  const graceful = finish(false)
  const forceful = finish(true)
  const onData = (chunk) => {
    drained += chunk.length
    if (drained > DRAIN_MAX_BYTES) forceful()
  }
  const timer = setTimeout(forceful, DRAIN_TIMEOUT_MS)
  timer.unref()
  request.on('data', onData)
  request.once('end', graceful)
  request.once('close', graceful)
  request.resume()
}

function proxyToGateway(request, response) {
  const target = new URL(request.url || '/', gateway)
  const traceId = getCorrelationId(request)
  const remoteAddress = request.socket?.remoteAddress || ''
  const fromTrustedProxy = trustLoopbackProxy && isLoopbackAddress(remoteAddress)
  const forwardedAddress = fromTrustedProxy
    ? lastForwardedAddress(request.headers['x-forwarded-for']) || remoteAddress
    : remoteAddress
  const headers = {
    ...request.headers,
    host: target.host,
    'x-correlation-id': traceId,
    'x-forwarded-for': forwardedAddress,
    'x-forwarded-proto': fromTrustedProxy ? publicScheme : 'http',
    'x-forwarded-host': request.headers.host || '',
  }
  request.on('error', () => {})
  response.on('error', () => {})
  let settled = false
  const upstream = httpRequest(target, { method: request.method, headers }, (upstreamResponse) => {
    if (settled) {
      upstreamResponse.resume()
      return
    }
    settled = true
    const status = upstreamResponse.statusCode || 502
    if (status >= 500) {
      logProxyFailure('frontend_gateway_response_error', request, traceId, { status })
    }
    upstreamResponse.on('error', () => {})
    response.writeHead(status, upstreamResponse.headers)
    upstreamResponse.on('data', (chunk) => {
      response.write(chunk)
    })
    upstreamResponse.on('end', () => {
      endAfterDrain(request, response, upstream)
    })
  })
  upstream.setTimeout(180_000, () => upstream.destroy(new Error('Gateway request timed out')))
  upstream.on('socket', (socket) => socket.on('error', () => {}))
  request.once('close', () => {
    if (!settled && !request.complete && !upstream.destroyed) upstream.destroy()
  })
  upstream.on('error', (error) => {
    logProxyFailure('frontend_gateway_transport_error', request, traceId, {
      code: typeof error.code === 'string' ? error.code : 'UNKNOWN',
    })
    if (settled || response.headersSent) {
      if (!response.writableEnded) response.destroy()
      return
    }
    settled = true
    const payload = JSON.stringify({
      data: null,
      error: { code: 'SERVICE_UNAVAILABLE', message: 'API Gateway 暂时不可用。', details: {} },
      traceId,
    })
    response.writeHead(503, {
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Length': Buffer.byteLength(payload),
      'X-Correlation-Id': traceId,
    })
    response.write(payload)
    endAfterDrain(request, response, upstream)
  })
  request.pipe(upstream)
}

async function serveFrontend(request, response) {
  const rawPathname = requestPath(request)
  let pathname
  try {
    pathname = decodeURIComponent(rawPathname)
  } catch {
    pathname = rawPathname
  }
  const relative = normalize(pathname).replace(/^([/\\])+/, '')
  let filePath = join(staticRoot, relative)
  if (!filePath.startsWith(staticRoot)) filePath = join(staticRoot, 'index.html')

  try {
    const info = await stat(filePath)
    if (info.isDirectory()) filePath = join(filePath, 'index.html')
    await stat(filePath)
  } catch {
    const extension = extname(filePath).toLowerCase()
    if (!extension || extension === '.html') {
      filePath = join(staticRoot, 'index.html')
    } else {
      response.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' })
      response.end('Not Found')
      return
    }
  }

  const extension = extname(filePath).toLowerCase()
  response.writeHead(200, {
    'Content-Type': contentTypes.get(extension) || 'application/octet-stream',
    'Cache-Control': filePath.endsWith('index.html')
      ? 'no-cache'
      : 'public, max-age=604800, immutable',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'strict-origin-when-cross-origin',
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
  void serveFrontend(request, response).catch((error) => {
    logProxyFailure('frontend_static_error', request, getCorrelationId(request), {
      code: typeof error?.code === 'string' ? error.code : error?.name || 'UNKNOWN',
    })
    if (!response.headersSent) response.writeHead(400, { 'Content-Type': 'text/plain; charset=utf-8' })
    if (!response.writableEnded) response.end()
  })
})

server.requestTimeout = 190_000
server.headersTimeout = 195_000
server.listen(port, host)
