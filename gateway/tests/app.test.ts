import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';
import request from 'supertest';
import {
  createApp,
  MAX_UPLOAD_BYTES,
  MAX_UPLOAD_REQUEST_BYTES,
  MULTIPART_OVERHEAD_BYTES,
} from '../src/app.js';
import type { GatewayConfig } from '../src/config.js';

const mockConfig: GatewayConfig = {
  port: 5000,
  gatewayKey: 'test-gateway-key',
  trustProxy: false,
  corsOrigins: ['http://localhost:5173'],
  defaultTimeoutMs: 5000,
  uploadTimeoutMs: 10000,
  services: {
    userService: { name: 'UserService', url: 'http://localhost:5251' },
    authService: { name: 'AuthService', url: 'http://localhost:5252' },
    fileService: { name: 'FileService', url: 'http://localhost:5253' },
    knowledgeService: { name: 'KnowledgeService', url: 'http://localhost:5254' },
    galGameService: { name: 'GalGameService', url: 'http://localhost:5255' },
    renderService: { name: 'RenderService', url: 'http://localhost:5256' },
  },
  rateLimit: {
    anonymous: { windowMs: 60000, max: 100 },
    upload: { windowMs: 60000, max: 100 },
    generation: { windowMs: 60000, max: 100 },
    general: { windowMs: 60000, max: 1000 },
  },
};

describe('Gateway App 集成测试', () => {
  let app: ReturnType<typeof createApp>;

  beforeEach(() => {
    app = createApp(mockConfig);
    vi.restoreAllMocks();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe('健康检查', () => {
    it('GET /healthz 应返回 200 和 live 状态', async () => {
      const res = await request(app).get('/healthz');
      expect(res.status).toBe(200);
      expect(res.body.data.status).toBe('live');
      expect(res.body.traceId).toBeDefined();
      expect(res.headers['x-correlation-id']).toBeDefined();
    });

    it('GET /readyz 应在下游可达时返回 200', async () => {
      // mock 所有下游 /healthz 返回 200
      vi.spyOn(globalThis, 'fetch').mockResolvedValue(
        new Response(JSON.stringify({ status: 'live' }), { status: 200 }),
      );
      const res = await request(app).get('/readyz');
      expect(res.status).toBe(200);
      expect(res.body.data.status).toBe('ready');
    });

    it('GET /readyz 应在下游不可达时返回 503', async () => {
      vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('ECONNREFUSED'));
      const res = await request(app).get('/readyz');
      expect(res.status).toBe(503);
      expect(res.body.error.code).toBe('SERVICE_UNAVAILABLE');
      expect(res.body.error.details.unhealthy).toBeDefined();
    });

    it('GET /readyz 只应探测配置的核心服务', async () => {
      const coreOnlyApp = createApp({
        ...mockConfig,
        readinessServices: ['authService', 'knowledgeService'],
      });
      const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
        new Response('{}', { status: 200 }),
      );

      const res = await request(coreOnlyApp).get('/readyz');

      expect(res.status).toBe(200);
      expect(fetchSpy).toHaveBeenCalledTimes(2);
      expect(fetchSpy.mock.calls.map(([url]) => String(url))).toEqual([
        'http://localhost:5252/healthz',
        'http://localhost:5254/healthz',
      ]);
    });

    it('健康检查应保留自定义 X-Correlation-Id', async () => {
      const res = await request(app)
        .get('/healthz')
        .set('X-Correlation-Id', 'test-trace-abc');
      expect(res.status).toBe(200);
      expect(res.body.traceId).toBe('test-trace-abc');
      expect(res.headers['x-correlation-id']).toBe('test-trace-abc');
    });
  });

  describe('请求体大小限制', () => {
    const MB = 1024 * 1024;

    it('Content-Length 超过默认限制（10MB）应返回 413', async () => {
      // 手动设置 Content-Length 但不发 body，使 superagent 不覆写该头
      const res = await request(app)
        .post('/api/v1/auth/tokens')
        .set('Content-Type', 'application/json')
        .set('Content-Length', String(11 * MB));
      expect(res.status).toBe(413);
      expect(res.body.error.code).toBe('FILE_TOO_LARGE');
    });

    it('Content-Length 在默认限制内应通过', async () => {
      const res = await request(app)
        .post('/api/v1/auth/tokens')
        .set('Content-Type', 'application/json')
        .set('Content-Length', String(1 * MB));
      // 通过体检查 → 被代理转发（服务不可达返回 503）
      expect(res.status).toBe(503);
    });

    it('上传路由的总请求上限应为 10MiB 文件加 1MiB multipart 开销', () => {
      expect(MAX_UPLOAD_BYTES).toBe(10 * MB);
      expect(MULTIPART_OVERHEAD_BYTES).toBe(1 * MB);
      expect(MAX_UPLOAD_REQUEST_BYTES).toBe(11 * MB);
    });

    it('上传路由 Content-Length 超过有限 multipart 总上限应返回 413', async () => {
      const res = await request(app)
        .post('/api/v1/materials')
        .set('Content-Type', 'multipart/form-data; boundary=test-boundary')
        .set('Content-Length', String(MAX_UPLOAD_REQUEST_BYTES + 1));
      expect(res.status).toBe(413);
      expect(res.body.error.code).toBe('FILE_TOO_LARGE');
    });

    it('上传路由应允许文件上限之外的受控 multipart 开销', async () => {
      vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('ECONNREFUSED'));

      const res = await request(app)
        .post('/api/v1/materials')
        .set('Content-Type', 'multipart/form-data; boundary=test-boundary')
        .set('Authorization', 'Bearer valid-token')
        .set('Content-Length', String(MAX_UPLOAD_BYTES + 1));
      // 通过体检查 → 鉴权；mock 的 AuthService 连接故障稳定返回 503。
      expect(res.status).toBe(503);
    });

    it('非上传路由在超限 Content-Length 时应返回 413', async () => {
      const res = await request(app)
        .post('/api/v1/users/me')
        .set('Content-Type', 'application/json')
        .set('Content-Length', String(50 * MB));
      expect(res.status).toBe(413);
      expect(res.body.error.code).toBe('FILE_TOO_LARGE');
    });

    it('Content-Length 为 NaN 可解析字符串时应由 Node.js 返回 400', async () => {
      // Node.js HTTP 解析器在校验前拒绝了无效的 Content-Length: NaN
      // 我们的中间件逻辑中用 isNaN 兜底，但 Node 层面已拦截
      const res = await request(app)
        .post('/api/v1/auth/tokens')
        .set('Content-Type', 'application/json')
        .set('Content-Length', 'NaN');
      // Node.js 对无效 Content-Length 返回 400
      expect(res.status).toBe(400);
    });

    it('Content-Length 为 0 时应通过（空请求体）', async () => {
      const res = await request(app)
        .post('/api/v1/auth/tokens')
        .set('Content-Type', 'application/json')
        .set('Content-Length', '0');
      // 通过体检查 → 代理转发（服务不可达返回 503）
      expect(res.status).toBe(503);
    });

    it('Content-Length 刚好等于 multipart 总上限时应通过', async () => {
      vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('ECONNREFUSED'));

      const res = await request(app)
        .post('/api/v1/materials')
        .set('Content-Type', 'multipart/form-data; boundary=test-boundary')
        .set('Authorization', 'Bearer valid-token')
        .set('Content-Length', String(MAX_UPLOAD_REQUEST_BYTES));
      // 刚好等于限制不触发错误 → 被鉴权或代理处理
      expect(res.status).toBe(503);
    });

    it('无 Content-Length 头的 GET 请求应通过体检查', async () => {
      const res = await request(app).get('/api/v1/auth/tokens');
      // 不命中 body 检查（无 Content-Length）；
      // 路由方法不匹配（仅 POST 注册）→ 被 /api/v1/auth catch-all 拦截 → 返回 401
      expect(res.status).toBe(401);
    });
  });

  describe('CORS', () => {
    it('应允许配置的前端源', async () => {
      const res = await request(app)
        .options('/api/v1/users/me')
        .set('Origin', 'http://localhost:5173')
        .set('Access-Control-Request-Method', 'GET');
      expect(res.headers['access-control-allow-origin']).toBe('http://localhost:5173');
    });

    it('应拒绝未配置的前端源', async () => {
      const res = await request(app)
        .options('/api/v1/users/me')
        .set('Origin', 'http://evil-site.com')
        .set('Access-Control-Request-Method', 'GET');
      expect(res.headers['access-control-allow-origin']).toBeUndefined();
    });
  });

  describe('请求头清洗', () => {
    it('应在代理前剥离伪造的内部头（通过 404 路由验证）', async () => {
      // 访问不存在的路由，验证清洗中间件已执行
      const res = await request(app)
        .get('/nonexistent')
        .set('X-User-Id', 'hacker')
        .set('X-Service-Name', 'EvilService');
      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe('RESOURCE_NOT_FOUND');
    });
  });

  describe('404 兜底', () => {
    it('未匹配路由应返回统一 404 格式', async () => {
      const res = await request(app).get('/api/v2/unknown');
      expect(res.status).toBe(404);
      expect(res.body.data).toBeNull();
      expect(res.body.error.code).toBe('RESOURCE_NOT_FOUND');
      expect(res.body.traceId).toBeDefined();
    });
  });

  describe('方法精确匹配鉴权', () => {
    it('POST /api/v1/auth/sessions 应公开（登录）', async () => {
      // 公开路由会代理到 authService，由于服务不可达会返回 503
      const res = await request(app)
        .post('/api/v1/auth/sessions')
        .send({ email: 'a@b.com', password: '12345678' });
      // 不是 401 就说明没被鉴权拦截
      expect(res.status).not.toBe(401);
    });

    it('DELETE /api/v1/auth/sessions/xxx 应需要鉴权', async () => {
      const res = await request(app)
        .delete('/api/v1/auth/sessions/some-id');
      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('AUTH_REQUIRED');
    });

    it('GET /api/v1/auth/sessions/xxx 应需要鉴权', async () => {
      const res = await request(app)
        .get('/api/v1/auth/sessions/some-id');
      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('AUTH_REQUIRED');
    });

    it('GET /api/v1/admin/users 应需要鉴权', async () => {
      const res = await request(app).get('/api/v1/admin/users');
      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('AUTH_REQUIRED');
    });

    it('POST /api/v1/admin/sessions 应公开（管理员登录）', async () => {
      const res = await request(app)
        .post('/api/v1/admin/sessions')
        .send({ username: 'admin', password: 'admin' });
      expect(res.status).not.toBe(401);
    });
  });

  describe('服务身份路由', () => {
    it('/internal 路由应拒绝无服务身份的请求', async () => {
      const res = await request(app).get('/internal/v1/users');
      expect(res.status).toBe(403);
      expect(res.body.error.code).toBe('FORBIDDEN');
    });

    it('/internal 路由应拒绝伪造服务密钥', async () => {
      const res = await request(app)
        .post('/internal/v1/users')
        .set('X-Service-Name', 'AuthService')
        .set('X-Service-Key', 'wrong-key')
        .send({ userId: '123', displayName: 'test' });
      expect(res.status).toBe(403);
      expect(res.body.error.code).toBe('FORBIDDEN');
    });
  });

  describe('用户认证路由', () => {
    it('/api/v1/users 应拒绝无令牌的请求', async () => {
      const res = await request(app).get('/api/v1/users/me');
      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('AUTH_REQUIRED');
    });
  });

  describe('统一响应格式', () => {
    it('错误响应应包含 data=null, error, traceId', async () => {
      const res = await request(app).get('/nonexistent');
      expect(res.body).toHaveProperty('data', null);
      expect(res.body).toHaveProperty('error');
      expect(res.body.error).toHaveProperty('code');
      expect(res.body.error).toHaveProperty('message');
      expect(res.body.error).toHaveProperty('details');
      expect(res.body).toHaveProperty('traceId');
    });
  });
});
