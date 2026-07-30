import 'dotenv/config';

export interface ServiceTarget {
  name: string;
  url: string;
  /** 每服务独立密钥；省略则回退到全局 gatewayKey */
  serviceKey?: string;
}

export interface GatewayConfig {
  port: number;
  gatewayKey: string;
  corsOrigins: string[];
  defaultTimeoutMs: number;
  uploadTimeoutMs: number;
  services: Record<string, ServiceTarget>;
  rateLimit: {
    anonymous: { windowMs: number; max: number };
    upload: { windowMs: number; max: number };
    generation: { windowMs: number; max: number };
    general: { windowMs: number; max: number };
  };
}

function env(key: string, fallback: string): string {
  return process.env[key] ?? fallback;
}

function envInt(key: string, fallback: number): number {
  const v = process.env[key];
  if (!v) return fallback;
  const n = parseInt(v, 10);
  return Number.isNaN(n) ? fallback : n;
}

export function loadConfig(): GatewayConfig {
  const gatewayKey = env('GATEWAY_KEY', 'moonstone-local-gateway-key');

  /** 读取每服务独立密钥，回退到全局密钥 */
  const svcKey = (envName: string) => env(envName, gatewayKey);

  return {
    port: envInt('GATEWAY_PORT', 5000),
    gatewayKey,
    corsOrigins: env('CORS_ORIGINS', 'http://localhost:5173,http://localhost:5174')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean),
    defaultTimeoutMs: envInt('DEFAULT_TIMEOUT_MS', 30_000),
    uploadTimeoutMs: envInt('UPLOAD_TIMEOUT_MS', 120_000),
    services: {
      userService: {
        name: 'UserService',
        url: env('USER_SERVICE_URL', 'http://localhost:5101'),
        serviceKey: svcKey('USER_SERVICE_KEY'),
      },
      authService: {
        name: 'AuthService',
        url: env('AUTH_SERVICE_URL', 'http://localhost:5102'),
        serviceKey: svcKey('AUTH_SERVICE_KEY'),
      },
      fileService: {
        name: 'FileService',
        url: env('FILE_SERVICE_URL', 'http://localhost:5103'),
        serviceKey: svcKey('FILE_SERVICE_KEY'),
      },
      knowledgeService: {
        name: 'KnowledgeService',
        url: env('KNOWLEDGE_SERVICE_URL', 'http://localhost:5104'),
        serviceKey: svcKey('KNOWLEDGE_SERVICE_KEY'),
      },
      galGameService: {
        name: 'GalGameService',
        url: env('GALGAME_SERVICE_URL', 'http://localhost:5105'),
        serviceKey: svcKey('GALGAME_SERVICE_KEY'),
      },
      renderService: {
        name: 'RenderService',
        url: env('RENDER_SERVICE_URL', 'http://localhost:5106'),
        serviceKey: svcKey('RENDER_SERVICE_KEY'),
      },
    },
    rateLimit: {
      anonymous: {
        windowMs: envInt('RL_ANONYMOUS_WINDOW_MS', 60_000),
        max: envInt('RL_ANONYMOUS_MAX', 20),
      },
      upload: {
        windowMs: envInt('RL_UPLOAD_WINDOW_MS', 60_000),
        max: envInt('RL_UPLOAD_MAX', 10),
      },
      generation: {
        windowMs: envInt('RL_GENERATION_WINDOW_MS', 60_000),
        max: envInt('RL_GENERATION_MAX', 5),
      },
      general: {
        windowMs: envInt('RL_GENERAL_WINDOW_MS', 60_000),
        max: envInt('RL_GENERAL_MAX', 120),
      },
    },
  };
}
