import express from 'express';
import cors from 'cors';
import type { GatewayConfig } from './config.js';
import { traceContextMiddleware } from './middleware/traceContext.js';
import { headerSanitizerMiddleware } from './middleware/headerSanitizer.js';
import { createAuthenticationMiddleware } from './middleware/authentication.js';
import { createServiceIdentityMiddleware } from './middleware/serviceIdentity.js';
import { createRateLimiters } from './middleware/rateLimiter.js';
import { errorHandlerMiddleware, notFoundHandler } from './middleware/errorHandler.js';
import { createProxyForRoute } from './proxy/createProxy.js';
import { createHealthRouter } from './routes/health.js';
import { ROUTE_TABLE } from './routes/routeTable.js';
import { buildApiFailure } from './types.js';

/** 默认请求体大小上限（10MB） */
const DEFAULT_BODY_LIMIT_BYTES = 10 * 1024 * 1024;
/** 上传路由请求体大小上限（100MB） */
const UPLOAD_BODY_LIMIT_BYTES = 100 * 1024 * 1024;

/**
 * 创建 Gateway Express 应用
 */
export function createApp(config: GatewayConfig): express.Express {
  const app = express();

  // 信任代理（用于正确获取客户端 IP）
  app.set('trust proxy', 1);

  // ===== 全局中间件 =====
  // 1. 链路追踪
  app.use(traceContextMiddleware);

  // 2. CORS（只允许明确的前端源）
  app.use(
    cors({
      origin: config.corsOrigins,
      methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
      allowedHeaders: [
        'Content-Type',
        'Authorization',
        'X-Correlation-Id',
        'Idempotency-Key',
      ],
      exposedHeaders: ['X-Correlation-Id'],
      credentials: true,
      maxAge: 86400,
    }),
  );

  // 3. 健康检查（无需鉴权和清洗）
  app.use(createHealthRouter(config));

  // 4. 请求头清洗（剥离客户端伪造的内部身份头）
  app.use(headerSanitizerMiddleware);

  // 5. 请求体大小限制（通过 Content-Length 早期拒绝超大请求）
  app.use((req, res, next) => {
    const raw = req.headers['content-length'];
    const contentLength = Array.isArray(raw) ? raw[0] : raw;
    if (contentLength) {
      // 使用 req.originalUrl 避免子应用挂载场景下路径解析错误
      const requestPath = req.originalUrl || req.path;
      const isUpload = requestPath.startsWith('/api/v1/materials') && req.method === 'POST';
      const limit = isUpload ? UPLOAD_BODY_LIMIT_BYTES : DEFAULT_BODY_LIMIT_BYTES;
      const size = parseInt(contentLength, 10);
      if (isNaN(size) || size > limit) {
        const traceId = req.traceId ?? 'unknown';
        res.status(413).json(buildApiFailure('FILE_TOO_LARGE', '请求体超过大小限制', traceId));
        return;
      }
    }
    next();
  });

  // ===== 按路由表注册代理 =====
  const authMiddleware = createAuthenticationMiddleware(config);
  const serviceMiddleware = createServiceIdentityMiddleware(config);
  const rateLimiters = createRateLimiters(config);

  for (const route of ROUTE_TABLE) {
    const middlewares: express.RequestHandler[] = [];

    // 先鉴权再限流，使限流器能按 userId 计量
    if (route.auth === 'user') {
      middlewares.push(authMiddleware);
      middlewares.push(rateLimiters[route.rateLimitCategory]);
    } else if (route.auth === 'service') {
      middlewares.push(serviceMiddleware);
      middlewares.push(rateLimiters[route.rateLimitCategory]);
    } else {
      // public 路由不加鉴权，仅限流
      middlewares.push(rateLimiters[route.rateLimitCategory]);
    }

    // 代理
    const proxy = createProxyForRoute(route, config);
    middlewares.push(proxy as unknown as express.RequestHandler);

    // 有 methods 约束时按精确方法注册，否则前缀匹配
    if (route.methods && route.methods.length > 0) {
      for (const method of route.methods) {
        const verb = method.toLowerCase() as 'get' | 'post' | 'put' | 'patch' | 'delete';
        app[verb](route.path, ...middlewares);
      }
    } else {
      app.use(route.path, ...middlewares);
    }
  }

  // ===== 兜底 =====
  app.use(notFoundHandler);
  app.use(errorHandlerMiddleware);

  return app;
}
