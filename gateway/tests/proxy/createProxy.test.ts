import { createServer, type Server } from 'node:http';
import express from 'express';
import { describe, it, expect } from 'vitest';
import request from 'supertest';
import type { GatewayConfig } from '../../src/config.js';
import type { RouteEntry } from '../../src/types.js';
import { createProxyForRoute } from '../../src/proxy/createProxy.js';
import { listenOnTestPort } from '../support/testPorts.js';

const mockConfig: GatewayConfig = {
  port: 5000,
  gatewayKey: 'test-gateway-key',
  corsOrigins: ['http://localhost:5173'],
  defaultTimeoutMs: 30000,
  uploadTimeoutMs: 120000,
  services: {
    userService: { name: 'UserService', url: 'http://localhost:5101', serviceKey: 'user-key' },
    authService: { name: 'AuthService', url: 'http://localhost:5102' },
    fileService: { name: 'FileService', url: 'http://localhost:5103' },
    knowledgeService: { name: 'KnowledgeService', url: 'http://localhost:5104' },
    galGameService: { name: 'GalGameService', url: 'http://localhost:5105' },
    renderService: { name: 'RenderService', url: 'http://localhost:5106' },
    practiceService: { name: 'PracticeService', url: 'http://localhost:5107' },
  },
  rateLimit: {
    anonymous: { windowMs: 60000, max: 20 },
    upload: { windowMs: 60000, max: 10 },
    generation: { windowMs: 60000, max: 5 },
    general: { windowMs: 60000, max: 120 },
  },
};

describe('createProxyForRoute', () => {
  it('应为已知服务创建代理中间件', () => {
    const route: RouteEntry = {
      path: '/api/v1/users/me',
      service: 'userService',
      auth: 'user',
      rateLimitCategory: 'general',
    };
    const proxy = createProxyForRoute(route, mockConfig);
    expect(typeof proxy).toBe('function');
  });

  it('应使用路由自定义超时', () => {
    const route: RouteEntry = {
      path: '/api/v1/materials',
      service: 'fileService',
      auth: 'user',
      rateLimitCategory: 'upload',
      timeoutMs: 120_000,
      methods: ['POST'],
    };
    const proxy = createProxyForRoute(route, mockConfig);
    expect(typeof proxy).toBe('function');
  });

  it('对未知服务应抛出明确错误', () => {
    const route: RouteEntry = {
      path: '/api/v1/unknown',
      service: 'nonexistent',
      auth: 'user',
      rateLimitCategory: 'general',
    };
    expect(() => createProxyForRoute(route, mockConfig)).toThrow(
      'Unknown service "nonexistent"',
    );
  });

  it('应使用独立服务密钥当配置有时', () => {
    const route: RouteEntry = {
      path: '/api/v1/users/me',
      service: 'userService',
      auth: 'user',
      rateLimitCategory: 'general',
    };
    // 不应抛异常（userService 有独立 serviceKey）
    expect(() => createProxyForRoute(route, mockConfig)).not.toThrow();
  });

  it('应回退到 gatewayKey 当服务无独立密钥时', () => {
    const route: RouteEntry = {
      path: '/api/v1/auth/sessions',
      service: 'authService',
      auth: 'public',
      rateLimitCategory: 'anonymous',
    };
    // authService 无独立密钥，使用全局 gatewayKey
    expect(() => createProxyForRoute(route, mockConfig)).not.toThrow();
  });

  it('应保留浏览器请求的完整契约路径和查询参数', async () => {
    const upstream = await startUpstream();
    try {
      const app = express();
      const route: RouteEntry = {
        path: '/api/v1/users',
        service: 'userService',
        auth: 'user',
        rateLimitCategory: 'general',
      };
      app.use(route.path, createProxyForRoute(route, configFor(upstream.origin)));

      const response = await request(app).get('/api/v1/users/me?include=preferences');

      expect(response.status).toBe(200);
      expect(await upstream.requestUrl).toBe('/api/v1/users/me?include=preferences');
    } finally {
      await closeServer(upstream.server);
    }
  });

  it('应保留服务间内部调用的完整契约路径', async () => {
    const upstream = await startUpstream();
    try {
      const app = express();
      const route: RouteEntry = {
        path: '/internal/v1/users',
        service: 'userService',
        auth: 'service',
        rateLimitCategory: 'general',
      };
      app.use(route.path, createProxyForRoute(route, configFor(upstream.origin)));

      const response = await request(app).post('/internal/v1/users/profile-lookups').send({ userIds: [] });

      expect(response.status).toBe(200);
      expect(await upstream.requestUrl).toBe('/internal/v1/users/profile-lookups');
    } finally {
      await closeServer(upstream.server);
    }
  });

  it('上游连接失败应返回 503 SERVICE_UNAVAILABLE', async () => {
    const unavailableOrigin = await reserveUnavailableOrigin();
    const app = createProxyTestApp(unavailableOrigin, 1_000, 'proxy-connection-trace');

    const response = await request(app).get('/api/v1/users/me');

    expect(response.status).toBe(503);
    expect(response.body).toMatchObject({
      data: null,
      error: {
        code: 'SERVICE_UNAVAILABLE',
        details: {},
      },
      traceId: 'proxy-connection-trace',
    });
  });

  it('上游响应超时应返回 503 SERVICE_UNAVAILABLE', async () => {
    const upstream = await startHangingUpstream();
    try {
      const app = createProxyTestApp(upstream.origin, 25, 'proxy-timeout-trace');

      const response = await request(app).get('/api/v1/users/me');

      expect(response.status).toBe(503);
      expect(response.body).toMatchObject({
        data: null,
        error: {
          code: 'SERVICE_UNAVAILABLE',
          details: {},
        },
        traceId: 'proxy-timeout-trace',
      });
    } finally {
      upstream.server.closeAllConnections();
      await closeServer(upstream.server);
    }
  });

  it('上游 HTTP 响应不可解析应返回 502 UPSTREAM_CONTRACT_INVALID', async () => {
    const upstream = await startMalformedUpstream();
    try {
      const app = createProxyTestApp(upstream.origin, 1_000, 'proxy-contract-trace');

      const response = await request(app).get('/api/v1/users/me');

      expect(response.status).toBe(502);
      expect(response.body).toMatchObject({
        data: null,
        error: {
          code: 'UPSTREAM_CONTRACT_INVALID',
          details: {},
        },
        traceId: 'proxy-contract-trace',
      });
    } finally {
      upstream.server.closeAllConnections();
      await closeServer(upstream.server);
    }
  });
});

function configFor(userServiceUrl: string): GatewayConfig {
  return {
    ...mockConfig,
    services: {
      ...mockConfig.services,
      userService: { ...mockConfig.services.userService!, url: userServiceUrl },
    },
  };
}

function createProxyTestApp(
  userServiceUrl: string,
  timeoutMs: number,
  traceId: string,
): express.Express {
  const app = express();
  const route: RouteEntry = {
    path: '/api/v1/users',
    service: 'userService',
    auth: 'user',
    rateLimitCategory: 'general',
  };
  app.use((req, _res, next) => {
    req.traceId = traceId;
    next();
  });
  app.use(
    route.path,
    createProxyForRoute(route, {
      ...configFor(userServiceUrl),
      defaultTimeoutMs: timeoutMs,
    }),
  );
  return app;
}

async function startUpstream(): Promise<{ server: Server; origin: string; requestUrl: Promise<string> }> {
  let resolveRequestUrl!: (value: string) => void;
  const requestUrl = new Promise<string>((resolve) => { resolveRequestUrl = resolve; });
  const server = createServer((incoming, response) => {
    resolveRequestUrl(incoming.url ?? '/');
    response.writeHead(200, { 'Content-Type': 'application/json' });
    response.end('{"ok":true}');
  });

  const origin = await listenOnTestPort(server);
  return { server, origin, requestUrl };
}

async function startHangingUpstream(): Promise<{ server: Server; origin: string }> {
  const server = createServer(() => {
    // 故意不写响应，等待 Gateway 的 proxyTimeout 生效。
  });
  const origin = await listenOnTestPort(server);
  return { server, origin };
}

async function startMalformedUpstream(): Promise<{ server: Server; origin: string }> {
  const server = createServer((_incoming, response) => {
    response.socket?.end('not-an-http-response\r\n\r\n');
  });
  const origin = await listenOnTestPort(server);
  return { server, origin };
}

async function reserveUnavailableOrigin(): Promise<string> {
  const server = createServer();
  const origin = await listenOnTestPort(server);
  await closeServer(server);
  return origin;
}

async function closeServer(server: Server): Promise<void> {
  await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
}
