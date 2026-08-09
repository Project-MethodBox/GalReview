export async function pollUntil<T>(
  read: () => Promise<T>,
  isDone: (value: T) => boolean,
  onValue?: (value: T) => void,
  timeoutMs = 240_000,
  signal?: AbortSignal,
): Promise<T> {
  const deadline = Date.now() + timeoutMs
  while (true) {
    if (signal?.aborted) throw new DOMException('Aborted', 'AbortError')
    const value = await read()
    onValue?.(value)
    if (isDone(value)) return value
    if (Date.now() >= deadline) throw new Error('任务等待超时，请稍后重新查看。')
    await new Promise((resolve) => window.setTimeout(resolve, 1_000))
  }
}
