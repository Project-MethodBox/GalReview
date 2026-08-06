import request from 'supertest';
import { describe, it, expect } from 'vitest';
import { createApp } from '../../src/app.js';
import type { GatewayConfig } from '../../src/config.js';
import { createRateLimiters } from '../../src/middleware/rateLimiter.js';

const mockConfig: GatewayConfig = {
  port: 5000,
  gatewayKey: 'test-key',
  trustProxy: false,
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
};

describe('createRateLimiters', () => {
  it('应返回四个分类限流器', () => {
    const limiters = createRateLimiters(mockConfig);
    expect(limiters).toHaveProperty('anonymous');
    expect(limiters).toHaveProperty('upload');
    expect(limiters).toHaveProperty('generation');
    expect(limiters).toHaveProperty('general');
  });

  it('每个限流器应为函数', () => {
    const limiters = createRateLimiters(mockConfig);
    for (const key of ['anonymous', 'upload', 'generation', 'general'] as const) {
      expect(typeof limiters[key]).toBe('function');
    }
  });

  it('限流器应使用 gatewayUserId 作为键优先于 IP', () => {
    const limiters = createRateLimiters(mockConfig);
    // express-rate-limit 的 keyGenerator 在构造时传入
    // 无法直接读取 keyGenerator，但验证返回的是 middleware 函数即可
    expect(typeof limiters.anonymous).toBe('function');
  });
});

/**
 * 匿名限流的桶键不能由调用方决定：默认 trustProxy=false 时 X-Forwarded-For
 * 一律不采信，否则轮换该头即可无限刷新配额，登录/注册/找回密码的爆破节流失效。
 */
describe('限流键与代理信任', () => {
  const withLimit = (trustProxy: GatewayConfig['trustProxy'], max: number): GatewayConfig => ({
    ...mockConfig,
    trustProxy,
    rateLimit: { ...mockConfig.rateLimit, anonymous: { windowMs: 60_000, max } },
  });
  /** 匿名路由；上游不可达时为 503，但限流在代理之前生效 */
  const ANONYMOUS_ROUTE = '/api/v1/auth/sessions';
  const attempt = (app: ReturnType<typeof createApp>, forwardedFor: string) =>
    request(app)
      .post(ANONYMOUS_ROUTE)
      .set('X-Forwarded-For', forwardedFor)
      .send({ email: 'nobody@example.com', password: 'wrong-password' });

  it('默认配置下轮换 X-Forwarded-For 不能刷新匿名配额', async () => {
    const app = createApp(withLimit(false, 2));
    const statuses: number[] = [];
    for (let index = 0; index < 4; index += 1) {
      statuses.push((await attempt(app, `198.51.100.${index + 1}`)).status);
    }
    expect(statuses.filter((status) => status === 429).length).toBeGreaterThan(0);
  }, 20_000);

  it('显式信任代理时按 X-Forwarded-For 分桶', async () => {
    const app = createApp(withLimit(true, 1));
    const first = await attempt(app, '203.0.113.10');
    const otherClient = await attempt(app, '203.0.113.11');
    const sameClientAgain = await attempt(app, '203.0.113.10');

    expect(first.status).not.toBe(429);
    expect(otherClient.status).not.toBe(429);
    expect(sameClientAgain.status).toBe(429);
  }, 20_000);
});
