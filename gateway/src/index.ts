import { loadConfig } from './config.js';
import { createApp } from './app.js';

const config = loadConfig();
const app = createApp(config);

app.listen(config.port, () => {
  console.log(`[Gateway] listening on :${config.port}`);
  console.log(`[Gateway] CORS origins: ${config.corsOrigins.join(', ')}`);
  console.log(`[Gateway] services:`);
  for (const [key, svc] of Object.entries(config.services)) {
    console.log(`  ${key} -> ${svc.url}`);
  }
});
