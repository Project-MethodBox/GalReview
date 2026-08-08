import { describe, expect, it } from 'vitest';
import {
  DEFAULT_BODY_LIMIT_BYTES,
  MAX_PRACTICE_PACKAGE_BYTES,
  MAX_PRACTICE_PACKAGE_REQUEST_BYTES,
  MAX_UPLOAD_REQUEST_BYTES,
  bodyLimitForRequest,
} from '../src/limits.js';

describe('请求体限额路由', () => {
  it('项目包导入允许 50 MiB 文件和 1 MiB multipart 开销', () => {
    expect(MAX_PRACTICE_PACKAGE_BYTES).toBe(50 * 1024 * 1024);
    expect(MAX_PRACTICE_PACKAGE_REQUEST_BYTES).toBe(51 * 1024 * 1024);
    expect(bodyLimitForRequest('POST', '/api/v1/practice-packages/imports')).toBe(MAX_PRACTICE_PACKAGE_REQUEST_BYTES);
  });

  it('资料上传与其他请求保持原有限额', () => {
    expect(bodyLimitForRequest('POST', '/api/v1/materials')).toBe(MAX_UPLOAD_REQUEST_BYTES);
    expect(bodyLimitForRequest('GET', '/api/v1/practice-packages/imports')).toBe(DEFAULT_BODY_LIMIT_BYTES);
    expect(bodyLimitForRequest('POST', '/api/v1/practice-projects')).toBe(DEFAULT_BODY_LIMIT_BYTES);
  });
});
