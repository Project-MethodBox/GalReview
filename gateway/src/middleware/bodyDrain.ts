import type { NextFunction, Request, Response } from 'express';

/** 早期拒绝时最多排空的请求体字节数：上传整包上限（11MiB）+ 1MiB 余量 */
export const DRAIN_MAX_BYTES = 12 * 1024 * 1024;

/** 排空阶段总超时（毫秒）；超时后回落为原有的硬关闭行为 */
export const DRAIN_TIMEOUT_MS = 10_000;

export interface BodyDrainOptions {
  /** 覆盖排空字节上限（测试用） */
  maxBytes?: number;
  /** 覆盖排空超时（测试用） */
  timeoutMs?: number;
}

/** 请求是否仍有未接收完的 in-flight 请求体。
 * 注意：'request' 事件在 headers-complete 时同步派发，同步 handler 中即使
 * 无体请求 req.complete 也是 false，因此还需检查请求是否声明了体—— */
function hasUnfinishedBody(req: Request): boolean {
  const declaresBody =
    req.headers['content-length'] !== undefined
    || req.headers['transfer-encoding'] !== undefined;
  return declaresBody
    && req.complete !== true
    && !req.readableEnded
    && !req.destroyed
    && req.socket != null
    && !req.socket.destroyed;
}

function noop(): void {}

/**
 * 早期拒绝排空中间件工厂。
 *
 * Node 在响应 finish 时若请求体尚未接收完会销毁 socket（RST）；正在写体的
 * 上游代理（vite dev proxy、frontend server.mjs 等）得到 ECONNABORTED，
 * 统一错误信封被裸 5xx 替换（上传 413/401/429 竞态即由此产生）。
 * 本中间件包装 res.end：先立即冲刷响应字节（客户端第一时间拿到完整信封），
 * 再有上限、有超时地消费并丢弃剩余请求体，体完整后才真正 finish，使连接
 * 以 FIN 优雅关闭。正常代理路径 / GET / 健康检查因守卫判断为 no-op。
 */
export function createBodyDrain(options: BodyDrainOptions = {}) {
  const maxBytes = options.maxBytes ?? DRAIN_MAX_BYTES;
  const timeoutMs = options.timeoutMs ?? DRAIN_TIMEOUT_MS;

  return function bodyDrainMiddleware(req: Request, res: Response, next: NextFunction): void {
    const originalEnd = res.end.bind(res) as (...args: unknown[]) => Response;
    let intercepted = false;

    res.end = function endWithDrain(
      chunkOrCb?: unknown,
      encodingOrCb?: unknown,
      maybeCb?: unknown,
    ): Response {
      if (intercepted || !hasUnfinishedBody(req)) {
        return originalEnd(chunkOrCb, encodingOrCb, maybeCb);
      }
      intercepted = true;

      // 规范化 end 的三种重载：(cb) | (chunk, cb) | (chunk, encoding, cb)
      let chunk: string | Buffer | undefined;
      let encoding: BufferEncoding | undefined;
      let cb: (() => void) | undefined;
      if (typeof chunkOrCb === 'function') {
        cb = chunkOrCb as () => void;
      } else {
        chunk = chunkOrCb as string | Buffer | undefined;
        if (typeof encodingOrCb === 'function') {
          cb = encodingOrCb as () => void;
        } else {
          encoding = encodingOrCb as BufferEncoding | undefined;
          cb = maybeCb as (() => void) | undefined;
        }
      }

      // 立即冲刷响应：客户端无需等待排空完成即可读到完整信封（消除 RST 竞态）。
      // 关键：若头未定且缺 Content-Length，则以本 chunk 长度补齐——否则响应
      // 走 chunked 编码，客户端要等 originalEnd 的终结块才能判定完成。
      if (!res.destroyed && !res.writableEnded) {
        if (chunk != null) {
          if (!res.headersSent && !res.getHeader('content-length')
              && !res.getHeader('transfer-encoding')) {
            res.setHeader('Content-Length', Buffer.byteLength(chunk, encoding));
          }
          if (encoding) {
            res.write(chunk, encoding);
          } else {
            res.write(chunk);
          }
        } else if (!res.headersSent) {
          res.flushHeaders();
        }
      }

      let drained = 0;
      let settled = false;
      const finish = (): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        req.removeListener('data', onData);
        req.removeListener('end', finish);
        req.removeListener('close', finish);
        // 体已完整 → 连接优雅 FIN。因超上限/超时提前结束 → 响应冲刷后显式
        // 销毁 socket（明示降级）：一旦挂过 data 监听，Node 会认为请求"正在
        // 被消费"，响应结束后不再自动销毁，停滞客户端会永久占住连接。
        const graceful = req.complete === true || req.readableEnded;
        if (!graceful) {
          res.once('finish', () => {
            setImmediate(() => {
              req.socket?.destroy();
            });
          });
        }
        if (cb) {
          originalEnd(cb);
        } else {
          originalEnd();
        }
      };
      const onData = (buf: Buffer): void => {
        drained += buf.length;
        if (drained > maxBytes) finish();
      };
      const timer = setTimeout(finish, timeoutMs);
      timer.unref();

      req.on('error', noop); // 排空期客户端中止不能变成未捕获异常
      req.on('data', onData);
      req.once('end', finish);
      req.once('close', finish);
      req.resume();
      return res;
    } as typeof res.end;

    next();
  };
}
