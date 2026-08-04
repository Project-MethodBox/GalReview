import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';
import express, {
  type NextFunction,
  type Request,
  type Response,
} from 'express';
import request from 'supertest';
import {
  createAuthenticationMiddleware,
  INTROSPECTION_TIMEOUT_MS,
} from '../../src/middleware/authentication.js';
import type { GatewayConfig } from '../../src/config.js';

const mockConfig: GatewayConfig = {
  port: 5000,
  gatewayKey: 'test-gateway-key',
  corsOrigins: ['http://localhost:5173'],
  defaultTimeoutMs: 30000,
  uploadTimeoutMs: 120000,
  services: {
    authService: { name: 'AuthService', url: 'http://localhost:5259' },
  },
  rateLimit: {
    anonymous: { windowMs: 60000, max: 20 },
    upload: { windowMs: 60000, max: 10 },
    generation: { windowMs: 60000, max: 5 },
    general: { windowMs: 60000, max: 120 },
  },
  introspectionCache: { ttlMs: 15_000, maxSize: 4_096 },
};

const VALID_ACTIVE_INTROSPECTION = {
  active: true,
  userId: '7bc4918a-9079-4ea2-9e8e-369ad79a9f20',
  sessionId: '6fa43e7f-0383-4c60-b305-8011f4a8cab8',
  scopes: ['user'],
  expiresAt: '2026-08-03T08:10:00Z',
};

function successEnvelope(
  data: unknown = VALID_ACTIVE_INTROSPECTION,
  meta: unknown = {},
  traceId: unknown = 'auth-service-trace',
): string {
  return JSON.stringify({ data, meta, traceId });
}

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
    vi.useRealTimers();
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

  it('应在 AuthService 连接失败时返回 503', async () => {
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('ECONNREFUSED'));

    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', 'Bearer some-token');
    expect(res.status).toBe(503);
    expect(res.body.error.code).toBe('SERVICE_UNAVAILABLE');
  });

  it('应在令牌内省返回 active=false 时返回 401', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        successEnvelope({
          active: false,
          userId: null,
          sessionId: null,
          scopes: [],
          expiresAt: null,
        }),
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
        successEnvelope(),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    );

    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', 'Bearer valid-token');
    expect(res.status).toBe(200);
    expect(res.body.userId).toBe('7bc4918a-9079-4ea2-9e8e-369ad79a9f20');
  });

  it('应接受小写 UUID v4、可空 sessionId 和 +00:00 UTC 小数秒', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        successEnvelope({
          ...VALID_ACTIVE_INTROSPECTION,
          sessionId: null,
          expiresAt: '2026-08-03T08:10:00.1234567+00:00',
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    );

    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', 'Bearer valid-utc-token');

    expect(res.status).toBe(200);
    expect(res.body.userId).toBe(VALID_ACTIVE_INTROSPECTION.userId);
  });

  it('应将 AuthService 的非预期 401 映射为 503，而不是令牌失效', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('Unauthorized', { status: 401 }),
    );

    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', 'Bearer bad-token');
    expect(res.status).toBe(503);
    expect(res.body.error.code).toBe('SERVICE_UNAVAILABLE');
  });

  it('应将服务密钥错配产生的 403 映射为 503，并保留关联 ID', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('Forbidden', { status: 403 }),
    );

    const res = await request(app)
      .get('/protected/data')
      .set('X-Correlation-Id', 'auth-key-mismatch-trace')
      .set('Authorization', 'Bearer unverifiable-token');

    expect(res.status).toBe(503);
    expect(res.body.error.code).toBe('SERVICE_UNAVAILABLE');
    expect(res.body.traceId).toBe('auth-key-mismatch-trace');
    expect(
      new Headers(fetchSpy.mock.calls[0]?.[1]?.headers)
        .get('X-Correlation-Id'),
    ).toBe('auth-key-mismatch-trace');
  });

  it('应将 AuthService 的 5xx 映射为 503 而不是误报令牌失效', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('service unavailable', { status: 503 }),
    );

    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', 'Bearer valid-but-unverifiable-token');
    expect(res.status).toBe(503);
    expect(res.body.error.code).toBe('SERVICE_UNAVAILABLE');
  });

  it('应把关联 ID 透传给 AuthService 内省接口', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        successEnvelope(),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    );

    const res = await request(app)
      .get('/protected/data')
      .set('X-Correlation-Id', 'auth-adapter-trace')
      .set('Authorization', 'Bearer valid-token');
    expect(res.status).toBe(200);
    expect(
      new Headers(fetchSpy.mock.calls[0]?.[1]?.headers)
        .get('X-Correlation-Id'),
    ).toBe('auth-adapter-trace');
  });

  it('应将内省接口的畸形 200 非 JSON 响应映射为 503', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('not-json-plain-text', {
        status: 200,
        headers: { 'Content-Type': 'text/plain' },
      }),
    );

    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', 'Bearer some-token');
    expect(res.status).toBe(503);
    expect(res.body.error.code).toBe('SERVICE_UNAVAILABLE');
  });

  it('应在 AuthService 内省超时时返回 503', async () => {
    vi.useFakeTimers();
    vi.spyOn(globalThis, 'fetch').mockImplementation((_input, init) =>
      new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener(
          'abort',
          () => reject(new DOMException('aborted', 'AbortError')),
          { once: true },
        );
      }));

    const middleware = createAuthenticationMiddleware(mockConfig);
    const req = {
      headers: {
        authorization: 'Bearer slow-token',
        'x-correlation-id': 'auth-timeout-trace',
      },
    } as unknown as Request;
    let statusCode = 0;
    let body: Record<string, unknown> | undefined;
    const res = {
      status(code: number) {
        statusCode = code;
        return this;
      },
      json(payload: Record<string, unknown>) {
        body = payload;
        return this;
      },
    } as unknown as Response;
    const next = vi.fn() as unknown as NextFunction;

    const pending = middleware(req, res, next);
    await vi.advanceTimersByTimeAsync(INTROSPECTION_TIMEOUT_MS);
    await pending;

    expect(statusCode).toBe(503);
    expect((body?.error as { code?: string })?.code).toBe('SERVICE_UNAVAILABLE');
    expect(body?.traceId).toBe('auth-timeout-trace');
    expect(next).not.toHaveBeenCalled();
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

  it.each([
    {
      caseName: '缺少 meta',
      envelope: {
        data: VALID_ACTIVE_INTROSPECTION,
        traceId: 'auth-service-trace',
      },
    },
    {
      caseName: 'meta 不是对象',
      envelope: {
        data: VALID_ACTIVE_INTROSPECTION,
        meta: [],
        traceId: 'auth-service-trace',
      },
    },
    {
      caseName: '默认 meta 含未声明字段',
      envelope: {
        data: VALID_ACTIVE_INTROSPECTION,
        meta: { unexpected: true },
        traceId: 'auth-service-trace',
      },
    },
    {
      caseName: '缺少 traceId',
      envelope: {
        data: VALID_ACTIVE_INTROSPECTION,
        meta: {},
      },
    },
    {
      caseName: 'traceId 不是字符串',
      envelope: {
        data: VALID_ACTIVE_INTROSPECTION,
        meta: {},
        traceId: 42,
      },
    },
    {
      caseName: 'traceId 为空白',
      envelope: {
        data: VALID_ACTIVE_INTROSPECTION,
        meta: {},
        traceId: '   ',
      },
    },
  ])('应将不符合统一成功响应的情况视为 503：$caseName', async ({ envelope }) => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        JSON.stringify(envelope),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    );

    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', 'Bearer malformed-envelope-token');

    expect(res.status).toBe(503);
    expect(res.body.error.code).toBe('SERVICE_UNAVAILABLE');
  });

  it('应在内省接口 data 缺失时返回 503', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        JSON.stringify({ meta: {}, traceId: 'auth-service-trace' }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    );

    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', 'Bearer weird-response');
    expect(res.status).toBe(503);
    expect(res.body.error.code).toBe('SERVICE_UNAVAILABLE');
  });

  it('应在 active=true 但 data.userId 为 null 时返回 503', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        successEnvelope({
          ...VALID_ACTIVE_INTROSPECTION,
          userId: null,
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    );

    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', 'Bearer no-userid-token');
    expect(res.status).toBe(503);
    expect(res.body.error.code).toBe('SERVICE_UNAVAILABLE');
  });

  it('应将缺少其余契约字段的 active=false 视为畸形 200', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        successEnvelope({ active: false }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    );

    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', 'Bearer unverifiable-token');

    expect(res.status).toBe(503);
    expect(res.body.error.code).toBe('SERVICE_UNAVAILABLE');
  });

  it.each([
    {
      caseName: 'userId 不是 UUID',
      field: 'userId',
      value: 'not-a-uuid',
    },
    {
      caseName: 'userId 含大写十六进制',
      field: 'userId',
      value: '7BC4918A-9079-4EA2-9E8E-369AD79A9F20',
    },
    {
      caseName: 'userId 不是 UUID v4',
      field: 'userId',
      value: '7bc4918a-9079-1ea2-9e8e-369ad79a9f20',
    },
    {
      caseName: 'sessionId 不是 UUID',
      field: 'sessionId',
      value: 'not-a-uuid',
    },
    {
      caseName: 'sessionId 含大写十六进制',
      field: 'sessionId',
      value: '6FA43E7F-0383-4C60-B305-8011F4A8CAB8',
    },
    {
      caseName: 'sessionId 不是 UUID v4',
      field: 'sessionId',
      value: '6fa43e7f-0383-5c60-b305-8011f4a8cab8',
    },
    {
      caseName: 'expiresAt 不是日期时间',
      field: 'expiresAt',
      value: 'not-a-date',
    },
    {
      caseName: 'expiresAt 只有日期',
      field: 'expiresAt',
      value: '2026-08-03',
    },
    {
      caseName: 'expiresAt 使用非 UTC offset',
      field: 'expiresAt',
      value: '2026-08-03T16:10:00+08:00',
    },
    {
      caseName: 'expiresAt 使用无效日历日期',
      field: 'expiresAt',
      value: '2026-02-30T08:10:00Z',
    },
    {
      caseName: 'expiresAt 缺少时区',
      field: 'expiresAt',
      value: '2026-08-03T08:10:00',
    },
    {
      caseName: 'expiresAt 使用小写 z',
      field: 'expiresAt',
      value: '2026-08-03T08:10:00z',
    },
  ])('应拒绝 active=true 中无效的契约字段：$caseName', async ({ field, value }) => {
    const data: Record<string, unknown> = {
      ...VALID_ACTIVE_INTROSPECTION,
    };
    data[field] = value;
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        successEnvelope(data),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    );

    const res = await request(app)
      .get('/protected/data')
      .set('Authorization', 'Bearer malformed-token');

    expect(res.status).toBe(503);
    expect(res.body.error.code).toBe('SERVICE_UNAVAILABLE');
  });
});
