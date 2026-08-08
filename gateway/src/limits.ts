/**
 * 请求体大小上限。集中定义，供 Content-Length 早拒（app.ts）与
 * chunked 流式计数（proxy/createProxy.ts）共用同一阈值。
 */

/** 默认请求体大小上限（10MB） */
export const DEFAULT_BODY_LIMIT_BYTES = 10 * 1024 * 1024;
/** FileService 对文件本体执行的严格上限（10 MiB） */
export const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;
/** multipart 边界、字段和头部可占用的有限开销（1 MiB） */
export const MULTIPART_OVERHEAD_BYTES = 1 * 1024 * 1024;
/** Gateway 可接受的整个 multipart 请求上限；文件本体仍由 FileService 校验 */
export const MAX_UPLOAD_REQUEST_BYTES =
  MAX_UPLOAD_BYTES + MULTIPART_OVERHEAD_BYTES;
/** PracticeService 项目包文件上限（50 MiB） */
export const MAX_PRACTICE_PACKAGE_BYTES = 50 * 1024 * 1024;
/** 项目包 multipart 请求上限 */
export const MAX_PRACTICE_PACKAGE_REQUEST_BYTES =
  MAX_PRACTICE_PACKAGE_BYTES + MULTIPART_OVERHEAD_BYTES;

/** 上传路由的整包上限，其余路由用默认上限 */
export function bodyLimitForRequest(method: string, path: string): number {
  const pathname = path.split('?', 1)[0];
  const isUpload = pathname === '/api/v1/materials' && method === 'POST';
  const isPracticePackageUpload = pathname === '/api/v1/practice-packages/imports' && method === 'POST';
  if (isPracticePackageUpload) return MAX_PRACTICE_PACKAGE_REQUEST_BYTES;
  return isUpload ? MAX_UPLOAD_REQUEST_BYTES : DEFAULT_BODY_LIMIT_BYTES;
}
