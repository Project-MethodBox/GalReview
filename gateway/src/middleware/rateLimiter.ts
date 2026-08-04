import rateLimit, { type RateLimitRequestHandler, type Store, type Options } from 'express-rate-limit';
import type { Request, Response } from 'express';
import type { GatewayConfig } from '../config.js';
import { buildApiFailure, getTraceId } from '../types.js';

/** 限流键生成：优先用已认证的 userId，否则按 IP */
function keyGenerator(req: Request): string {
  return req.gatewayUserId ?? req.ip ?? 'unknown';
}

/**
 * Redis 限流存储（基于 INCR + EXPIRE）。
 *
 * 为何自实现而不引入 rate-limit-redis：
 * - 项目依赖最小化原则；express-rate-limit v7 的 Store 接口足够简单
 * - 使用动态 import('ioredis')，未配置 Redis 时不引入该包
 *
 * 多实例行为：所有 Gateway 实例共享同一 Redis 计数，窗口由 EXPIRE 自动过期；
 * 因 INCR 与 EXPIRE 不在同一个 MULTI 事务中，理论上首请求的 EXPIRE 可能丢失，
 * 但 Redis INCR 在键不存在时会自动创建，下一请求会再次设置 EXPIRE，影响仅是
 * 窗口略长一次，对限流精度无实质损害。
 *
 * express-rate-limit v7 的 Store 接口要求 increment/decrement/resetKey 只接受
 * key 参数；windowMs 通过 init(options) 在 limiter 构造时注入。
 */
export class RedisRateLimitStore implements Store {
  private client: unknown;
  private readonly redisUrl: string;
  // windowMs 由 express-rate-limit 通过 init() 注入；每个 store 实例对应一个 limiter。
  private windowMs = 60_000;
  // 命名空间前缀：多个 store 共享同一 Redis 时按 prefix 隔离
  private readonly namespace: string;
  readonly kind = 'redis' as const;

  constructor(redisUrl: string, namespace = 'default') {
    this.redisUrl = redisUrl;
    this.namespace = namespace;
  }

  async connect(): Promise<void> {
    const { default: Redis } = await import('ioredis');
    this.client = new Redis(this.redisUrl, {
      // 限流为非关键路径：Redis 不可用时回退到内存存储更优，这里直接抛错
      // 让上层决定是否继续启动。连接重试由 ioredis 内置处理。
      maxRetriesPerRequest: 3,
      enableReadyCheck: true,
      lazyConnect: false,
    });
  }

  /** 注入已建立的 ioredis 客户端，多个 store 共享同一连接 */
  attachClient(client: unknown): this {
    this.client = client;
    return this;
  }

  /** express-rate-limit 在构造 limiter 时调用，传入完整 options */
  init(options: Options): void {
    this.windowMs = options.windowMs;
  }

  private async sendCommand(command: string, ...args: unknown[]): Promise<unknown> {
    const client = this.client as { call?(...args: unknown[]): Promise<unknown> } | null;
    if (!client || typeof client.call !== 'function') {
      throw new Error('Redis client not connected');
    }
    return client.call(command, ...args);
  }

  async increment(key: string): Promise<{ totalHits: number; resetTime: Date | undefined }> {
    const redisKey = `ratelimit:${this.namespace}:${key}`;
    const totalHits = (await this.sendCommand('INCR', redisKey)) as number;
    // 仅在首次创建键时设置 TTL，避免每个请求都刷新窗口（固定窗口语义）
    if (totalHits === 1) {
      await this.sendCommand('PEXPIRE', redisKey, this.windowMs);
    }
    const pttl = (await this.sendCommand('PTTL', redisKey)) as number;
    const resetTime = pttl > 0 ? new Date(Date.now() + pttl) : undefined;
    return { totalHits, resetTime };
  }

  async decrement(key: string): Promise<void> {
    const redisKey = `ratelimit:${this.namespace}:${key}`;
    await this.sendCommand('DECR', redisKey);
  }

  async resetKey(key: string): Promise<void> {
    const redisKey = `ratelimit:${this.namespace}:${key}`;
    await this.sendCommand('DEL', redisKey);
  }
}

/**
 * 构建限流存储工厂。返回 null 表示使用 express-rate-limit 默认的内存存储。
 *
 * 每个分类限流器需要独立的 RedisRateLimitStore 实例（携带自己的 namespace 与 windowMs），
 * 因为 express-rate-limit v7 的 Store 接口在 increment() 时只传 key 不传 options。
 * 这里返回一个工厂函数 makeStore(namespace)，由 createRateLimiters 为每个分类调用。
 */
export async function createRateLimitStoreFactory(
  config: GatewayConfig,
): Promise<((namespace: string) => Store) | null> {
  if (!config.rateLimitRedisUrl) return null;
  // 共享连接：所有 store 实例使用同一个 ioredis 客户端
  const { default: Redis } = await import('ioredis');
  const client = new Redis(config.rateLimitRedisUrl, {
    maxRetriesPerRequest: 3,
    enableReadyCheck: true,
    lazyConnect: false,
  });
  try {
    // 触发实际连接验证
    await client.call('PING');
    console.log(
      `[Gateway] rate-limit store: redis (${config.rateLimitRedisUrl.replace(/:[^:@]+@/, ':****@')})`,
    );
  } catch (error) {
    // ioredis disconnect() 在某些版本返回 void；try/catch 包裹避免影响主流程
    try {
      await (client as { disconnect: () => Promise<void> | void }).disconnect();
    } catch {
      // ignore disconnect errors
    }
    throw new Error(
      `Failed to connect Redis rate-limit store: ${error instanceof Error ? error.message : String(error)}. ` +
        `Unset RATELIMIT_REDIS_URL to fall back to in-memory store.`,
    );
  }
  return (namespace: string) => new RedisRateLimitStore(config.rateLimitRedisUrl!, namespace).attachClient(client);
}

/** 构建单个限流器 */
function buildLimiter(
  windowMs: number,
  max: number,
  store?: Store,
): RateLimitRequestHandler {
  return rateLimit({
    windowMs,
    max,
    standardHeaders: true,
    legacyHeaders: false,
    store,
    handler: (req: Request, res: Response) => {
      const traceId = getTraceId(req);
      res.status(429).json(buildApiFailure('RATE_LIMITED', '请求过于频繁，请稍后再试', traceId));
    },
    keyGenerator,
  });
}

/**
 * 创建分类限流器
 * - anonymous: 登录、注册、密码恢复等匿名接口
 * - upload: 文件上传
 * - generation: 游戏生成、图谱构建等长任务
 * - general: 普通读取
 *
 * 当 storeFactory 提供时，每个分类创建独立的 RedisRateLimitStore（共享 Redis 连接，
 * 按 namespace 隔离计数）；否则使用进程内存存储。
 */
export function createRateLimiters(
  config: GatewayConfig,
  storeFactory?: ((namespace: string) => Store) | null,
) {
  return {
    anonymous: buildLimiter(
      config.rateLimit.anonymous.windowMs,
      config.rateLimit.anonymous.max,
      storeFactory?.('anonymous'),
    ),
    upload: buildLimiter(
      config.rateLimit.upload.windowMs,
      config.rateLimit.upload.max,
      storeFactory?.('upload'),
    ),
    generation: buildLimiter(
      config.rateLimit.generation.windowMs,
      config.rateLimit.generation.max,
      storeFactory?.('generation'),
    ),
    general: buildLimiter(
      config.rateLimit.general.windowMs,
      config.rateLimit.general.max,
      storeFactory?.('general'),
    ),
  };
}
