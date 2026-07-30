import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';
import express from 'express';
import request from 'supertest';
import { createAuthenticationMiddleware } from '../../src/middleware/authentication.js';
import type { GatewayConfig } from '../../src/config.js';

const mockConfig: GatewayConfig = {
  port: 5000,
  gatewayKey: 'test-gateway-key',
  corsOrigins: ['http://localhost:5173'],
  defaultTimeoutMs: 30000,
  uploadTimeoutMs: 120000,
  services: {
    authService: { name: 'AuthService', url: 'http://localhost:19999' },
  },
  rateLimit: {
    anonymous: { windowMs: 60000, max: 20 },
    upload: { windowMs: 60000, max: 10 },
    generation: { windowMs: 60000, max: 5 },
    general: { windowMs: 60000, max: 120 },
  },
};

function createTestApp() {
  const app = express();
  const middleware = createAuthenticationMiddleware(mockConfig);
  app.use('/protected', middleware);
  app.get('/protected/data', (req, res) => {
    res.json({ userId: req.gatewayUserId });
  });
  return app;
}

describe('authenticationMiddleware', () => {
  let app: express.Express;

  beforeEach(() => {
    app = createTestApp();
    vi.restoreAllMocks();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('应拒绝缺少 Authorization 头的请求', async () => {
    const res = await request(app).get('/protected/data');
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('AUTH_REQUIRED');
    expect(res.body.data).toBeNull();
    expect(res.body.traceId).toBeDefined();
  });

  it('应拒绝非 Bearer 格式的 Authorization', async () => {
    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', 'Basic abc123');
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('AUTH_REQUIRED');
  });

  it('应拒绝 Bearer 后无 token 的请求', async () => {
    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', 'Bearer ');
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('AUTH_REQUIRED');
  });

  it('应拒绝 Bearer 后仅有空白 token 的请求', async () => {
    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', 'Bearer   ');
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('AUTH_REQUIRED');
  });

  it('应在 AuthService 不可用时返回 503', async () => {
    // fetch 会因为连接失败而抛出异常，introspectToken 返回 unreachable
    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', 'Bearer some-token');
    expect(res.status).toBe(503);
    expect(res.body.error.code).toBe('SERVICE_UNAVAILABLE');
  });

  it('应在令牌内省返回 active=false 时返回 401', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        JSON.stringify({ data: { active: false, userId: null, sessionId: null, scopes: [], expiresAt: null } }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    );

    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', 'Bearer expired-token');
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('TOKEN_EXPIRED');
  });

  it('应在令牌有效时注入 userId 并放行', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        JSON.stringify({
          data: {
            active: true,
            userId: '7bc4918a-9079-4ea2-9e8e-369ad79a9f20',
            sessionId: '6fa43e7f-0383-4c60-b305-8011f4a8cab8',
            scopes: ['user'],
            expiresAt: '2026-08-03T08:10:00Z',
          },
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    );

    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', 'Bearer valid-token');
    expect(res.status).toBe(200);
    expect(res.body.userId).toBe('7bc4918a-9079-4ea2-9e8e-369ad79a9f20');
  });

  it('应在内省接口返回非 200 时返回 401', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('Unauthorized', { status: 401 }),
    );

    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', 'Bearer bad-token');
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('TOKEN_EXPIRED');
  });

  it('应在内省接口返回非 JSON 响应体时返回 401 而非 503', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('not-json-plain-text', {
        status: 200,
        headers: { 'Content-Type': 'text/plain' },
      }),
    );

    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', 'Bearer some-token');
    // json() 抛 SyntaxError → 视为 invalid → 返回 401
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('TOKEN_EXPIRED');
  });

  it('应拒绝超过 8192 字符的超长令牌', async () => {
    const longToken = 'x'.repeat(9000);
    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', `Bearer ${longToken}`);
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('AUTH_REQUIRED');
    expect(res.body.error.message).toBe('访问令牌格式无效');
  });

  it('刚好 8192 字符的令牌应被验证（不由 Gateway 直接拒绝）', async () => {
    const longToken = 'x'.repeat(8192);
    // 不 mock fetch，真实 fetch 会因服务不可达返回 503
    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', `Bearer ${longToken}`);
    // 令牌不被 Gateway 拒绝 → fetch 请求导致 503
    expect(res.status).toBe(503);
  });

  it('应在内省接口 data 缺失时返回 401', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        JSON.stringify({}), // 无 data 字段
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    );

    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', 'Bearer weird-response');
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('TOKEN_EXPIRED');
  });

  it('应在内省接口 data.userId 为 null 时返回 401', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        JSON.stringify({ data: { active: true, userId: null, sessionId: null, scopes: [], expiresAt: null } }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    );

    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', 'Bearer no-userid-token');
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('TOKEN_EXPIRED');
  });
});
