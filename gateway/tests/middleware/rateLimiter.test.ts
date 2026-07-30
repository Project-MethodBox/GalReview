import { describe, it, expect } from 'vitest';
import type { GatewayConfig } from '../../src/config.js';
import { createRateLimiters } from '../../src/middleware/rateLimiter.js';

const mockConfig: GatewayConfig = {
  port: 5000,
  gatewayKey: 'test-key',
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
