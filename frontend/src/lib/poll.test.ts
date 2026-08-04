import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { pollUntil } from './poll'

describe('pollUntil', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('resolves immediately when the first value satisfies isDone', async () => {
    const read = vi.fn().mockResolvedValue('done')
    const result = await pollUntil(read, (value) => value === 'done')
    expect(result).toBe('done')
    expect(read).toHaveBeenCalledTimes(1)
  })

  it('invokes onValue for each polled value', async () => {
    const values = ['pending', 'pending', 'ready']
    let index = 0
    const read = vi.fn(async () => values[index++] as string)
    const onValue = vi.fn()

    const promise = pollUntil(read, (value) => value === 'ready', onValue, 10_000)
    // First read happens immediately
    await vi.advanceTimersByTimeAsync(0)
    // Second read after 1s interval
    await vi.advanceTimersByTimeAsync(1_000)
    // Third read after another 1s interval
    await vi.advanceTimersByTimeAsync(1_000)

    const result = await promise
    expect(result).toBe('ready')
    expect(onValue).toHaveBeenCalledTimes(3)
    expect(onValue).toHaveBeenNthCalledWith(1, 'pending')
    expect(onValue).toHaveBeenNthCalledWith(3, 'ready')
  })

  it('rejects with an AbortError when the signal is already aborted', async () => {
    const controller = new AbortController()
    controller.abort()
    const read = vi.fn()

    await expect(
      pollUntil(read, () => false, undefined, 1_000, controller.signal),
    ).rejects.toMatchObject({ name: 'AbortError' })

    expect(read).not.toHaveBeenCalled()
  })

  it('rejects with an AbortError when aborted during the interval', async () => {
    const controller = new AbortController()
    const read = vi.fn().mockResolvedValue('pending')

    const promise = pollUntil(read, () => false, undefined, 10_000, controller.signal)

    // First read resolves, then we wait in the interval.
    await vi.advanceTimersByTimeAsync(0)
    // Abort during the 1s interval wait.
    controller.abort()

    await expect(promise).rejects.toMatchObject({ name: 'AbortError' })
  })

  it('rejects on timeout', async () => {
    const read = vi.fn().mockResolvedValue('pending')
    const promise = pollUntil(read, () => false, undefined, 5_000)

    // Attach the rejection handler BEFORE advancing timers so the rejection
    // is never unhandled while fake timers flush the microtask queue.
    const assertion = expect(promise).rejects.toThrow('任务等待超时')
    // Advance past the deadline so the loop throws the timeout error.
    await vi.advanceTimersByTimeAsync(10_000)
    await assertion
  })
})
