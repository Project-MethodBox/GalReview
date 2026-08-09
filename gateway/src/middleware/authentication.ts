import type { Request, Response, NextFunction } from 'express';
import type { GatewayConfig } from '../config.js';
import type { TokenIntrospection } from '../types.js';
import { buildApiFailure, getTraceId } from '../types.js';

/** 内省请求超时（毫秒），AuthService 挂起时不会拖死 Gateway */
export const INTROSPECTION_TIMEOUT_MS = 5_000;

/** Token 最大允许长度（字符），防止超长令牌造成出站带宽/AuthService DoS */
const MAX_TOKEN_LENGTH = 8_192;

type ActiveTokenIntrospection = TokenIntrospection & {
  active: true;
  userId: string;
};

/** 内省结果：只有规范响应中的 active=false 能证明令牌无效 */
type IntrospectionResult =
  | { status: 'ok'; data: ActiveTokenIntrospection }
  | { status: 'invalid' }
  | { status: 'unreachable' };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

const LOWERCASE_UUID_V4_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

const ISO_8601_UTC_PATTERN =
  /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(?:Z|\+00:00)$/;

function isLowercaseUuidV4(value: unknown): value is string {
  return typeof value === 'string'
    && LOWERCASE_UUID_V4_PATTERN.test(value);
}

function isLeapYear(year: number): boolean {
  return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
}

function daysInMonth(year: number, month: number): number {
  if (month === 2) return isLeapYear(year) ? 29 : 28;
  return [4, 6, 9, 11].includes(month) ? 30 : 31;
}

function isIso8601Utc(value: unknown): value is string {
  if (typeof value !== 'string') return false;

  const match = ISO_8601_UTC_PATTERN.exec(value);
  if (!match) return false;

  const [, yearText, monthText, dayText, hourText, minuteText, secondText] = match;
  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const hour = Number(hourText);
  const minute = Number(minuteText);
  const second = Number(secondText);

  return year >= 1
    && month >= 1
    && month <= 12
    && day >= 1
    && day <= daysInMonth(year, month)
    && hour >= 0
    && hour <= 23
    && minute >= 0
    && minute <= 59
    && second >= 0
    && second <= 59;
}

function isDateTimeOrNull(value: unknown): value is string | null {
  return value === null || isIso8601Utc(value);
}

function hasStringScopes(value: unknown): value is string[] {
  return Array.isArray(value)
    && value.every((scope) => typeof scope === 'string');
}

function isTokenIntrospection(value: unknown): value is TokenIntrospection {
  return isRecord(value)
    && typeof value.active === 'boolean'
    && (value.userId === null || isLowercaseUuidV4(value.userId))
    && (value.sessionId === null || isLowercaseUuidV4(value.sessionId))
    && hasStringScopes(value.scopes)
    && isDateTimeOrNull(value.expiresAt);
}

function isSuccessEnvelope(
  value: unknown,
): value is {
  data: TokenIntrospection;
  meta: Record<string, never>;
  traceId: string;
} {
  return isRecord(value)
    && isTokenIntrospection(value.data)
    && isRecord(value.meta)
    && Object.keys(value.meta).length === 0
    && typeof value.traceId === 'string'
    && value.traceId.trim().length > 0;
}

/**
 * 调用 AuthService 的令牌内省接口验证 Access Token
 */
async function introspectToken(
  authServiceUrl: string,
  gatewayKey: string,
  token: string,
  traceId: string,
): Promise<IntrospectionResult> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), INTROSPECTION_TIMEOUT_MS);
  try {
    const res = await fetch(`${authServiceUrl}/internal/v1/auth/introspections`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Gateway-Key': gatewayKey,
        'X-Correlation-Id': traceId,
      },
      body: JSON.stringify({ token }),
      signal: controller.signal,
    });

    // AuthService 的公开契约以 HTTP 200 返回内省结论。任何其他状态都表示
    // Gateway 无法可靠判断令牌有效性（包括服务密钥错配导致的 403）。
    if (res.status !== 200) return { status: 'unreachable' };

    const envelope: unknown = await res.json();
    if (!isSuccessEnvelope(envelope)) {
      return { status: 'unreachable' };
    }

    // 只有完整、规范的 active=false 记录能证明令牌无效。
    if (envelope.data.active === false) {
      return { status: 'invalid' };
    }

    // active=true 必须给出可注入的用户身份。畸形 200 是上游故障，不能伪装成 401。
    if (envelope.data.userId === null) {
      return { status: 'unreachable' };
    }

    return {
      status: 'ok',
      data: envelope.data as ActiveTokenIntrospection,
    };
  } catch {
    return { status: 'unreachable' };
  } finally {
    clearTimeout(timer);
  }
}

/**
 * 用户认证中间件工厂
 * - 从 Authorization: Bearer <token> 提取令牌
 * - 调用 AuthService 内省接口验证
 * - 验证通过后注入 X-User-Id 到 req.gatewayUserId
 * - 验证失败返回 401
 */
export function createAuthenticationMiddleware(config: GatewayConfig) {
  const authServiceUrl = config.services.authService.url;
  // 使用 AuthService 的独立密钥（如有），回退到全局 gatewayKey
  const gatewayKey = config.services.authService.serviceKey ?? config.gatewayKey;

  return async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const traceId = getTraceId(req);

    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      res.status(401).json(buildApiFailure('AUTH_REQUIRED', '缺少访问令牌', traceId));
      return;
    }

    const token = authHeader.slice(7);
    if (!token) {
      res.status(401).json(buildApiFailure('AUTH_REQUIRED', '访问令牌为空', traceId));
      return;
    }

    if (token.length > MAX_TOKEN_LENGTH) {
      res.status(401).json(buildApiFailure('AUTH_REQUIRED', '访问令牌格式无效', traceId));
      return;
    }

    const result = await introspectToken(
      authServiceUrl,
      gatewayKey,
      token,
      traceId,
    );

    if (result.status === 'unreachable') {
      res.status(503).json(buildApiFailure('SERVICE_UNAVAILABLE', '认证服务暂不可用', traceId));
      return;
    }

    if (result.status === 'invalid') {
      res.status(401).json(buildApiFailure('TOKEN_EXPIRED', '访问令牌无效或已过期', traceId));
      return;
    }

    req.gatewayUserId = result.data.userId;
    // headerSanitizer 已在认证之前删除所有客户端伪造的 X-User-Id。
    // 同时写回当前请求头，保证带请求体的 http-proxy 流在创建上游请求时也能
    // 取得已经内省确认的用户身份；proxyReq 仍会再次以 gatewayUserId 覆盖该值。
    req.headers['x-user-id'] = result.data.userId;
    next();
  };
}
