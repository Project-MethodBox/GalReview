import { Agent, createServer, request as httpRequest } from 'node:http';
import type { Server } from 'node:http';
import express from 'express';
import { describe, expect, it } from 'vitest';
import { DRAIN_MAX_BYTES, createBodyDrain } from '../../src/middleware/bodyDrain.js';
import type { BodyDrainOptions } from '../../src/middleware/bodyDrain.js';
import { MAX_UPLOAD_REQUEST_BYTES } from '../../src/app.js';
import { listenOnTestPort } from '../support/testPorts.js';

const ENVELOPE = { data: null, error: { code: 'AUTH_REQUIRED', message: '测试拒绝', details: {} }, traceId: 'trace-drain' };

interface Harness {
  server: Server;
  origin: string;
  close(): Promise<void>;
}

async function startHarness(options: BodyDrainOptions = {}): Promise<Harness> {
  const app = express();
  app.use(createBodyDrain(options));
  // 模拟"请求体仍在流入时就拒绝"的早期拒绝路径（等价于 401/413/429）
  app.post('/reject', (_req, res) => {
    res.status(401).json(ENVELOPE);
  });
  app.post('/late', (req, res) => {
    // 消费完请求体后延迟响应：验证"体已完整"时中间件为直通
    req.on('data', () => {});
    req.on('end', () => {
      setTimeout(() => res.json({ ok: true }), 50);
    });
  });
  app.get('/ok', (_req, res) => {
    res.json({ ok: true });
  });
  const server = createServer(app);
  const origin = await listenOnTestPort(server);
  return {
    server,
    origin,
    close: () => new Promise((resolve) => server.close(() => resolve())),
  };
}

interface StreamingPost {
  write(chunk: Buffer): boolean;
  end(): void;
  errors: string[];
  response: Promise<{ status: number; body: string }>;
  closed: Promise<void>;
}

function streamPost(origin: string, contentLength: number, firstChunk: Buffer, path = '/reject'): StreamingPost {
  const url = new URL(origin);
  const errors: string[] = [];
  const req = httpRequest({
    host: url.hostname,
    port: url.port,
    path,
    method: 'POST',
    headers: { 'Content-Type': 'application/octet-stream', 'Content-Length': String(contentLength) },
  });
  req.on('error', (error: NodeJS.ErrnoException) => {
    errors.push(error.code ?? error.message);
  });
  const response = new Promise<{ status: number; body: string }>((resolve) => {
    req.on('response', (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (chunk: string) => {
        body += chunk;
      });
      res.on('end', () => resolve({ status: res.statusCode ?? 0, body }));
    });
  });
  const closed = new Promise<void>((resolve) => req.on('close', () => resolve()));
  req.write(firstChunk);
  return {
    write: (chunk) => req.write(chunk),
    end: () => req.end(),
    errors,
    response,
    closed,
  };
}

const kib = (n: number): Buffer => Buffer.alloc(n * 1024, 0x61);

describe('bodyDrain 早期拒绝排空', () => {
  it('拒绝响应完整送达后排空剩余请求体，连接零错误优雅关闭', async () => {
    const harness = await startHarness();
    try {
      const post = streamPost(harness.origin, 256 * 1024, kib(32));
      const reply = await post.response;
      expect(reply.status).toBe(401);
      expect(JSON.parse(reply.body).error.code).toBe('AUTH_REQUIRED');

      // 响应已收到，但客户端仍要把剩余体写完（模拟代理转发中的 vite/前端代理）
      for (let sent = 32; sent < 256; sent += 32) {
        post.write(kib(32));
        await new Promise((resolve) => setTimeout(resolve, 5));
      }
      post.end();
      await post.closed;
      expect(post.errors).toEqual([]);
    } finally {
      await harness.close();
    }
  });

  it('排空超过 maxBytes 上限后硬关闭，但信封在此之前已完整送达', async () => {
    const harness = await startHarness({ maxBytes: 64 * 1024 });
    try {
      const post = streamPost(harness.origin, 1024 * 1024, kib(16));
      const reply = await post.response;
      expect(reply.status).toBe(401);
      expect(JSON.parse(reply.body).error.code).toBe('AUTH_REQUIRED');

      // 持续写入直至越过 64KiB 上限；服务端应确定性终止连接
      const deadline = Date.now() + 6000;
      let terminated = false;
      while (Date.now() < deadline) {
        try {
          post.write(kib(32));
        } catch {
          terminated = true;
          break;
        }
        if (post.errors.length > 0) {
          terminated = true;
          break;
        }
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      const closedInTime = await Promise.race([
        post.closed.then(() => true),
        new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 4000)),
      ]);
      // cap 生效的两种可观察形态：写入端报错，或连接关闭；二者必居其一
      expect(terminated || closedInTime).toBe(true);
      expect(closedInTime).toBe(true);
    } finally {
      await harness.close();
    }
  }, 15_000);

  it('排空超时后结束等待，信封已完整送达且连接在限时内关闭', async () => {
    const harness = await startHarness({ timeoutMs: 200 });
    try {
      const post = streamPost(harness.origin, 1024 * 1024, kib(8));
      const reply = await post.response;
      expect(reply.status).toBe(401);
      // 客户端停止写入（模拟上游断流）：中间件 200ms 后放弃等待并硬关闭；
      // 时限余量对齐慢速 CI（Node keepAliveTimeout 默认 5s 之上再留余量）
      const closedInTime = await Promise.race([
        post.closed.then(() => true),
        new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 6000)),
      ]);
      expect(closedInTime).toBe(true);
    } finally {
      await harness.close();
    }
  }, 15_000);

  it('无体 GET 保持直通且 keep-alive 连接可复用', async () => {
    const harness = await startHarness();
    const agent = new Agent({ keepAlive: true, maxSockets: 1 });
    try {
      const get = () => new Promise<{ status: number; reused: boolean }>((resolve, reject) => {
        const url = new URL(harness.origin);
        const req = httpRequest(
          { host: url.hostname, port: url.port, path: '/ok', method: 'GET', agent },
          (res) => {
            res.resume();
            res.on('end', () => resolve({ status: res.statusCode ?? 0, reused: req.reusedSocket === true }));
          },
        );
        req.on('error', reject);
        req.end();
      });
      const first = await get();
      const second = await get();
      expect(first.status).toBe(200);
      expect(second.status).toBe(200);
      expect(second.reused).toBe(true);
    } finally {
      agent.destroy();
      await harness.close();
    }
  });

  it('请求体已完整接收时为直通路径，延迟响应正常返回', async () => {
    const harness = await startHarness();
    try {
      const post = streamPost(harness.origin, 4 * 1024, kib(4), '/late');
      post.end();
      const reply = await post.response;
      expect(reply.status).toBe(200);
      expect(JSON.parse(reply.body).ok).toBe(true);
      await post.closed;
      expect(post.errors).toEqual([]);
    } finally {
      await harness.close();
    }
  });

  it('排空上限覆盖上传整包上限', () => {
    expect(DRAIN_MAX_BYTES).toBeGreaterThanOrEqual(MAX_UPLOAD_REQUEST_BYTES);
  });
});
