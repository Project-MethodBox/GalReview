import { describe, it, expect, beforeEach } from 'vitest';
import express from 'express';
import request from 'supertest';
import { headerSanitizerMiddleware } from '../../src/middleware/headerSanitizer.js';

function createTestApp() {
  const app = express();
  app.use(headerSanitizerMiddleware);
  app.get('/api/test', (req, res) => {
    res.json({
      serviceName: req.headers['x-service-name'] ?? null,
      serviceKey: req.headers['x-service-key'] ?? null,
      userId: req.headers['x-user-id'] ?? null,
      gatewayKey: req.headers['x-gateway-key'] ?? null,
      correlationId: req.headers['x-correlation-id'] ?? null,
    });
  });
  app.get('/internal/test', (req, res) => {
    res.json({
      serviceName: req.headers['x-service-name'] ?? null,
      serviceKey: req.headers['x-service-key'] ?? null,
      userId: req.headers['x-user-id'] ?? null,
      gatewayKey: req.headers['x-gateway-key'] ?? null,
    });
  });
  return app;
}

describe('headerSanitizerMiddleware', () => {
  let app: express.Express;

  beforeEach(() => {
    app = createTestApp();
  });

  describe('/api/ 路由（浏览器）', () => {
    it('应剥离客户端伪造的 X-Service-Name', async () => {
      const res = await request(app)
        .get('/api/test')
        .set('X-Service-Name', 'FakeService');
      expect(res.status).toBe(200);
      expect(res.body.serviceName).toBeNull();
    });

    it('应剥离客户端伪造的 X-User-Id', async () => {
      const res = await request(app)
        .get('/api/test')
        .set('X-User-Id', 'fake-user-id');
      expect(res.status).toBe(200);
      expect(res.body.userId).toBeNull();
    });

    it('应剥离客户端伪造的 X-Gateway-Key', async () => {
      const res = await request(app)
        .get('/api/test')
        .set('X-Gateway-Key', 'stolen-key');
      expect(res.status).toBe(200);
      expect(res.body.gatewayKey).toBeNull();
    });

    it('应剥离客户端伪造的 X-Service-Key', async () => {
      const res = await request(app)
        .get('/api/test')
        .set('X-Service-Key', 'stolen-service-key');
      expect(res.status).toBe(200);
      expect(res.body.serviceKey).toBeNull();
    });

    it('不应剥离 X-Correlation-Id（非内部身份头）', async () => {
      const res = await request(app)
        .get('/api/test')
        .set('X-Correlation-Id', 'trace-123');
      expect(res.status).toBe(200);
      expect(res.body.correlationId).toBe('trace-123');
    });

    it('应同时剥离多个伪造头', async () => {
      const res = await request(app)
        .get('/api/test')
        .set('X-Service-Name', 'Evil')
        .set('X-User-Id', 'admin')
        .set('X-Gateway-Key', 'key');
      expect(res.status).toBe(200);
      expect(res.body.serviceName).toBeNull();
      expect(res.body.userId).toBeNull();
      expect(res.body.gatewayKey).toBeNull();
    });

    it('无内部身份头时不应影响正常请求', async () => {
      const res = await request(app).get('/api/test');
      expect(res.status).toBe(200);
      expect(res.body.serviceName).toBeNull();
    });
  });

  describe('/internal/ 路由（服务间）', () => {
    it('应保留 X-Service-Name 供后续验证', async () => {
      const res = await request(app)
        .get('/internal/test')
        .set('X-Service-Name', 'KnowledgeService')
        .set('X-Service-Key', 'valid-key');
      expect(res.status).toBe(200);
      expect(res.body.serviceName).toBe('KnowledgeService');
      expect(res.body.serviceKey).toBe('valid-key');
    });

    it('应剥离伪造的 X-User-Id', async () => {
      const res = await request(app)
        .get('/internal/test')
        .set('X-User-Id', 'hacker')
        .set('X-Service-Name', 'AuthService')
        .set('X-Service-Key', 'key');
      expect(res.status).toBe(200);
      expect(res.body.userId).toBeNull();
      expect(res.body.serviceName).toBe('AuthService');
    });

    it('应剥离伪造的 X-Gateway-Key', async () => {
      const res = await request(app)
        .get('/internal/test')
        .set('X-Gateway-Key', 'stolen')
        .set('X-Service-Name', 'RenderService')
        .set('X-Service-Key', 'key');
      expect(res.status).toBe(200);
      expect(res.body.gatewayKey).toBeNull();
      expect(res.body.serviceName).toBe('RenderService');
    });

    it('无伪造头时 /internal 正常保留服务身份', async () => {
      const res = await request(app)
        .get('/internal/test')
        .set('X-Service-Name', 'AuthService')
        .set('X-Service-Key', 'my-key');
      expect(res.status).toBe(200);
      expect(res.body.serviceName).toBe('AuthService');
      expect(res.body.serviceKey).toBe('my-key');
    });
  });

  describe('getServiceNameFromHeaders / getServiceKeyFromHeaders', () => {
    it('应提取单值 X-Service-Name', async () => {
      const { getServiceNameFromHeaders, getServiceKeyFromHeaders } = await import('../../src/middleware/headerSanitizer.js');
      const headers = { 'x-service-name': 'UserService' };
      expect(getServiceNameFromHeaders(headers)).toBe('UserService');
    });

    it('应从数组中提取第一个 X-Service-Name', async () => {
      const { getServiceNameFromHeaders } = await import('../../src/middleware/headerSanitizer.js');
      const headers = { 'x-service-name': ['First', 'Second'] };
      expect(getServiceNameFromHeaders(headers)).toBe('First');
    });

    it('X-Service-Name 缺失时返回 undefined', async () => {
      const { getServiceNameFromHeaders } = await import('../../src/middleware/headerSanitizer.js');
      const headers = {};
      expect(getServiceNameFromHeaders(headers)).toBeUndefined();
    });

    it('应提取单值 X-Service-Key', async () => {
      const { getServiceKeyFromHeaders } = await import('../../src/middleware/headerSanitizer.js');
      const headers = { 'x-service-key': 'secret-key' };
      expect(getServiceKeyFromHeaders(headers)).toBe('secret-key');
    });

    it('应从数组中提取第一个 X-Service-Key', async () => {
      const { getServiceKeyFromHeaders } = await import('../../src/middleware/headerSanitizer.js');
      const headers = { 'x-service-key': ['key1', 'key2'] };
      expect(getServiceKeyFromHeaders(headers)).toBe('key1');
    });
  });
});
