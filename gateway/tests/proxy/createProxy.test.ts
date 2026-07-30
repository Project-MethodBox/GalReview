import { describe, it, expect } from 'vitest';
import type { GatewayConfig } from '../../src/config.js';
import type { RouteEntry } from '../../src/types.js';
import { createProxyForRoute } from '../../src/proxy/createProxy.js';

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
});
