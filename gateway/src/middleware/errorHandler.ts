import type { Request, Response, NextFunction } from 'express';
import { buildApiFailure, getTraceId } from '../types.js';

/**
 * 统一错误处理中间件
 * - 捕获下游未处理异常
 * - 映射为统一 ApiFailure 格式
 * - 保持下游 error.code（如果有）
 * - 不允许用 HTTP 200 包装业务失败
 */
export function errorHandlerMiddleware(
  err: Error & { status?: number; code?: string },
  req: Request,
  res: Response,
  next: NextFunction,
): void {
  const traceId = getTraceId(req);

  if (res.headersSent) {
    next(err);
    return;
  }

  const status = err.status ?? 500;
  const code = typeof err.code === 'string' && err.code.length > 0 ? err.code : 'INTERNAL_ERROR';
  const message = status >= 500 ? '服务内部错误' : err.message || '请求处理失败';

  res.status(status).json(buildApiFailure(code, message, traceId));
}

/**
 * 404 兜底处理
 */
export function notFoundHandler(req: Request, res: Response): void {
  const traceId = getTraceId(req);
  res.status(404).json(buildApiFailure('RESOURCE_NOT_FOUND', '路由不存在', traceId));
}
