/**
 * 轮询直到 isDone 返回 true、超时或被取消。
 *
 * 取消语义：
 * - signal.aborted 时立即停止轮询，reject 一个 AbortError；
 * - 正在进行的 read() 不会被强制中断（应由 read 内部通过 fetch 的 signal 处理），
 *   但下一次循环不会再发起；
 * - 等待 setTimeout 的间隔会被取消，立即 reject。
 *
 * 这样组件卸载时传入对应 AbortSignal 即可避免卸载后 setState 与请求泄漏。
 */
export async function pollUntil<T>(
  read: (signal?: AbortSignal) => Promise<T>,
  isDone: (value: T) => boolean,
  onValue?: (value: T) => void,
  timeoutMs = 240_000,
  signal?: AbortSignal,
): Promise<T> {
  if (signal?.aborted) throw new DOMException('Polling aborted before start.', 'AbortError')
  const deadline = Date.now() + timeoutMs

  // 监听外部 signal：在间隔等待阶段能立即打断。
  const onAbort = (): void => {
    // do nothing; the loop checks signal.aborted below.
  }
  signal?.addEventListener('abort', onAbort, { once: true })

  try {
    while (true) {
      if (signal?.aborted) throw new DOMException('Polling aborted.', 'AbortError')
      const value = await read(signal)
      onValue?.(value)
      if (isDone(value)) return value
      if (signal?.aborted) throw new DOMException('Polling aborted.', 'AbortError')
      if (Date.now() >= deadline) throw new Error('任务等待超时，请稍后重新查看。')
      // 在间隔等待期间也能响应取消：用可取消的 Promise 竞速。
      await new Promise<void>((resolve, reject) => {
        if (signal?.aborted) {
          reject(new DOMException('Polling aborted.', 'AbortError'))
          return
        }
        const timer = window.setTimeout(() => {
          signal?.removeEventListener('abort', onAbortInner)
          resolve()
        }, 1_000)
        const onAbortInner = (): void => {
          window.clearTimeout(timer)
          reject(new DOMException('Polling aborted.', 'AbortError'))
        }
        signal?.addEventListener('abort', onAbortInner, { once: true })
      })
    }
  } finally {
    signal?.removeEventListener('abort', onAbort)
  }
}
