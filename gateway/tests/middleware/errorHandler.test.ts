import { describe, it, expect, beforeEach } from 'vitest';
import express from 'express';
import request from 'supertest';
import { errorHandlerMiddleware, notFoundHandler } from '../../src/middleware/errorHandler.js';

describe('errorHandlerMiddleware', () => {
  function createTestApp(throwError?: Error & { status?: number; code?: string }) {
    const app = express();
    // 加一个路由主动抛错
    app.get('/error', () => {
      if (throwError) throw throwError;
      throw new Error('unexpected');
    });
    // 加一个路由挂载 traceId
    app.get('/with-trace', (req, _res, next) => {
      (req as any).traceId = 'trace-123';
      if (throwError) throw throwError;
      throw new Error('test error');
    });
    app.use(errorHandlerMiddleware);
    return app;
  }

  it('未处理错误应返回 500 和 INTERNAL_ERROR', async () => {
    const app = createTestApp();
    const res = await request(app).get('/error');
    expect(res.status).toBe(500);
    expect(res.body.data).toBeNull();
    expect(res.body.error.code).toBe('INTERNAL_ERROR');
    expect(res.body.error.message).toBe('服务内部错误');
    expect(res.body.traceId).toBeDefined();
  });

  it('应保留自定义 status 和 code', async () => {
    const err = new Error('请求体格式错误') as Error & { status?: number; code?: string };
    err.status = 400;
    err.code = 'VALIDATION_ERROR';
    const app = createTestApp(err);
    const res = await request(app).get('/error');
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
    expect(res.body.error.message).toBe('请求体格式错误');
  });

  it('status >= 500 时应屏蔽原始消息', async () => {
    const err = new Error('数据库连接失败') as Error & { status?: number; code?: string };
    err.status = 503;
    err.code = 'SERVICE_UNAVAILABLE';
    const app = createTestApp(err);
    const res = await request(app).get('/error');
    expect(res.status).toBe(503);
    expect(res.body.error.message).toBe('服务内部错误');
  });

  it('空 code 应回退到 INTERNAL_ERROR', async () => {
    const err = new Error('no code') as Error & { status?: number; code?: string };
    err.status = 422;
    err.code = '';
    const app = createTestApp(err);
    const res = await request(app).get('/error');
    expect(res.status).toBe(422);
    expect(res.body.error.code).toBe('INTERNAL_ERROR');
  });

  it('无 status 应回退到 500', async () => {
    const err = new Error('plain error') as Error & { status?: number; code?: string };
    err.code = 'DB_ERROR';
    const app = createTestApp(err);
    const res = await request(app).get('/error');
    expect(res.status).toBe(500);
    expect(res.body.error.code).toBe('DB_ERROR');
  });

  it('无 code 应回退到 INTERNAL_ERROR', async () => {
    const err = new Error('no code') as Error & { status?: number; code?: string };
    err.status = 400;
    const app = createTestApp(err);
    const res = await request(app).get('/error');
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('INTERNAL_ERROR');
  });

  it('headersSent 时应跳过（不抛二次错误）', async () => {
    const app = express();
    app.get('/headers-sent', (req, res, _next) => {
      res.json({ ok: true });
      // 在 headersSent 后模拟错误 — errorHandler 应静默跳过
      throw new Error('late error');
    });
    app.use(errorHandlerMiddleware);

    const res = await request(app).get('/headers-sent');
    expect(res.status).toBe(200);
    expect(res.body.ok).toBe(true);
  });

  it('应返回统一 ApiFailure 格式', async () => {
    const app = createTestApp();
    const res = await request(app).get('/error');
    expect(res.body).toEqual({
      data: null,
      error: expect.objectContaining({
        code: expect.any(String),
        message: expect.any(String),
        details: expect.any(Object),
      }),
      traceId: expect.any(String),
    });
  });
});

describe('notFoundHandler', () => {
  function createTestApp() {
    const app = express();
    app.use(notFoundHandler);
    return app;
  }

  it('应返回 404 RESOURCE_NOT_FOUND', async () => {
    const app = createTestApp();
    const res = await request(app).get('/any-route');
    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe('RESOURCE_NOT_FOUND');
    expect(res.body.error.message).toBe('路由不存在');
    expect(res.body.data).toBeNull();
    expect(res.body.traceId).toBeDefined();
  });

  it('traceId 在无 traceContext 时应为 unknown', async () => {
    const app = createTestApp();
    const res = await request(app).get('/test');
    expect(res.body.traceId).toBe('unknown');
  });
});
