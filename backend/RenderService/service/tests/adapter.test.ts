// Adapter tests: dual path (WASM-driven / local JS shell), JS<->C++ validator
// parity on the repo's real mock packages, and an HTTP smoke test of the
// shell server. Requires a build first (`npm test` runs it via pretest).
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { existsSync } from 'node:fs'
import { readFile, readdir } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { test } from 'vitest'

import { createWasmAdapter, validateGamePackage } from '../src/adapter.js'
import { spawnServerOnTestPort } from './support/testPorts.js'

const testsDirectory = new URL('./', import.meta.url)
const wasmBytes = Buffer.from(
  (await readFile(new URL('../runtime.wasm.base64', testsDirectory), 'utf8')).trim(),
  'base64',
)
const placeholderWasm = Buffer.from('AGFzbQEAAAA=', 'base64')

const goldenPackage = {
  schemaVersion: '1.0',
  packageId: 'f2561bb2-b88c-47ef-b0ae-8f283ff64f1b',
  generatorVersion: 'gala-0.1.0',
  reviewPlanId: '8e812950-3311-40a7-93ab-636409df8cc2',
  snapshotVersion: 'plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620',
  entrySceneId: 'scene-001',
  scenes: [
    {
      sceneId: 'scene-001',
      dialogue: [{ speakerId: 'heroine', text: '水稻分蘖期最关键的管理目标是什么？', emotion: 'curious' }],
      choices: [
        {
          choiceId: 'c1',
          questionId: '6428a20a-66dd-44c9-944f-d7b36fa9c95a',
          text: '协调群体数量与个体生长',
          nextSceneId: null,
          scoreDelta: 1,
          knowledgePointId: 'd1adc45a-52db-4de2-9cf7-02e1ac0d53cb',
          answerKind: 'CHOICE',
          correct: true,
        },
      ],
      knowledgeBindings: [
        {
          knowledgePointId: 'd1adc45a-52db-4de2-9cf7-02e1ac0d53cb',
          questionId: '6428a20a-66dd-44c9-944f-d7b36fa9c95a',
          purpose: 'QUESTION',
        },
      ],
    },
  ],
  assets: [],
}

const goldenSession = {
  sessionId: 'bc98017d-cf5f-44fc-ac09-9604a2a0248b',
  userId: '7bc4918a-9079-4ea2-9e8e-369ad79a9f20',
  packageId: goldenPackage.packageId,
  reviewPlanId: goldenPackage.reviewPlanId,
  snapshotVersion: goldenPackage.snapshotVersion,
  status: 'CREATED',
  currentSceneId: null,
  progressVersion: 0,
  startedAt: null,
  completedAt: null,
}

function issueKeys(result: { errors: Array<{ path: string; code: string }> }): string[] {
  return result.errors.map((entry) => `${entry.path}|${entry.code}`).sort()
}

test('JS validator accepts the golden package', () => {
  const result = validateGamePackage(goldenPackage)
  assert.equal(result.valid, true)
  assert.deepEqual(result.errors, [])
})

test('JS validator rejects a broken package with stable codes', () => {
  const broken = structuredClone(goldenPackage) as Record<string, unknown>
  broken.schemaVersion = '2.0'
  broken.entrySceneId = 'scene-ghost'
  const result = validateGamePackage(broken)
  assert.equal(result.valid, false)
  const codes = result.errors.map((entry) => entry.code)
  assert.ok(codes.includes('SCHEMA_UNSUPPORTED'))
  assert.ok(codes.includes('ENTRY_SCENE_INVALID'))
})

test('WASM adapter drives a full session through the C++ core', async () => {
  const adapter = await createWasmAdapter({ wasmBytes })
  assert.equal(adapter.engine, 'wasm')
  assert.equal(adapter.abiVersion, 1)
  assert.equal(adapter.runtimeVersion, 'cpp-wasm-0.2.0')

  await adapter.initialize({})
  const validation = adapter.loadPackage(goldenPackage)
  assert.equal(validation.valid, true)

  adapter.startSession(goldenSession)
  adapter.renderFrame(16.5)
  adapter.renderFrame(16.5)

  const events = adapter.dispatchInput({ type: 'CHOICE_SELECTED', choiceId: 'c1' })
  assert.equal(events.length, 2)
  assert.equal(events[0]!.type, 'ANSWER_RECORDED')
  assert.equal(events[0]!.correct, true)
  assert.equal(events[0]!.attemptNumber, 1)
  assert.equal(events[1]!.type, 'SESSION_COMPLETED')
  assert.equal(events[1]!.answeredQuestionCount, 1)

  const state = adapter.serializeState()
  assert.equal(state.schemaVersion, 'render-runtime-state-1')
  assert.equal(state.status, 'COMPLETED')
  assert.equal(state.score, 1)
  assert.equal(state.elapsedMs, 33)
  const answers = state.answers as Array<Record<string, unknown>>
  assert.equal(answers.length, 1)
  assert.equal(answers[0]!.answerKind, 'CHOICE')

  const rejected = adapter.dispatchInput({ type: 'ADVANCE' })
  assert.deepEqual(rejected, [])
  assert.equal(adapter.lastError().code, 'SESSION_ALREADY_COMPLETED')

  adapter.dispose()
  assert.throws(() => adapter.serializeState(), /disposed/)
})

test('WASM startSession enforces the frozen package identity', async () => {
  const adapter = await createWasmAdapter({ wasmBytes })
  await adapter.initialize()
  adapter.loadPackage(goldenPackage)
  const mismatched = { ...goldenSession, snapshotVersion: 'plan-graph-1.0:deadbeef' }
  assert.throws(() => adapter.startSession(mismatched), /SESSION_PACKAGE_MISMATCH/)
  adapter.dispose()
})

test('WASM and JS validators agree on the repo mock packages', async (ctx) => {
  const mocksDirectory = new URL('../../../GalGameService/mocks/', testsDirectory)
  if (!existsSync(mocksDirectory)) {
    ctx.skip()
    return
  }
  const adapter = await createWasmAdapter({ wasmBytes })
  await adapter.initialize()
  let compared = 0
  for (const name of await readdir(mocksDirectory)) {
    if (!name.endsWith('.json')) continue
    let parsed: unknown
    try {
      parsed = JSON.parse(await readFile(new URL(name, mocksDirectory), 'utf8'))
    } catch {
      continue
    }
    if (parsed === null || typeof parsed !== 'object' || !('scenes' in parsed)) continue
    const jsResult = validateGamePackage(parsed)
    const wasmResult = adapter.loadPackage(parsed)
    assert.equal(wasmResult.valid, jsResult.valid, `${name}: valid flag parity`)
    assert.deepEqual(issueKeys(wasmResult), issueKeys(jsResult), `${name}: issue parity`)
    compared += 1
  }
  adapter.dispose()
  assert.ok(compared >= 4, `expected to compare at least 4 packages, got ${compared}`)
})

test('placeholder wasm falls back to the local JS shell', async () => {
  const adapter = await createWasmAdapter({ wasmBytes: placeholderWasm })
  assert.equal(adapter.engine, 'js')
  await adapter.initialize()

  assert.throws(() => adapter.startSession(goldenSession), /loadPackage must succeed/)
  const validation = adapter.loadPackage(goldenPackage)
  assert.equal(validation.valid, true)
  assert.throws(
    () => adapter.startSession({ ...goldenSession, packageId: '00000000-0000-4000-8000-000000000000' }),
    /do not match/,
  )
  adapter.startSession(goldenSession)
  const state = adapter.serializeState()
  assert.equal(state.currentSceneId, 'scene-001')
  assert.deepEqual(state.visitedSceneIds, ['scene-001'])
  assert.deepEqual(adapter.dispatchInput({ type: 'CHOICE_SELECTED', choiceId: 'c1' }), [])
  adapter.dispose()
  assert.throws(() => adapter.serializeState(), /disposed/)
})

test('HTTP shell serves runtime resources and honest 501s', async () => {
  const { child, base } = await spawnServerOnTestPort(
    fileURLToPath(new URL('../dist/server.js', testsDirectory)))
  try {
    const health = await (await fetch(`${base}/healthz`)).json()
    assert.equal(health.data.status, 'live')

    const ready = await (await fetch(`${base}/readyz`)).json()
    assert.equal(ready.data.runtimeMode, 'SHELL')
    assert.equal(ready.data.reviewSessionsAvailable, false)
    assert.equal(ready.data.wasmAbiComplete, true)
    assert.equal(ready.data.executionEngine, 'cpp-wasm-shell')

    const manifestResponse = await fetch(`${base}/api/v1/render-runtime/manifest`, {
      headers: { 'X-Correlation-Id': 'trace-render-test' },
    })
    const manifest = (await manifestResponse.json()).data
    assert.equal(manifestResponse.headers.get('x-correlation-id'), 'trace-render-test')
    assert.equal(manifest.wasmVersion, 'cpp-wasm-0.2.0')
    assert.equal(manifest.wasmAbiComplete, true)
    assert.deepEqual(manifest.supportedSchemaVersions, ['1.0'])

    const wasmResponse = await fetch(`${base}${manifest.wasmUrl}`)
    assert.equal(wasmResponse.headers.get('content-type'), 'application/wasm')
    const served = Buffer.from(await wasmResponse.arrayBuffer())
    assert.equal(createHash('sha256').update(served).digest('hex'), manifest.checksum)

    const adapterResponse = await fetch(`${base}${manifest.jsAdapterUrl}`)
    assert.match(adapterResponse.headers.get('content-type') ?? '', /application\/javascript/)
    assert.match(await adapterResponse.text(), /async function createWasmAdapter/)

    const notImplemented = await fetch(`${base}/api/v1/review-sessions`, { method: 'POST' })
    assert.equal(notImplemented.status, 501)
    assert.equal((await notImplemented.json()).error.code, 'RENDER_SESSION_NOT_IMPLEMENTED')

    const missing = await fetch(`${base}/api/v1/unknown`)
    assert.equal(missing.status, 404)
    assert.equal((await missing.json()).error.code, 'RESOURCE_NOT_FOUND')
  } finally {
    child.kill()
  }
})
