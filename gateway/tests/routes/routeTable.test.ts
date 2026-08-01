import { describe, expect, it } from 'vitest';
import { ROUTE_TABLE } from '../../src/routes/routeTable.js';
import type { RouteEntry } from '../../src/types.js';

describe('当前服务接口路由适配', () => {
  it.each([
    ['POST', '/api/v1/materials', 'fileService', 'user'],
    ['GET', '/api/v1/materials/3a7f/extracted-text-preview', 'fileService', 'user'],
    ['POST', '/api/v1/materials/3a7f/ingestion-jobs', 'fileService', 'user'],
    ['GET', '/api/v1/ingestion-jobs/6fa4', 'fileService', 'user'],
    ['POST', '/api/v1/materials/3a7f/access-grants', 'fileService', 'user'],
    ['GET', '/internal/v1/materials/3a7f/extracted-text', 'fileService', 'service'],
    ['GET', '/internal/v1/materials/3a7f/content', 'fileService', 'service'],
    ['POST', '/api/v1/knowledge-graph-builds', 'knowledgeService', 'user'],
    ['GET', '/api/v1/knowledge-graph-builds/0957574f', 'knowledgeService', 'user'],
    ['GET', '/api/v1/knowledge-graphs/3a7f', 'knowledgeService', 'user'],
    ['POST', '/api/v1/game-generations', 'galGameService', 'user'],
    ['GET', '/api/v1/game-generations/0957574f', 'galGameService', 'user'],
    ['GET', '/api/v1/game-packages/3a7f', 'galGameService', 'user'],
    ['GET', '/api/v1/game-packages/3a7f/content', 'galGameService', 'user'],
    [
      'POST',
      '/internal/v1/game-package-validations',
      'galGameService',
      'service',
    ],
  ])(
    '%s %s 应路由到 %s 并采用 %s 身份',
    (method, path, service, auth) => {
      const route = resolveRoute(method, path);
      expect(route?.service).toBe(service);
      expect(route?.auth).toBe(auth);
    },
  );

  it('上传使用可配置的 upload 分类，解析任务不误用上传限流', () => {
    expect(resolveRoute('POST', '/api/v1/materials')?.rateLimitCategory)
      .toBe('upload');
    expect(
      resolveRoute('POST', '/api/v1/materials/3a7f/ingestion-jobs')
        ?.rateLimitCategory,
    ).toBe('general');
  });

  it('构图创建使用 generation 限流，状态轮询使用 general 限流', () => {
    expect(
      resolveRoute('POST', '/api/v1/knowledge-graph-builds')
        ?.rateLimitCategory,
    ).toBe('generation');
    expect(
      resolveRoute('GET', '/api/v1/knowledge-graph-builds/0957574f')
        ?.rateLimitCategory,
    ).toBe('general');
  });

  it('游戏创建使用 generation 限流，状态轮询和游戏包读取使用 general 限流', () => {
    expect(
      resolveRoute('POST', '/api/v1/game-generations')?.rateLimitCategory,
    ).toBe('generation');
    expect(
      resolveRoute('GET', '/api/v1/game-generations/0957574f')
        ?.rateLimitCategory,
    ).toBe('general');
    expect(
      resolveRoute('GET', '/api/v1/game-packages/3a7f')?.rateLimitCategory,
    ).toBe('general');
    expect(
      resolveRoute('GET', '/api/v1/game-packages/3a7f/content')
        ?.rateLimitCategory,
    ).toBe('general');
  });
});

function resolveRoute(method: string, path: string): RouteEntry | undefined {
  return ROUTE_TABLE.find((route) => {
    const methodMatches = !route.methods ||
      route.methods.includes(method.toUpperCase());
    if (!methodMatches) return false;

    // methods 条目由 Express 的 app[verb](path) 精确注册；app.use 条目按前缀注册。
    return route.methods ? route.path === path : isPrefix(route.path, path);
  });
}

function isPrefix(prefix: string, path: string): boolean {
  return path === prefix || path.startsWith(`${prefix}/`);
}
