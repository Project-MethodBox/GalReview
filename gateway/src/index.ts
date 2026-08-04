import { loadConfig } from './config.js';
import { createApp } from './app.js';
import { createRateLimitStoreFactory } from './middleware/rateLimiter.js';
import { ROUTE_TABLE } from './routes/routeTable.js';

const config = loadConfig();

// 限流存储在启动时一次性初始化：配置了 RATELIMIT_REDIS_URL 时使用 Redis（多实例共享），
// 否则返回 null，createApp 内部回退到进程内存存储。
// 必须在 createApp 之前 await，因为 Redis 连接失败应让进程直接退出而不是带着降级的
// 限流策略静默启动。
createRateLimitStoreFactory(config)
  .then((rateLimitStoreFactory) => {
    const app = createApp(config, rateLimitStoreFactory ?? undefined);

    const server = app.listen(config.port, () => {
      console.log(`[Gateway] listening on :${config.port}`);
      console.log(`[Gateway] CORS origins: ${config.corsOrigins.join(', ')}`);
      console.log(`[Gateway] rate-limit store: ${rateLimitStoreFactory ? 'redis' : 'memory'}`);
      console.log(`[Gateway] services:`);
      for (const [key, svc] of Object.entries(config.services)) {
        console.log(`  ${key} -> ${svc.url}`);
      }
    });

    // http-proxy-middleware registers one server lifecycle listener per proxy.
    // The route table is finite and intentional, so size the warning threshold to it.
    server.setMaxListeners(ROUTE_TABLE.length + 10);
  })
  .catch((error) => {
    console.error(`[Gateway] startup failed: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  });
