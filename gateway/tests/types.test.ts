import { describe, it, expect } from 'vitest';
import { buildApiSuccess, buildApiFailure, getTraceId } from '../src/types.js';
import type { Request } from 'express';

describe('buildApiSuccess', () => {
  it('应构建统一成功响应格式', () => {
    const result = buildApiSuccess({ id: '123' }, 'trace-1');
    expect(result).toEqual({
      data: { id: '123' },
      meta: {},
      traceId: 'trace-1',
    });
  });

  it('应支持 null data', () => {
    const result = buildApiSuccess(null, 'trace-2');
    expect(result.data).toBeNull();
    expect(result.meta).toEqual({});
  });

  it('应支持数组 data', () => {
    const result = buildApiSuccess([1, 2, 3], 'trace-3');
    expect(result.data).toEqual([1, 2, 3]);
  });
});

describe('buildApiFailure', () => {
  it('应构建统一失败响应格式', () => {
    const result = buildApiFailure('VALIDATION_ERROR', '参数错误', 'trace-4');
    expect(result).toEqual({
      data: null,
      error: {
        code: 'VALIDATION_ERROR',
        message: '参数错误',
        details: {},
      },
      traceId: 'trace-4',
    });
  });

  it('应包含自定义 details', () => {
    const result = buildApiFailure(
      'FILE_TOO_LARGE',
      '文件过大',
      'trace-5',
      { maxSize: 10485760, actual: 20971520 },
    );
    expect(result.error.details).toEqual({ maxSize: 10485760, actual: 20971520 });
  });

  it('details 默认应为空对象', () => {
    const result = buildApiFailure('NOT_FOUND', '未找到', 'trace-6');
    expect(result.error.details).toEqual({});
  });
});

describe('getTraceId', () => {
  function createMockReq(overrides: Partial<Request> = {}): Request {
    return {
      traceId: undefined,
      headers: {},
      ...overrides,
    } as unknown as Request;
  }

  it('应优先返回 req.traceId', () => {
    const req = createMockReq({ traceId: 'my-trace' });
    expect(getTraceId(req)).toBe('my-trace');
  });

  it('应回退到 X-Correlation-Id 头', () => {
    const req = createMockReq({ headers: { 'x-correlation-id': 'header-trace' } });
    expect(getTraceId(req)).toBe('header-trace');
  });

  it('应优先使用 req.traceId 即使有 X-Correlation-Id', () => {
    const req = createMockReq({
      traceId: 'req-trace',
      headers: { 'x-correlation-id': 'header-trace' },
    });
    expect(getTraceId(req)).toBe('req-trace');
  });

  it('两值均缺时返回 unknown', () => {
    const req = createMockReq();
    expect(getTraceId(req)).toBe('unknown');
  });
});
