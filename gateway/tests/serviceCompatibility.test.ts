import {
  createServer,
  type IncomingHttpHeaders,
  type Server,
  type ServerResponse,
} from 'node:http';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import request from 'supertest';
import { createApp } from '../src/app.js';
import type { GatewayConfig } from '../src/config.js';
import { listenOnTestPort } from './support/testPorts.js';

const USER_ID = '7bc4918a-9079-4ea2-9e8e-369ad79a9f20';
const MATERIAL_ID = '3a7f3d0f-1876-4879-8d6d-01a919d5c935';

interface CapturedRequest {
  method: string;
  url: string;
  headers: IncomingHttpHeaders;
  body: Buffer;
}

interface StubService {
  server: Server;
  origin: string;
  requests: CapturedRequest[];
}

describe('Gateway 与当前服务的真实代理契约', () => {
  let auth: StubService;
  let user: StubService;
  let file: StubService;
  let knowledge: StubService;
  let app: ReturnType<typeof createApp>;

  beforeAll(async () => {
    [auth, user, file, knowledge] = await Promise.all([
      startStub('auth'),
      startStub('user'),
      startStub('file'),
      startStub('knowledge'),
    ]);
    app = createApp(createConfig(auth, user, file, knowledge));
  });

  afterAll(async () => {
    await Promise.all(
      [auth, user, file, knowledge].map((stub) => closeServer(stub.server)),
    );
  });

  it('公开注册和登录应注入 AuthService 的目标密钥', async () => {
    const registration = await request(app)
      .post('/api/v1/auth/registrations')
      .set('X-Correlation-Id', 'registration-trace')
      .send({
        email: 'student@example.com',
        password: 'password-123',
        displayName: 'Student',
        invitationCode: 'MS-MOCK2026',
      });
    const login = await request(app)
      .post('/api/v1/auth/sessions')
      .send({ email: 'student@example.com', password: 'password-123' });

    expect(registration.status).toBe(201);
    expect(login.status).toBe(201);
    const forwarded = auth.requests.filter(
      (entry) => entry.url.startsWith('/api/v1/auth/'),
    );
    expect(forwarded.map((entry) => entry.url)).toEqual([
      '/api/v1/auth/registrations',
      '/api/v1/auth/sessions',
    ]);
    expect(forwarded[0]?.headers['x-gateway-key']).toBe('auth-key');
    expect(forwarded[0]?.headers.authorization).toBeUndefined();
  });

  it('用户上传应完整流式转发 multipart 并注入可信用户身份', async () => {
    const response = await request(app)
      .post('/api/v1/materials')
      .set('Authorization', 'Bearer valid-token')
      .set('X-Correlation-Id', 'upload-trace')
      .field('displayName', 'Gateway Contract')
      .field('subjectCode', 'CS')
      .attach('file', Buffer.from('Chapter 1\nProxy contract'), 'notes.txt');

    expect(response.status).toBe(201);
    const upload = file.requests.find(
      (entry) => entry.method === 'POST' && entry.url === '/api/v1/materials',
    );
    expect(upload?.headers['x-gateway-key']).toBe('file-key');
    expect(upload?.headers['x-user-id']).toBe(USER_ID);
    expect(upload?.headers.authorization).toBeUndefined();
    expect(upload?.headers['x-service-key']).toBeUndefined();
    expect(upload?.headers['content-type']).toContain('multipart/form-data; boundary=');
    expect(upload?.body.toString('utf8')).toContain('Proxy contract');
  });

  it('OCR 解析任务和查询应由 FileService 前缀路由透明转发', async () => {
    const createJob = await request(app)
      .post(`/api/v1/materials/${MATERIAL_ID}/ingestion-jobs`)
      .set('Authorization', 'Bearer valid-token')
      .send({
        parserVersion: 'files-text-v1',
        force: false,
        enableOcr: true,
        ocrMode: 'standard',
      });
    const getJob = await request(app)
      .get('/api/v1/ingestion-jobs/6fa43e7f-0383-4c60-b305-8011f4a8cab8')
      .set('Authorization', 'Bearer valid-token');

    expect(createJob.status).toBe(202);
    expect(getJob.status).toBe(200);
    const jobRequest = file.requests.find(
      (entry) => entry.url.endsWith('/ingestion-jobs') && entry.method === 'POST',
    );
    expect(JSON.parse(jobRequest!.body.toString('utf8'))).toEqual({
      parserVersion: 'files-text-v1',
      force: false,
      enableOcr: true,
      ocrMode: 'standard',
    });
    expect(jobRequest?.headers['x-user-id']).toBe(USER_ID);
  });

  it('KnowledgeService 读取纯文本和用户构图应采用各自信任边界', async () => {
    const text = await request(app)
      .get(`/internal/v1/materials/${MATERIAL_ID}/extracted-text`)
      .set('X-Service-Name', 'KnowledgeService')
      .set('X-Service-Key', 'knowledge-key')
      .set('X-Correlation-Id', 'extract-trace');
    const graph = await request(app)
      .post('/api/v1/knowledge-graph-builds')
      .set('Authorization', 'Bearer valid-token')
      .set('Idempotency-Key', '33b2bd78-155e-4dc9-8384-8e3784d6b848')
      .send({
        materialId: MATERIAL_ID,
        subjectCode: 'CS',
        segmentation: { mode: 'AUTO' },
      });

    expect(text.status).toBe(200);
    expect(graph.status).toBe(202);
    const extracted = file.requests.find(
      (entry) => entry.url.endsWith('/extracted-text'),
    );
    expect(extracted?.headers['x-gateway-key']).toBe('file-key');
    expect(extracted?.headers['x-service-name']).toBe('KnowledgeService');
    expect(extracted?.headers['x-service-key']).toBeUndefined();
    const build = knowledge.requests.find(
      (entry) => entry.url === '/api/v1/knowledge-graph-builds',
    );
    expect(build?.headers['x-gateway-key']).toBe('knowledge-key');
    expect(build?.headers['x-user-id']).toBe(USER_ID);
    expect(build?.headers['idempotency-key']).toBe(
      '33b2bd78-155e-4dc9-8384-8e3784d6b848',
    );
  });
});

function createConfig(
  auth: StubService,
  user: StubService,
  file: StubService,
  knowledge: StubService,
): GatewayConfig {
  return {
    port: 5000,
    gatewayKey: 'fallback-key',
    corsOrigins: ['http://localhost:5173'],
    defaultTimeoutMs: 5_000,
    uploadTimeoutMs: 10_000,
    readinessServices: [
      'userService',
      'authService',
      'fileService',
      'knowledgeService',
    ],
    services: {
      userService: { name: 'UserService', url: user.origin, serviceKey: 'user-key' },
      authService: { name: 'AuthService', url: auth.origin, serviceKey: 'auth-key' },
      fileService: { name: 'FileService', url: file.origin, serviceKey: 'file-key' },
      knowledgeService: {
        name: 'KnowledgeService',
        url: knowledge.origin,
        serviceKey: 'knowledge-key',
      },
      galGameService: {
        name: 'GalGameService',
        url: 'http://127.0.0.1:5255',
        serviceKey: 'galgame-key',
      },
      renderService: {
        name: 'RenderService',
        url: 'http://127.0.0.1:5256',
        serviceKey: 'render-key',
      },
      practiceService: {
        name: 'PracticeService',
        url: 'http://127.0.0.1:5257',
        serviceKey: 'practice-key',
      },
      creditService: {
        name: 'CreditService',
        url: 'http://127.0.0.1:5258',
        serviceKey: 'credit-key',
      },
    },
    rateLimit: {
      anonymous: { windowMs: 60_000, max: 100 },
      upload: { windowMs: 60_000, max: 100 },
      generation: { windowMs: 60_000, max: 100 },
      general: { windowMs: 60_000, max: 100 },
    },
  };
}

async function startStub(
  kind: 'auth' | 'user' | 'file' | 'knowledge',
): Promise<StubService> {
  const requests: CapturedRequest[] = [];
  const server = createServer((incoming, response) => {
    const chunks: Buffer[] = [];
    incoming.on('data', (chunk: Buffer) => chunks.push(chunk));
    incoming.on('end', () => {
      const captured: CapturedRequest = {
        method: incoming.method ?? 'GET',
        url: incoming.url ?? '/',
        headers: incoming.headers,
        body: Buffer.concat(chunks),
      };
      requests.push(captured);
      respondToStub(kind, captured, response);
    });
  });
  const origin = await listenOnTestPort(server);
  return { server, origin, requests };
}

function respondToStub(
  kind: 'auth' | 'user' | 'file' | 'knowledge',
  requestRecord: CapturedRequest,
  response: ServerResponse,
): void {
  if (kind === 'auth' && requestRecord.url === '/internal/v1/auth/introspections') {
    sendJson(response, 200, {
      data: {
        active: true,
        userId: USER_ID,
        sessionId: '6fa43e7f-0383-4c60-b305-8011f4a8cab8',
        scopes: ['user'],
        expiresAt: '2026-08-03T08:10:00Z',
      },
      meta: {},
      traceId: 'auth-stub-trace',
    });
    return;
  }
  if (kind === 'auth' && requestRecord.url.startsWith('/api/v1/auth/')) {
    sendJson(response, 201, { data: { accepted: true } });
    return;
  }
  if (kind === 'file' && requestRecord.url === '/api/v1/materials') {
    sendJson(response, 201, { data: { materialId: MATERIAL_ID } });
    return;
  }
  if (kind === 'file' && requestRecord.url.endsWith('/ingestion-jobs')) {
    sendJson(response, requestRecord.method === 'POST' ? 202 : 200, {
      data: { status: 'QUEUED' },
    });
    return;
  }
  if (kind === 'file' && requestRecord.url.startsWith('/api/v1/ingestion-jobs/')) {
    sendJson(response, 200, { data: { status: 'RUNNING' } });
    return;
  }
  if (kind === 'file' && requestRecord.url.endsWith('/extracted-text')) {
    sendJson(response, 200, {
      data: {
        materialId: MATERIAL_ID,
        ownerUserId: USER_ID,
        status: 'READY',
        text: 'Chapter 1\nProxy contract',
      },
    });
    return;
  }
  if (
    kind === 'knowledge' &&
    requestRecord.url === '/api/v1/knowledge-graph-builds'
  ) {
    sendJson(response, 202, { data: { status: 'QUEUED' } });
    return;
  }
  sendJson(response, 404, { error: { code: 'NOT_FOUND' } });
}

function sendJson(
  response: ServerResponse,
  status: number,
  payload: unknown,
): void {
  response.writeHead(status, { 'Content-Type': 'application/json' });
  response.end(JSON.stringify(payload));
}

async function closeServer(server: Server): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    server.close((error) => error ? reject(error) : resolve());
  });
}
