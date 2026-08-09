import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { loadConfig } from '../src/config.js';

describe('loadConfig', () => {
  const originalEnv = { ...process.env };

  afterEach(() => {
    // 恢复原始 env
    process.env = { ...originalEnv };
  });

  it('应使用默认值当环境变量未设置时', () => {
    // 清除所有 Gateway 相关 env 变量
    for (const key of Object.keys(process.env)) {
      if (key.startsWith('GATEWAY_') || key.startsWith('CORS_') || key.startsWith('RL_') ||
          key.endsWith('_SERVICE_URL') || key.endsWith('_SERVICE_KEY') ||
          key === 'DEFAULT_TIMEOUT_MS' || key === 'UPLOAD_TIMEOUT_MS' ||
          key === 'READINESS_SERVICES') {
        delete process.env[key];
      }
    }

    const cfg = loadConfig();
    expect(cfg.port).toBe(5000);
    expect(cfg.host).toBe('127.0.0.1');
    expect(cfg.gatewayKey).toBe('moonstone-local-gateway-key');
    expect(cfg.corsOrigins).toEqual([
      'http://localhost:5120',
      'http://localhost:5121',
      'http://localhost:5122',
    ]);
    expect(cfg.defaultTimeoutMs).toBe(30_000);
    expect(cfg.uploadTimeoutMs).toBe(120_000);
    expect(cfg.services.userService.url).toBe('http://localhost:5101');
    expect(cfg.services.authService.url).toBe('http://localhost:5102');
    expect(cfg.services.fileService.url).toBe('http://localhost:5103');
    expect(cfg.services.knowledgeService.url).toBe('http://localhost:5104');
    expect(cfg.services.galGameService.url).toBe('http://localhost:5105');
    expect(cfg.services.renderService.url).toBe('http://localhost:5106');
    expect(cfg.services.practiceService.url).toBe('http://localhost:5107');
    expect(cfg.services.creditService.url).toBe('http://localhost:5108');
    expect(cfg.services.modelService.url).toBe('http://localhost:5109');
    expect(cfg.readinessServices).toEqual([
      'userService',
      'authService',
      'fileService',
      'knowledgeService',
      'modelService',
    ]);
    // 每服务 key 回退到全局 gatewayKey
    expect(cfg.services.userService.serviceKey).toBe(cfg.gatewayKey);
  });

  it('应读取环境变量覆盖默认值', () => {
    process.env.GATEWAY_PORT = '5297';
    process.env.GATEWAY_HOST = '10.0.0.5';
    process.env.GATEWAY_KEY = 'custom-key';
    process.env.CORS_ORIGINS = 'http://localhost:5298';
    process.env.DEFAULT_TIMEOUT_MS = '10000';
    process.env.USER_SERVICE_URL = 'http://custom:5261';

    const cfg = loadConfig();
    expect(cfg.port).toBe(5297);
    expect(cfg.host).toBe('10.0.0.5');
    expect(cfg.gatewayKey).toBe('custom-key');
    expect(cfg.corsOrigins).toEqual(['http://localhost:5298']);
    expect(cfg.defaultTimeoutMs).toBe(10_000);
    expect(cfg.services.userService.url).toBe('http://custom:5261');
  });

  it('应为每个服务配置独立密钥', () => {
    process.env.USER_SERVICE_KEY = 'user-key';
    process.env.AUTH_SERVICE_KEY = 'auth-key';

    const cfg = loadConfig();
    expect(cfg.services.userService.serviceKey).toBe('user-key');
    expect(cfg.services.authService.serviceKey).toBe('auth-key');
    // 未设置独立密钥的服务回退到全局 key
    expect(cfg.services.fileService.serviceKey).toBe(cfg.gatewayKey);
  });

  it('应处理 CORS_ORIGINS 中的多余空白和空段', () => {
    process.env.CORS_ORIGINS = ' http://a.com , , http://b.com , ';

    const cfg = loadConfig();
    expect(cfg.corsOrigins).toEqual(['http://a.com', 'http://b.com']);
  });

  it('CORS_ORIGINS 为空时应返回空数组', () => {
    process.env.CORS_ORIGINS = '';

    const cfg = loadConfig();
    expect(cfg.corsOrigins).toEqual([]);
  });

  it('envInt 应返回数字值', () => {
    process.env.GATEWAY_PORT = '5299';

    const cfg = loadConfig();
    expect(cfg.port).toBe(5299);
  });

  it('envInt 在非数字字符串时应返回 fallback', () => {
    process.env.GATEWAY_PORT = 'not-a-number';

    const cfg = loadConfig();
    expect(cfg.port).toBe(5000);
  });

  it('envInt 在空字符串时应返回 fallback', () => {
    process.env.DEFAULT_TIMEOUT_MS = '';

    const cfg = loadConfig();
    expect(cfg.defaultTimeoutMs).toBe(30_000);
  });

  it('应正确解析限流配置', () => {
    process.env.RL_ANONYMOUS_WINDOW_MS = '30000';
    process.env.RL_ANONYMOUS_MAX = '50';
    process.env.RL_UPLOAD_MAX = '5';
    process.env.RL_GENERATION_MAX = '3';
    process.env.RL_GENERAL_MAX = '200';

    const cfg = loadConfig();
    expect(cfg.rateLimit.anonymous.windowMs).toBe(30_000);
    expect(cfg.rateLimit.anonymous.max).toBe(50);
    expect(cfg.rateLimit.upload.max).toBe(5);
    expect(cfg.rateLimit.generation.max).toBe(3);
    expect(cfg.rateLimit.general.max).toBe(200);
  });

  it('应读取核心就绪服务列表并拒绝未知服务 key', () => {
    process.env.READINESS_SERVICES = ' authService, knowledgeService ';
    expect(loadConfig().readinessServices).toEqual([
      'authService',
      'knowledgeService',
    ]);

    process.env.READINESS_SERVICES = 'authService,unknownService';
    expect(() => loadConfig()).toThrow(
      'READINESS_SERVICES contains unknown service keys: unknownService',
    );
  });

  it('服务名应正确映射', () => {
    const cfg = loadConfig();
    expect(cfg.services.userService.name).toBe('UserService');
    expect(cfg.services.authService.name).toBe('AuthService');
    expect(cfg.services.fileService.name).toBe('FileService');
    expect(cfg.services.knowledgeService.name).toBe('KnowledgeService');
    expect(cfg.services.galGameService.name).toBe('GalGameService');
    expect(cfg.services.renderService.name).toBe('RenderService');
    expect(cfg.services.practiceService.name).toBe('PracticeService');
    expect(cfg.services.creditService.name).toBe('CreditService');
    expect(cfg.services.modelService.name).toBe('ModelService');
  });
});
