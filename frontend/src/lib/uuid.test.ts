import { describe, expect, it } from 'vitest'
import { createUuidV4 } from './uuid'

const UUID_V4_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

describe('createUuidV4', () => {
  it('produces a string matching the UUID v4 format', () => {
    const id = createUuidV4()
    expect(id).toMatch(UUID_V4_REGEX)
  })

  it('sets the version nibble to 4', () => {
    const id = createUuidV4()
    expect(id[14]).toBe('4')
  })

  it('sets the variant bits correctly (8, 9, a, or b)', () => {
    const id = createUuidV4()
    expect(['8', '9', 'a', 'b']).toContain(id[19].toLowerCase())
  })

  it('generates unique values across many calls', () => {
    const ids = new Set(Array.from({ length: 1000 }, () => createUuidV4()))
    expect(ids.size).toBe(1000)
  })
})
