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

// 网关早期拒绝（401/413/429）到达时客户端请求体往往仍在上传。收尾规则
// （与网关 bodyDrain 中间件同构）：响应头和信封字节立即转发——响应带
// Content-Length，客户端凭它即刻完成读取；但 response.end() 延迟到客户端
// 请求体排空完成后再调用——否则 Node 会对"请求未完成"的连接 destroySoon
// （RST），信封可能被冲掉。排空前先把请求流从上游腿 unpipe（上游已停止
// 收体，pipe 背压会把流冻结）。排空有上限、有超时，越界则在响应完成后
// 显式断开（明示降级）。
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
  // 本进程是浏览器侧入口：客户端自带的 X-Forwarded-* 一律不可信，直接以真实
  // socket 对端地址覆盖，网关（配置 TRUST_PROXY 指向本代理时）才能得到可信的
  // 客户端 IP 用于匿名限流分桶。
  const headers = {
    ...request.headers,
    host: target.host,
    'x-correlation-id': traceId,
    'x-forwarded-for': request.socket?.remoteAddress || '',
    'x-forwarded-proto': 'http',
    'x-forwarded-host': request.headers.host || '',
  }
  // 崩溃防护：早期拒绝后上游/客户端连接的迟到错误（如网关排空超时 RST）
  // 不能变成未捕获异常打崩整个前端进程
  request.on('error', () => {})
  response.on('error', () => {})
  let settled = false // 单飞：正常转发与 503 兜底二选一，杜绝二次 writeHead
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
  // 客户端在上传途中断开时 pipe 只会 unpipe、不会结束上游请求，网关会一直
  // 等待剩余请求体直到 180 秒空闲超时；主动销毁上游腿让网关立即回收连接。
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
  // 畸形百分号编码（如 `/%`、`/%E0%A4%A`）会让 decodeURIComponent 抛 URIError；
  // 该异常若逸出会成为未处理的 Promise 拒绝并直接终止进程，因此就地回退为
  // 原始 pathname（后续 normalize + 前缀校验仍保证不会越出静态根目录）。
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
  // 兜底：静态服务的任何异步异常都不得逸出为未处理拒绝（会终止进程）
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
server.listen(port, '0.0.0.0')
