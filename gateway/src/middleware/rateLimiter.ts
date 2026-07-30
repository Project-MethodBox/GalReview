import rateLimit, { type RateLimitRequestHandler } from 'express-rate-limit';
import type { Request, Response } from 'express';
import type { GatewayConfig } from '../config.js';
import { buildApiFailure, getTraceId } from '../types.js';

/** 限流键生成：优先用已认证的 userId，否则按 IP */
function keyGenerator(req: Request): string {
  return req.gatewayUserId ?? req.ip ?? 'unknown';
}

/** 构建单个限流器 */
function buildLimiter(windowMs: number, max: number): RateLimitRequestHandler {
  return rateLimit({
    windowMs,
    max,
    standardHeaders: true,
    legacyHeaders: false,
    handler: (req: Request, res: Response) => {
      const traceId = getTraceId(req);
      res.status(429).json(buildApiFailure('RATE_LIMITED', '请求过于频繁，请稍后再试', traceId));
    },
    keyGenerator,
  });
}

/**
 * 创建分类限流器
 * - anonymous: 登录、注册、密码恢复等匿名接口
 * - upload: 文件上传
 * - generation: 游戏生成、图谱构建等长任务
 * - general: 普通读取
 */
export function createRateLimiters(config: GatewayConfig) {
  return {
    anonymous: buildLimiter(config.rateLimit.anonymous.windowMs, config.rateLimit.anonymous.max),
    upload: buildLimiter(config.rateLimit.upload.windowMs, config.rateLimit.upload.max),
    generation: buildLimiter(config.rateLimit.generation.windowMs, config.rateLimit.generation.max),
    general: buildLimiter(config.rateLimit.general.windowMs, config.rateLimit.general.max),
  };
}
