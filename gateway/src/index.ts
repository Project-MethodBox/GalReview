import { loadConfig } from './config.js';
import { createApp } from './app.js';
import { ROUTE_TABLE } from './routes/routeTable.js';

const config = loadConfig();
const app = createApp(config);

const host = config.host ?? '127.0.0.1';
const server = app.listen(config.port, host, () => {
  console.log(`[Gateway] listening on http://${host}:${config.port}`);
  console.log(`[Gateway] CORS origins: ${config.corsOrigins.join(', ')}`);
  console.log(`[Gateway] services:`);
  for (const [key, svc] of Object.entries(config.services)) {
    console.log(`  ${key} -> ${svc.url}`);
  }
});

// http-proxy-middleware registers one server lifecycle listener per proxy.
// The route table is finite and intentional, so size the warning threshold to it.
server.setMaxListeners(ROUTE_TABLE.length + 10);
