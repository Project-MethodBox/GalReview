import { createProxyMiddleware, type Options } from 'http-proxy-middleware';
import type { ClientRequest } from 'http';
import type { Request, RequestHandler, Response } from 'express';
import type { GatewayConfig } from '../config.js';
import type { RouteEntry } from '../types.js';
import { buildApiFailure } from '../types.js';

/** 代理错误分类 */
type ProxyErrorKind = 'timeout' | 'connection' | 'contract' | 'other';

/** 错误关键词列表需要检查的类型集合 */
const TIMEOUT_PATTERNS = ['ETIMEDOUT', 'ESOCKETTIMEDOUT', 'WSAETIMEDOUT', 'timeout'] as const;
const CONNECTION_PATTERNS = [
  'ECONNREFUSED',
  'ECONNRESET',
  'ECONNABORTED',
  'EPIPE',
  'EHOSTUNREACH',
  'ENETUNREACH',
  'ENOTFOUND',
  'EAI_AGAIN',
] as const;

/** 让上游 proxyTimeout 先于客户端请求超时触发，以便返回统一错误信封。 */
const PROXY_ERROR_RESPONSE_GRACE_MS = 1_000;

/** 检查是否属于某类错误 */
function matchesPattern(err: NodeJS.ErrnoException, patterns: readonly string[]): boolean {
  const code = err.code ?? '';
  const msg = err.message ?? '';
  return patterns.some((p) => code === p || msg.includes(p));
}

/** 将上游代理错误归类为可响应的种类 */
function classifyProxyError(err: NodeJS.ErrnoException): ProxyErrorKind {
  if (matchesPattern(err, TIMEOUT_PATTERNS)) return 'timeout';
  // Node 的 HTTP 客户端用 HPE_* 表示上游响应无法按 HTTP 契约解析。
  if ((err.code ?? '').startsWith('HPE_')) return 'contract';
  if (matchesPattern(err, CONNECTION_PATTERNS)) return 'connection';
  return 'other';
}

function requestPath(req: Request): string {
  try {
    return new URL(req.originalUrl || req.url, 'http://gateway').pathname;
  } catch {
    return '/';
  }
}

/** 剥离不应透传下游的原始请求头（令牌、调用方服务凭证） */
function stripSensitiveHeaders(proxyReq: ClientRequest): void {
  proxyReq.removeHeader('authorization');
  proxyReq.removeHeader('x-service-key');
}

/** 错误代码 → HTTP 状态码、错误码和消息 */
const ERROR_MAP: Record<ProxyErrorKind, [number, string, string]> = {
  timeout: [503, 'SERVICE_UNAVAILABLE', '上游服务响应超时'],
  connection: [503, 'SERVICE_UNAVAILABLE', '上游服务暂不可用'],
  contract: [502, 'UPSTREAM_CONTRACT_INVALID', '上游响应不可解析或违反服务契约'],
  other: [503, 'SERVICE_UNAVAILABLE', '上游服务暂不可用'],
};

/**
 * 为指定路由条目创建代理中间件
 * - 注入 Gateway 身份头（X-Gateway-Key）
 * - 注入可信用户身份（X-User-Id）或服务身份（X-Service-Name）
 * - 透传 X-Correlation-Id
 * - 剥离敏感请求头（Authorization、X-Service-Key），防止凭证泄露
 * - 配置超时
 * - 写操作不盲目重试；GET 仅在确认幂等时有限重试
 */
export function createProxyForRoute(
  route: RouteEntry,
  config: GatewayConfig,
): RequestHandler {
  const target = config.services[route.service];
  if (!target) {
    throw new Error(`Unknown service "${route.service}" in route "${route.path}"`);
  }

  const timeoutMs = route.timeoutMs ??
    (route.rateLimitCategory === 'upload'
      ? config.uploadTimeoutMs
      : config.defaultTimeoutMs);
  // 使用目标服务的独立密钥，避免全局 key 透传所有下游
  const targetServiceKey = target.serviceKey ?? config.gatewayKey;

  const options: Options<Request, Response> = {
    target: target.url,
    changeOrigin: true,
    // Express 的 app.use(route.path, ...) 会从 req.url 移除已匹配的挂载前缀。
    // 下游服务按完整契约路径注册路由，因此必须以 originalUrl 还原客户端路径。
    pathRewrite: (path, req) => req.originalUrl || path,
    proxyTimeout: timeoutMs,
    timeout: timeoutMs + PROXY_ERROR_RESPONSE_GRACE_MS,
    // 不自动跟随重定向，透传给客户端
    followRedirects: false,
    // 注入静态头：X-Gateway-Key（每个服务密钥固定，通过 headers 字段一次性设置）
    headers: {
      'X-Gateway-Key': targetServiceKey,
    },
    // 使用 on 注册事件处理器：
    // 必须通过 on.error 注册错误处理器，http-proxy-middleware v3 仅当 on.error 存在时
    // 才会跳过默认的 errorResponsePlugin（否则默认插件先注册并返回 504 纯文本，
    // 覆盖本网关的统一 JSON 错误信封）。plugins 适用于中间件式扩展，不适用于覆盖默认错误响应。
    on: {
      proxyReq: (proxyReq, req: Request) => {
        // 剥离客户端原始敏感头，防止凭证泄露给下游
        stripSensitiveHeaders(proxyReq);

        // 注入链路追踪
        if (req.traceId) {
          proxyReq.setHeader('X-Correlation-Id', req.traceId);
        }

        // 用户路由：注入可信用户身份
        if (route.auth === 'user' && req.gatewayUserId) {
          proxyReq.setHeader('X-User-Id', req.gatewayUserId);
        }

        // 服务路由：注入服务名称（已通过 serviceIdentity 中间件验证）
        if (route.auth === 'service' && req.gatewayServiceName) {
          proxyReq.setHeader('X-Service-Name', req.gatewayServiceName);
        }
      },
      error: (err, req, res) => {
        // 响应已发送或不是 HTTP 响应对象则跳过
        if (!res || !('writeHead' in res) || res.headersSent) return;

        const traceId = req.traceId ?? 'unknown';
        const proxyError = err as NodeJS.ErrnoException;
        const kind = classifyProxyError(proxyError);
        const [status, errorCode, message] = ERROR_MAP[kind];

        console.error(JSON.stringify({
          timestamp: new Date().toISOString(),
          level: 'error',
          event: 'gateway_upstream_proxy_error',
          traceId,
          method: req.method,
          path: requestPath(req),
          targetService: route.service,
          upstream: target.url,
          kind,
          code: proxyError.code ?? 'UNKNOWN',
          status,
        }));

        const payload = JSON.stringify(buildApiFailure(errorCode, message, traceId));
        // 显式 Content-Length：避免 chunked 编码下客户端需等待终结块才能
        // 判定响应完成（bodyDrain 会先冲刷信封、延迟终结以排空请求体）
        res.writeHead(status, {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(payload),
        });
        res.end(payload);
      },
    },
  };

  return createProxyMiddleware(options) as RequestHandler;
}
