import 'dotenv/config';

export interface ServiceTarget {
  name: string;
  url: string;
  /** 每服务独立密钥；省略则回退到全局 gatewayKey */
  serviceKey?: string;
}

export interface GatewayConfig {
  port: number;
  host?: string;
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
  /** Token 内省短 TTL 缓存，减少 AuthService 压力；仅缓存 active=true 结果 */
  introspectionCache: {
    ttlMs: number;
    maxSize: number;
  };
}

function env(key: string, fallback: string): string {
  return process.env[key] ?? fallback;
}

function envRequired(key: string): string {
  const value = process.env[key];
  if (!value || value.trim().length === 0) {
    throw new Error(
      `Environment variable ${key} must be set. Refusing to start with a default service key.`,
    );
  }
  return value;
}

function envInt(key: string, fallback: number): number {
  const v = process.env[key];
  if (!v) return fallback;
  const n = parseInt(v, 10);
  return Number.isNaN(n) ? fallback : n;
}

export function loadConfig(): GatewayConfig {
  // GATEWAY_KEY 必须显式设置，不允许回退到默认值。
  // 使用默认密钥会让任何知道默认值的攻击者绕过 Gateway 鉴权。
  const gatewayKey = envRequired('GATEWAY_KEY');

  /** 读取每服务独立密钥，回退到全局密钥 */
  const svcKey = (envName: string) => env(envName, gatewayKey);

  const services: Record<string, ServiceTarget> = {
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
      // KnowledgeService 按契约在宿主机统一暴露 5104。
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
    port: envInt('GATEWAY_PORT', 5000),
    host: env('GATEWAY_HOST', '0.0.0.0'),
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
    introspectionCache: {
      // 短 TTL：默认 15 秒。仅缓存 active=true 结果，令牌撤销最长延迟 = TTL。
      ttlMs: envInt('INTROSPECTION_CACHE_TTL_MS', 15_000),
      // 上限：默认 4096 条。LRU 淘汰最旧条目，防止内存膨胀。
      maxSize: envInt('INTROSPECTION_CACHE_MAX_SIZE', 4_096),
    },
  };
}

