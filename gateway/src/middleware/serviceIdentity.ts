import { timingSafeEqual } from 'node:crypto';
import type { Request, Response, NextFunction } from 'express';
import type { GatewayConfig } from '../config.js';
import { buildApiFailure, getTraceId } from '../types.js';
import { getServiceNameFromHeaders, getServiceKeyFromHeaders } from './headerSanitizer.js';

/** 常量时间字符串比较，防止时序攻击 */
export function safeCompare(a: string, b: string): boolean {
  const bufA = Buffer.from(a);
  const bufB = Buffer.from(b);
  const maxLen = Math.max(bufA.length, bufB.length);
  // 填充到相同长度，使 timingSafeEqual 总在相同大小的 buffer 上执行
  const padBufA = Buffer.alloc(maxLen, 0);
  const padBufB = Buffer.alloc(maxLen, 0);
  bufA.copy(padBufA);
  bufB.copy(padBufB);
  try {
    return timingSafeEqual(padBufA, padBufB) && bufA.length === bufB.length;
  } catch {
    return false;
  }
}

/**
 * 服务身份认证中间件工厂
 * - 验证 /internal/v1 路由的调用方服务身份
 * - 检查 X-Service-Name 和 X-Service-Key
 * - 支持每服务独立密钥（回退到全局 gatewayKey）
 * - 验证通过后挂载 req.gatewayServiceName
 * - 验证失败返回 403
 */
export function createServiceIdentityMiddleware(config: GatewayConfig) {
  const keyMap = new Map<string, string>();
  for (const svc of Object.values(config.services)) {
    keyMap.set(svc.name, svc.serviceKey ?? config.gatewayKey);
  }

  return (req: Request, res: Response, next: NextFunction): void => {
    const serviceName = getServiceNameFromHeaders(req.headers);
    const serviceKey = getServiceKeyFromHeaders(req.headers);
    const expectedKey = serviceName ? keyMap.get(serviceName) : undefined;

    if (!serviceName || !serviceKey || !expectedKey || !safeCompare(serviceKey, expectedKey)) {
      const traceId = getTraceId(req);
      res.status(403).json(
        buildApiFailure('FORBIDDEN', '该接口只允许受信服务经 Gateway 调用', traceId),
      );
      return;
    }

    req.gatewayServiceName = serviceName;
    next();
  };
}
