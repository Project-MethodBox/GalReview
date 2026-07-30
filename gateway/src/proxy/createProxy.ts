import { createProxyMiddleware, type Options } from 'http-proxy-middleware';
import type { ClientRequest } from 'http';
import type { Request, Response } from 'express';
import type { GatewayConfig } from '../config.js';
import type { RouteEntry } from '../types.js';
import { buildApiFailure } from '../types.js';

/** 代理错误分类 */
type ProxyErrorKind = 'timeout' | 'connection' | 'other';

/** 错误关键词列表需要检查的类型集合 */
const TIMEOUT_PATTERNS = ['ETIMEDOUT', 'ESOCKETTIMEDOUT', 'WSAETIMEDOUT', 'timeout'] as const;
const CONNECTION_PATTERNS = ['ECONNREFUSED', 'ECONNRESET'] as const;

/** 检查是否属于某类错误 */
function matchesPattern(err: NodeJS.ErrnoException, patterns: readonly string[]): boolean {
  const code = err.code ?? '';
  const msg = err.message ?? '';
  return patterns.some((p) => code === p || msg.includes(p));
}

/** 将上游代理错误归类为可响应的种类 */
function classifyProxyError(err: NodeJS.ErrnoException): ProxyErrorKind {
  if (matchesPattern(err, TIMEOUT_PATTERNS)) return 'timeout';
  if (matchesPattern(err, CONNECTION_PATTERNS)) return 'connection';
  return 'other';
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
  other: [502, 'INTERNAL_ERROR', '网关代理错误'],
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
export function createProxyForRoute(route: RouteEntry, config: GatewayConfig) {
  const target = config.services[route.service];
  if (!target) {
    throw new Error(`Unknown service "${route.service}" in route "${route.path}"`);
  }

  const timeoutMs = route.timeoutMs ?? config.defaultTimeoutMs;
  // 使用目标服务的独立密钥，避免全局 key 透传所有下游
  const targetServiceKey = target.serviceKey ?? config.gatewayKey;

  const options: Options<Request, Response> = {
    target: target.url,
    changeOrigin: true,
    proxyTimeout: timeoutMs,
    timeout: timeoutMs,
    // 不自动跟随重定向，透传给客户端
    followRedirects: false,
    on: {
      proxyReq: (proxyReq, req) => {
        // 剥离客户端原始敏感头，防止凭证泄露给下游
        stripSensitiveHeaders(proxyReq);

        // 注入目标服务的独立身份密钥（非全局 key）
        proxyReq.setHeader('X-Gateway-Key', targetServiceKey);

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
        const kind = classifyProxyError(err);
        const [status, errorCode, message] = ERROR_MAP[kind];

        res.writeHead(status, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(buildApiFailure(errorCode, message, traceId)));
      },
    },
  };

  return createProxyMiddleware(options);
}
