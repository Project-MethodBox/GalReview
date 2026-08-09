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
  /**
   * Express `trust proxy` 设置：决定是否根据 X-Forwarded-For 还原客户端 IP。
   * 默认 false —— 只认 socket 对端地址，客户端自带的 XFF 一律忽略，否则任何人
   * 都能靠轮换该头拿到全新的匿名限流桶（登录爆破防护失效）。
   * 网关位于可信反向代理之后时，用 TRUST_PROXY 显式列出该代理的地址/网段
   * （如 `172.18.0.0/16`）或 Express 预设（`loopback` / `uniquelocal`）。
   */
  trustProxy: boolean | number | string;
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
  const v = process.env[key];
  // key exists (even if empty) → return the actual value; absent → fallback
  return v !== undefined ? v : fallback;
}

function envInt(key: string, fallback: number): number {
  const v = process.env[key];
  if (!v) return fallback;
  const n = Number(v);
  return Number.isFinite(n) ? n : fallback;
}

/**
 * 解析 TRUST_PROXY：未设置或 false/0 → 不信任任何 XFF（默认，最安全）；
 * 纯数字 → 信任的代理跳数；其余按 Express 语法原样传递（IP、CIDR、
 * 逗号分隔列表、loopback/linklocal/uniquelocal 预设）。
 */
function envTrustProxy(key: string): boolean | number | string {
  const raw = process.env[key]?.trim();
  if (!raw) return false;
  const lowered = raw.toLowerCase();
  if (lowered === 'false' || lowered === 'off' || lowered === 'no') return false;
  if (lowered === 'true') return true;
  if (/^\d+$/.test(raw)) return Number.parseInt(raw, 10);
  return raw;
}

export function loadConfig(): GatewayConfig {
  const gatewayKey = env('GATEWAY_KEY', 'moonstone-local-gateway-key');
  if (!gatewayKey || gatewayKey.trim().length === 0) {
    throw new Error('GATEWAY_KEY must not be empty');
  }

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
    practiceService: {
      name: 'PracticeService',
      url: env('PRACTICE_SERVICE_URL', 'http://localhost:5107'),
      serviceKey: svcKey('PRACTICE_SERVICE_KEY'),
    },
    creditService: {
      name: 'CreditService',
      url: env('CREDIT_SERVICE_URL', 'http://localhost:5108'),
      serviceKey: svcKey('CREDIT_SERVICE_KEY'),
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
    host: env('GATEWAY_HOST', '127.0.0.1'),
    gatewayKey,
    trustProxy: envTrustProxy('TRUST_PROXY'),
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
