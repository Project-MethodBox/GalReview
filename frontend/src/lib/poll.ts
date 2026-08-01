export async function pollUntil<T>(
  read: () => Promise<T>,
  isDone: (value: T) => boolean,
  onValue?: (value: T) => void,
  timeoutMs = 240_000,
): Promise<T> {
  const deadline = Date.now() + timeoutMs
  while (true) {
    const value = await read()
    onValue?.(value)
    if (isDone(value)) return value
    if (Date.now() >= deadline) throw new Error('任务等待超时，请稍后重新查看。')
    await new Promise((resolve) => window.setTimeout(resolve, 1_000))
  }
}
