import type { Request } from 'express';

/** 统一成功响应 */
export interface ApiSuccess<T = unknown, M = Record<string, never>> {
  data: T;
  meta: M;
  traceId: string;
}

/** 统一错误详情 */
export interface ApiErrorDetail {
  code: string;
  message: string;
  details: Record<string, unknown>;
}

/** 统一失败响应 */
export interface ApiFailure {
  data: null;
  error: ApiErrorDetail;
  traceId: string;
}

/** 令牌内省结果 */
export interface TokenIntrospection {
  active: boolean;
  userId: string | null;
  sessionId: string | null;
  scopes: string[];
  expiresAt: string | null;
}

/** 扩展 Express Request，挂载 Gateway 上下文 */
declare global {
  namespace Express {
    interface Request {
      traceId?: string;
      gatewayUserId?: string;
      gatewayServiceName?: string;
    }
  }
}

/** 路由鉴权模式 */
export type AuthMode = 'public' | 'user' | 'service';

/** 路由表条目 */
export interface RouteEntry {
  /** 路由路径前缀（Express 通配） */
  path: string;
  /** 目标服务 key（对应 config.services） */
  service: string;
  /** 鉴权模式 */
  auth: AuthMode;
  /** 限流分类 */
  rateLimitCategory: 'anonymous' | 'upload' | 'generation' | 'general';
  /** 超时覆盖（ms），不设置则用默认 */
  timeoutMs?: number;
  /** 允许的 HTTP 方法；省略则匹配所有方法（用于 app.use） */
  methods?: string[];
}

export function buildApiSuccess(data: unknown, traceId: string): ApiSuccess {
  return { data, meta: {}, traceId };
}

export function buildApiFailure(
  code: string,
  message: string,
  traceId: string,
  details: Record<string, unknown> = {},
): ApiFailure {
  return { data: null, error: { code, message, details }, traceId };
}

export function getTraceId(req: Request): string {
  return req.traceId ?? req.headers['x-correlation-id'] as string ?? 'unknown';
}
