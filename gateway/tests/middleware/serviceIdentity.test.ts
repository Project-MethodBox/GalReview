import { describe, it, expect, beforeEach } from 'vitest';
import express from 'express';
import request from 'supertest';
import { createServiceIdentityMiddleware } from '../../src/middleware/serviceIdentity.js';
import type { GatewayConfig } from '../../src/config.js';

const mockConfig: GatewayConfig = {
  port: 5000,
  gatewayKey: 'test-gateway-key',
  corsOrigins: ['http://localhost:5173'],
  defaultTimeoutMs: 30000,
  uploadTimeoutMs: 120000,
  services: {
    userService: { name: 'UserService', url: 'http://localhost:5101' },
    authService: { name: 'AuthService', url: 'http://localhost:5102' },
    fileService: { name: 'FileService', url: 'http://localhost:5103' },
    knowledgeService: { name: 'KnowledgeService', url: 'http://localhost:5104' },
    galGameService: { name: 'GalGameService', url: 'http://localhost:5105' },
    renderService: { name: 'RenderService', url: 'http://localhost:5106' },
  },
  rateLimit: {
    anonymous: { windowMs: 60000, max: 20 },
    upload: { windowMs: 60000, max: 10 },
    generation: { windowMs: 60000, max: 5 },
    general: { windowMs: 60000, max: 120 },
  },
  introspectionCache: { ttlMs: 15_000, maxSize: 4_096 },
};

function createTestApp() {
  const app = express();
  const middleware = createServiceIdentityMiddleware(mockConfig);
  app.use('/internal', middleware);
  app.get('/internal/test', (req, res) => {
    res.json({ serviceName: req.gatewayServiceName });
  });
  return app;
}

describe('serviceIdentityMiddleware', () => {
  let app: express.Express;

  beforeEach(() => {
    app = createTestApp();
  });

  it('应拒绝缺少 X-Service-Name 的请求', async () => {
    const res = await request(app)
      .get('/internal/test')
      .set('X-Service-Key', 'test-gateway-key');
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });

  it('应拒绝未知服务名', async () => {
    const res = await request(app)
      .get('/internal/test')
      .set('X-Service-Name', 'UnknownService')
      .set('X-Service-Key', 'test-gateway-key');
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });

  it('应拒绝缺少 X-Service-Key 的请求', async () => {
    const res = await request(app)
      .get('/internal/test')
      .set('X-Service-Name', 'KnowledgeService');
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });

  it('应拒绝错误的 X-Service-Key', async () => {
    const res = await request(app)
      .get('/internal/test')
      .set('X-Service-Name', 'KnowledgeService')
      .set('X-Service-Key', 'wrong-key');
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });

  it('应通过合法服务身份验证', async () => {
    const res = await request(app)
      .get('/internal/test')
      .set('X-Service-Name', 'KnowledgeService')
      .set('X-Service-Key', 'test-gateway-key');
    expect(res.status).toBe(200);
    expect(res.body.serviceName).toBe('KnowledgeService');
  });

  it('应接受所有已注册服务', async () => {
    const services = ['UserService', 'AuthService', 'FileService', 'KnowledgeService', 'GalGameService', 'RenderService'];
    for (const svc of services) {
      const res = await request(app)
        .get('/internal/test')
        .set('X-Service-Name', svc)
        .set('X-Service-Key', 'test-gateway-key');
      expect(res.status).toBe(200);
      expect(res.body.serviceName).toBe(svc);
    }
  });

  it('应拒绝不同长度的错误密钥（safeCompare 路径覆盖）', async () => {
    // 短密钥 vs 长密钥 — safeCompare 内部走填充路径
    const res = await request(app)
      .get('/internal/test')
      .set('X-Service-Name', 'KnowledgeService')
      .set('X-Service-Key', 'short');
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });

  it('应拒绝 X-Service-Name 和 X-Service-Key 均缺失', async () => {
    const res = await request(app).get('/internal/test');
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });

  it('应返回统一 403 错误格式', async () => {
    const res = await request(app)
      .get('/internal/test')
      .set('X-Service-Name', 'UnknownService')
      .set('X-Service-Key', 'any-key');
    expect(res.status).toBe(403);
    expect(res.body.data).toBeNull();
    expect(res.body.error.code).toBe('FORBIDDEN');
    expect(res.body.error.message).toBe('该接口只允许受信服务经 Gateway 调用');
    expect(res.body.error.details).toEqual({});
    expect(res.body.traceId).toBeDefined();
  });

  it('应使用独立密钥进行验证', async () => {
    const customConfig: GatewayConfig = {
      ...mockConfig,
      services: {
        ...mockConfig.services,
        userService: { name: 'UserService', url: 'http://localhost:5101', serviceKey: 'user-individual-key' },
      },
    };
    const app = express();
    const middleware = createServiceIdentityMiddleware(customConfig);
    app.use('/internal', middleware);
    app.get('/internal/test', (req, res) => {
      res.json({ serviceName: req.gatewayServiceName });
    });

    // 使用独立密钥应通过
    const res = await request(app)
      .get('/internal/test')
      .set('X-Service-Name', 'UserService')
      .set('X-Service-Key', 'user-individual-key');
    expect(res.status).toBe(200);
    expect(res.body.serviceName).toBe('UserService');
  });

  it('独立密钥服务应拒绝全局密钥', async () => {
    const customConfig: GatewayConfig = {
      ...mockConfig,
      services: {
        ...mockConfig.services,
        userService: { name: 'UserService', url: 'http://localhost:5101', serviceKey: 'individual-key' },
      },
    };
    const app = express();
    const middleware = createServiceIdentityMiddleware(customConfig);
    app.use('/internal', middleware);
    app.get('/internal/test', (req, res) => {
      res.json({ serviceName: req.gatewayServiceName });
    });

    // 使用全局密钥应该失败
    const res = await request(app)
      .get('/internal/test')
      .set('X-Service-Name', 'UserService')
      .set('X-Service-Key', 'test-gateway-key');
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });
});

describe('safeCompare', () => {
  it('相同字符串应返回 true', async () => {
    const { safeCompare } = await import('../../src/middleware/serviceIdentity.js');
    expect(safeCompare('key1', 'key1')).toBe(true);
  });

  it('不同字符串应返回 false', async () => {
    const { safeCompare } = await import('../../src/middleware/serviceIdentity.js');
    expect(safeCompare('key1', 'key2')).toBe(false);
  });

  it('不同长度的字符串应返回 false', async () => {
    const { safeCompare } = await import('../../src/middleware/serviceIdentity.js');
    expect(safeCompare('short', 'a-very-long-key-that-is-different')).toBe(false);
  });

  it('空字符串不同应返回 false', async () => {
    const { safeCompare } = await import('../../src/middleware/serviceIdentity.js');
    expect(safeCompare('', 'a')).toBe(false);
  });

  it('两个空字符串应返回 true', async () => {
    const { safeCompare } = await import('../../src/middleware/serviceIdentity.js');
    expect(safeCompare('', '')).toBe(true);
  });
});
