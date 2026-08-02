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
  /** /readyz 必须可达的核心服务 key；省略时兼容性地探测全部服务 */
  readinessServices?: string[];
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

function envPort(key: string, fallback: number): number {
  const value = envInt(key, fallback);
  if (value < 5000 || value > 5300) {
    throw new RangeError(`${key} must be between 5000 and 5300`);
  }
  return value;
}

function serviceUrl(key: string, fallback: string): string {
  const value = env(key, fallback);
  const url = new URL(value);
  if (url.port) {
    const port = Number.parseInt(url.port, 10);
    if (port < 5000 || port > 5300) {
      throw new RangeError(`${key} port must be between 5000 and 5300`);
    }
  }
  return value;
}

export function loadConfig(): GatewayConfig {
  const gatewayKey = env('GATEWAY_KEY', 'moonstone-local-gateway-key');

  /** 读取每服务独立密钥，回退到全局密钥 */
  const svcKey = (envName: string) => env(envName, gatewayKey);

  const services: Record<string, ServiceTarget> = {
    userService: {
      name: 'UserService',
      url: serviceUrl('USER_SERVICE_URL', 'http://localhost:5101'),
      serviceKey: svcKey('USER_SERVICE_KEY'),
    },
    authService: {
      name: 'AuthService',
      url: serviceUrl('AUTH_SERVICE_URL', 'http://localhost:5102'),
      serviceKey: svcKey('AUTH_SERVICE_KEY'),
    },
    fileService: {
      name: 'FileService',
      url: serviceUrl('FILE_SERVICE_URL', 'http://localhost:5103'),
      serviceKey: svcKey('FILE_SERVICE_KEY'),
    },
    knowledgeService: {
      name: 'KnowledgeService',
      url: serviceUrl('KNOWLEDGE_SERVICE_URL', 'http://localhost:5104'),
      serviceKey: svcKey('KNOWLEDGE_SERVICE_KEY'),
    },
    galGameService: {
      name: 'GalGameService',
      url: serviceUrl('GALGAME_SERVICE_URL', 'http://localhost:5105'),
      serviceKey: svcKey('GALGAME_SERVICE_KEY'),
    },
    renderService: {
      name: 'RenderService',
      url: serviceUrl('RENDER_SERVICE_URL', 'http://localhost:5106'),
      serviceKey: svcKey('RENDER_SERVICE_KEY'),
    },
  };
  const readinessServices = env(
    'READINESS_SERVICES',
    'userService,authService,fileService,knowledgeService',
  )
    .split(',')
    .map((value) => value.trim())
    .filter(Boolean);
  const unknownReadinessServices = readinessServices.filter(
    (serviceKey) => !services[serviceKey],
  );
  if (unknownReadinessServices.length > 0) {
    throw new Error(
      `READINESS_SERVICES contains unknown service keys: ${unknownReadinessServices.join(', ')}`,
    );
  }

  return {
    port: envPort('GATEWAY_PORT', 5000),
    gatewayKey,
    corsOrigins: env('CORS_ORIGINS', 'http://localhost:5120,http://localhost:5121,http://localhost:5122')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean),
    defaultTimeoutMs: envInt('DEFAULT_TIMEOUT_MS', 30_000),
    uploadTimeoutMs: envInt('UPLOAD_TIMEOUT_MS', 120_000),
    readinessServices,
    services,
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
