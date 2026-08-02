// Stage engine pure-logic tests. The GPU path itself only runs in a real
// browser; everything deterministic (palettes, seeds, easing, typewriter,
// emotion mapping) is verified here, and the served stage.js/stage-demo
// routes are covered by the HTTP shell test in adapter.test.ts.
import assert from 'node:assert/strict'
import { test } from 'vitest'

import {
  STYLE_INDEX,
  emotionTint,
  sceneSeed,
  stylePalette,
  transitionProgress,
  typewriterVisibleChars,
} from '../src/stage.js'

test('style palettes are distinct and indexed for the shader', () => {
  const campus = stylePalette('CAMPUS')
  const fantasy = stylePalette('FANTASY')
  const science = stylePalette('SCIENCE')
  assert.notDeepEqual(campus.skyTop, fantasy.skyTop)
  assert.notDeepEqual(fantasy.skyTop, science.skyTop)
  assert.deepEqual(Object.values(STYLE_INDEX).sort(), [0, 1, 2])
  for (const palette of [campus, fantasy, science]) {
    for (const channel of [...palette.skyTop, ...palette.skyBottom, ...palette.accent]) {
      assert.ok(channel >= 0 && channel <= 1, 'channels stay normalized')
    }
  }
})

test('scene seeds are deterministic and normalized', () => {
  assert.equal(sceneSeed('scene-001'), sceneSeed('scene-001'))
  assert.notEqual(sceneSeed('scene-001'), sceneSeed('scene-002'))
  for (const id of ['scene-001', 'scene-002', '', '中文场景']) {
    const seed = sceneSeed(id)
    assert.ok(seed >= 0 && seed < 1, `seed of ${id} in [0,1)`)
  }
})

test('transition easing is clamped, monotone and smooth at the ends', () => {
  assert.equal(transitionProgress(-100, 900), 0)
  assert.equal(transitionProgress(0, 900), 0)
  assert.equal(transitionProgress(900, 900), 1)
  assert.equal(transitionProgress(5000, 900), 1)
  assert.equal(transitionProgress(100, 0), 1, 'zero duration completes immediately')
  let previous = 0
  for (let ms = 0; ms <= 900; ms += 45) {
    const value = transitionProgress(ms, 900)
    assert.ok(value >= previous, 'monotone')
    previous = value
  }
  assert.ok(transitionProgress(450, 900) > 0.45 && transitionProgress(450, 900) < 0.55)
})

test('emotion tints map known moods and fall back to neutral', () => {
  assert.notDeepEqual(emotionTint('happy'), emotionTint('sad'))
  assert.deepEqual(emotionTint('CURIOUS'), emotionTint('curious'), 'case-insensitive')
  assert.deepEqual(emotionTint('brand-new-emotion'), emotionTint(null))
  assert.deepEqual(emotionTint(undefined), emotionTint(''))
})

test('typewriter counts code points, honours speed and clamps', () => {
  assert.equal(typewriterVisibleChars('你好世界', 0), 0)
  assert.equal(typewriterVisibleChars('你好世界', 1000, 2), 2)
  assert.equal(typewriterVisibleChars('你好世界', 60_000, 2), 4, 'clamps to length')
  assert.equal(typewriterVisibleChars('emoji😀尾', 3000, 1), 3, 'surrogate pairs count once')
  assert.equal(typewriterVisibleChars('text', 100, 0), 0, 'zero speed reveals nothing')
})
