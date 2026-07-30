import type { Request, Response, NextFunction } from 'express';

/**
 * 浏览器路由上需要剥离的内部身份头。
 * 客户端（浏览器）不允许伪造这些头。
 */
const BROWSER_STRIP_HEADERS = [
  'x-service-name',
  'x-service-key',
  'x-user-id',
  'x-gateway-key',
];

/**
 * /internal/ 路由上需要剥离的头。
 * 服务调用方可以发送 X-Service-Name 和 X-Service-Key（由 serviceIdentity 中间件验证），
 * 但不允许伪造 X-User-Id 和 X-Gateway-Key。
 */
const INTERNAL_STRIP_HEADERS = [
  'x-user-id',
  'x-gateway-key',
];

/**
 * 请求头清洗中间件
 * - /api/ 路由：丢弃所有内部身份头（X-Service-Name, X-Service-Key, X-User-Id, X-Gateway-Key）
 * - /internal/ 路由：仅丢弃 X-User-Id 和 X-Gateway-Key，保留服务身份头供后续验证
 * - 使用 originalUrl 确保在 trust proxy / 子应用挂载场景下仍能正确判断路由前缀
 * - 确保下游服务只信任 Gateway 注入的身份信息
 */
export function headerSanitizerMiddleware(req: Request, _res: Response, next: NextFunction): void {
  // originalUrl 不受 mount path 和 trust proxy 影响，始终保留客户端原始路径
  const requestPath = req.originalUrl || req.path;
  const isInternal = requestPath.startsWith('/internal/');
  const headersToStrip = isInternal ? INTERNAL_STRIP_HEADERS : BROWSER_STRIP_HEADERS;

  for (const header of headersToStrip) {
    delete req.headers[header];
  }
  next();
}

/** 提取 /internal 路由上的 X-Service-Name，用于 serviceIdentity 和 proxy */
export function getServiceNameFromHeaders(headers: Record<string, string | string[] | undefined>): string | undefined {
  const raw = headers['x-service-name'];
  if (Array.isArray(raw)) return raw[0];
  return raw;
}

/** 提取 /internal 路由上的 X-Service-Key，用于 serviceIdentity 验证 */
export function getServiceKeyFromHeaders(headers: Record<string, string | string[] | undefined>): string | undefined {
  const raw = headers['x-service-key'];
  if (Array.isArray(raw)) return raw[0];
  return raw;
}
