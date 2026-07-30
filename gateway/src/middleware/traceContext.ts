import { randomBytes } from 'node:crypto';
import type { Request, Response, NextFunction } from 'express';

/** Crockford Base32 字符集 */
const ENCODING = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/** 生成 ULID 格式的 traceId（26 位，时间戳前缀 + 随机） */
function generateUlid(): string {
  const now = Date.now();
  // 10 位时间戳（48bit，Crockford base32）
  let ts = '';
  let t = now;
  for (let i = 0; i < 10; i++) {
    ts = ENCODING[t & 0x1f] + ts;
    t = Math.floor(t / 32);
  }
  // 16 位随机（每字符 5bit，共 80bit 熵）
  const bytes = randomBytes(16);
  let rand = '';
  for (let i = 0; i < 16; i++) {
    rand += ENCODING[bytes[i]! & 0x1f];
  }
  return ts + rand;
}

/** 控制字符正则（排除 Tab/CR/LF，保留可见字符和标准空白） */
const CONTROL_CHAR_RE = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g;

/**
 * 链路追踪中间件
 * - 读取或生成 X-Correlation-Id
 * - 过滤控制字符防止日志注入
 * - 挂载到 req.traceId
 * - 回写响应头
 */
/**
 * 从请求头安全提取单值 header（处理数组情况取首个）
 */
function getSingleHeader(headers: Record<string, string | string[] | undefined>, name: string): string | undefined {
  const raw = headers[name];
  if (Array.isArray(raw)) return raw[0];
  return raw;
}

export function traceContextMiddleware(req: Request, res: Response, next: NextFunction): void {
  const incoming = getSingleHeader(req.headers, 'x-correlation-id');
  const sanitized = typeof incoming === 'string' ? incoming.replace(CONTROL_CHAR_RE, '') : '';
  const correlationId =
    sanitized.trim().length > 0 && sanitized.length <= 128
      ? sanitized.trim()
      : generateUlid();

  req.traceId = correlationId;
  res.setHeader('X-Correlation-Id', correlationId);
  next();
}
