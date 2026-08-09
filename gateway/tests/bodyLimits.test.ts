import { createServer, request as httpRequest } from 'node:http';
import type { Server } from 'node:http';
import { describe, expect, it } from 'vitest';
import { createApp, MAX_UPLOAD_REQUEST_BYTES } from '../src/app.js';
import type { GatewayConfig } from '../src/config.js';
import { listenOnTestPort } from './support/testPorts.js';

/**
 * chunked（无 Content-Length）请求体的上限。app.ts 的早拒只能读 Content-Length，
 * 因此这条路径由代理阶段的流式计数兜底，两者阈值必须一致。
 */

const baseConfig: GatewayConfig = {
  port: 5000,
  gatewayKey: 'test-gateway-key',
  trustProxy: false,
  corsOrigins: ['http://localhost:5173'],
  defaultTimeoutMs: 5000,
  uploadTimeoutMs: 10000,
  services: {
    userService: { name: 'UserService', url: 'http://127.0.0.1:5251' },
    authService: { name: 'AuthService', url: 'http://127.0.0.1:5252' },
    fileService: { name: 'FileService', url: 'http://127.0.0.1:5253' },
    knowledgeService: { name: 'KnowledgeService', url: 'http://127.0.0.1:5254' },
    galGameService: { name: 'GalGameService', url: 'http://127.0.0.1:5255' },
    renderService: { name: 'RenderService', url: 'http://127.0.0.1:5256' },
    practiceService: { name: 'PracticeService', url: 'http://127.0.0.1:5257' },
    creditService: { name: 'CreditService', url: 'http://127.0.0.1:5258' },
    modelService: { name: 'ModelService', url: 'http://127.0.0.1:5259' },
  },
  rateLimit: {
    anonymous: { windowMs: 60_000, max: 100 },
    upload: { windowMs: 60_000, max: 100 },
    generation: { windowMs: 60_000, max: 100 },
    general: { windowMs: 60_000, max: 1000 },
  },
};

interface Harness {
  origin: string;
  close(): Promise<void>;
}

/** 可达的假上游：完整消费请求体后回 200，使计数器有机会在流式阶段生效 */
async function startUpstream(): Promise<{ origin: string; close(): Promise<void> }> {
  const server: Server = createServer((req, res) => {
    req.on('data', () => {});
    req.on('end', () => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ data: { ok: true }, meta: {}, traceId: 'upstream' }));
    });
    req.on('error', () => {});
  });
  const origin = await listenOnTestPort(server);
  return { origin, close: () => new Promise((resolve) => server.close(() => resolve())) };
}

async function startGateway(upstreamOrigin: string): Promise<Harness> {
  const config: GatewayConfig = {
    ...baseConfig,
    services: {
      ...baseConfig.services,
      authService: { name: 'AuthService', url: upstreamOrigin },
    },
  };
  const server: Server = createServer(createApp(config));
  const origin = await listenOnTestPort(server);
  return { origin, close: () => new Promise((resolve) => server.close(() => resolve())) };
}

/** 以 chunked 编码流式发送指定字节数，返回最终响应（或 socket 错误） */
function chunkedPost(origin: string, path: string, totalBytes: number, token: string) {
  const url = new URL(origin);
  const req = httpRequest({
    host: url.hostname,
    port: url.port,
    path,
    method: 'POST',
    headers: {
      'Content-Type': 'application/octet-stream',
      'Transfer-Encoding': 'chunked',
      Authorization: `Bearer ${token}`,
    },
  });
  const errors: string[] = [];
  req.on('error', (error: NodeJS.ErrnoException) => errors.push(error.code ?? error.message));
  const response = new Promise<{ status: number; body: string } | null>((resolve) => {
    req.on('response', (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (chunk: string) => {
        body += chunk;
      });
      res.on('end', () => resolve({ status: res.statusCode ?? 0, body }));
    });
    req.on('close', () => resolve(null));
  });

  const chunk = Buffer.alloc(256 * 1024, 0x61);
  let sent = 0;
  const pump = (): void => {
    if (req.destroyed || req.writableEnded) return;
    if (sent >= totalBytes) {
      req.end();
      return;
    }
    sent += chunk.length;
    req.write(chunk, () => setImmediate(pump));
  };
  pump();
  return { response, errors };
}

describe('chunked 请求体上限', () => {
  it('无 Content-Length 的超大请求体按契约返回 413 信封', async () => {
    const upstream = await startUpstream();
    const harness = await startGateway(upstream.origin);
    try {
      // 匿名路由：不需要用户令牌，限流与代理之前不会被 401 截断
      const { response } = chunkedPost(
        harness.origin,
        '/api/v1/auth/sessions',
        MAX_UPLOAD_REQUEST_BYTES + 2 * 1024 * 1024,
        'unused',
      );
      const result = await response;
      expect(result).not.toBeNull();
      expect(result!.status).toBe(413);
      const payload = JSON.parse(result!.body) as { error?: { code?: string } };
      expect(payload.error?.code).toBe('FILE_TOO_LARGE');
    } finally {
      await harness.close();
      await upstream.close();
    }
  }, 30_000);

  it('限额以内的 chunked 请求正常转发', async () => {
    const upstream = await startUpstream();
    const harness = await startGateway(upstream.origin);
    try {
      const { response } = chunkedPost(harness.origin, '/api/v1/auth/sessions', 512 * 1024, 'unused');
      const result = await response;
      expect(result).not.toBeNull();
      expect(result!.status).toBe(200);
    } finally {
      await harness.close();
      await upstream.close();
    }
  }, 30_000);
});
