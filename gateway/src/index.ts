import { loadConfig } from './config.js';
import { createApp } from './app.js';
import { ROUTE_TABLE } from './routes/routeTable.js';

const config = loadConfig();
const app = createApp(config);

const host = config.host || '127.0.0.1';
const server = app.listen(config.port, host, () => {
  console.log(`[Gateway] listening on http://${host}:${config.port}`);
  console.log(`[Gateway] CORS origins: ${config.corsOrigins.join(', ')}`);
  console.log(`[Gateway] services:`);
  for (const [key, svc] of Object.entries(config.services)) {
    console.log(`  ${key} -> ${svc.url}`);
  }
});

server.setMaxListeners(ROUTE_TABLE.length + 10);

server.on('error', (err: NodeJS.ErrnoException) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`[Gateway] Port ${config.port} is already in use`);
  } else {
    console.error('[Gateway] Server error:', err);
  }
  process.exit(1);
});

process.on('SIGTERM', () => {
  console.log('[Gateway] SIGTERM received, shutting down...');
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 10_000).unref();
});

process.on('SIGINT', () => {
  console.log('[Gateway] SIGINT received, shutting down...');
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 10_000).unref();
});
