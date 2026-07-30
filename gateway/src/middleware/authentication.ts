import type { Request, Response, NextFunction } from 'express';
import type { GatewayConfig } from '../config.js';
import type { TokenIntrospection } from '../types.js';
import { buildApiFailure, getTraceId } from '../types.js';

/** 内省请求超时（毫秒），AuthService 挂起时不会拖死 Gateway */
const INTROSPECTION_TIMEOUT_MS = 5_000;

/** Token 最大允许长度（字符），防止超长令牌造成出站带宽/AuthService DoS */
const MAX_TOKEN_LENGTH = 8_192;

/** 内省结果：区分“服务不可达”和“令牌无效” */
type IntrospectionResult =
  | { status: 'ok'; data: TokenIntrospection }
  | { status: 'invalid' }
  | { status: 'unreachable' };

/**
 * 调用 AuthService 的令牌内省接口验证 Access Token
 */
async function introspectToken(
  authServiceUrl: string,
  gatewayKey: string,
  token: string,
): Promise<IntrospectionResult> {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), INTROSPECTION_TIMEOUT_MS);

    const res = await fetch(`${authServiceUrl}/internal/v1/auth/introspections`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Gateway-Key': gatewayKey,
      },
      body: JSON.stringify({ token }),
      signal: controller.signal,
    });

    clearTimeout(timer);
    if (!res.ok) return { status: 'invalid' };
    const envelope = (await res.json()) as { data?: TokenIntrospection };
    if (envelope.data) return { status: 'ok', data: envelope.data };
    return { status: 'invalid' };
  } catch (err) {
    // 区分连接错误和 JSON 解析错误：json() 抛 SyntaxError 视为 invalid
    if (err instanceof SyntaxError) return { status: 'invalid' };
    return { status: 'unreachable' };
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

    const result = await introspectToken(authServiceUrl, gatewayKey, token);

    if (result.status === 'unreachable') {
      res.status(503).json(buildApiFailure('SERVICE_UNAVAILABLE', '认证服务暂不可用', traceId));
      return;
    }

    if (result.status === 'invalid' || !result.data.active || !result.data.userId) {
      res.status(401).json(buildApiFailure('TOKEN_EXPIRED', '访问令牌无效或已过期', traceId));
      return;
    }

    req.gatewayUserId = result.data.userId;
    next();
  };
}
