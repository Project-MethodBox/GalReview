// ReviewSession server-side tests.
//
// Part 1 drives the domain service directly with a scripted fake gateway
// (upstream failure mapping, idempotency, version conflicts, evidence
// payload shape). Part 2 spawns the real server.mjs against an in-process
// stub gateway and exercises the five endpoints over HTTP, including the
// trusted-header authentication.
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import { createSessionService } from './sessions.js'
import { listenOnTestPort, spawnServerOnTestPort } from './test-ports.mjs'

const USER = '7bc4918a-9079-4ea2-9e8e-369ad79a9f20'
const OTHER_USER = '11111111-2222-4333-8444-555555555555'

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
      dialogue: [{ speakerId: 'heroine', text: '水稻分蘖期最关键的管理目标是什么？' }],
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
        {
          choiceId: 'c2',
          questionId: '6428a20a-66dd-44c9-944f-d7b36fa9c95a',
          text: '尽量提高种植密度',
          nextSceneId: null,
          scoreDelta: 0,
          knowledgePointId: 'd1adc45a-52db-4de2-9cf7-02e1ac0d53cb',
          answerKind: 'CHOICE',
          correct: false,
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

const explanationPackage = {
  ...goldenPackage,
  packageId: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
  scenes: [
    {
      sceneId: 'scene-001',
      dialogue: [{ speakerId: 'heroine', text: '这一节只讲解，不出题。' }],
      choices: [],
      knowledgeBindings: [],
    },
  ],
}

function makeAnswer(overrides = {}) {
  return {
    attemptId: '36924035-ec0a-46aa-aa7e-25b86edfa259',
    questionId: '6428a20a-66dd-44c9-944f-d7b36fa9c95a',
    knowledgePointId: 'd1adc45a-52db-4de2-9cf7-02e1ac0d53cb',
    answerKind: 'CHOICE',
    choiceId: 'c1',
    correct: true,
    quality: 5,
    scoreDelta: 1,
    responseTimeMs: 9200,
    hintsUsed: 0,
    attemptNumber: 1,
    occurredAt: '2026-08-02T09:01:40Z',
    ...overrides,
  }
}

function makeResultBody(overrides = {}) {
  return {
    expectedProgressVersion: 0,
    idempotencyKey: 'eac9acb9-b96c-43a9-a6ff-6e7dfa885b09',
    reviewPlanId: goldenPackage.reviewPlanId,
    snapshotVersion: goldenPackage.snapshotVersion,
    answerResults: [makeAnswer()],
    durationSeconds: 186,
    ...overrides,
  }
}

function fakeGateway(overrides = {}) {
  const calls = { read: [], validate: [], evidence: [] }
  return {
    calls,
    async readGamePackage(packageId, ownerUserId, correlationId) {
      calls.read.push({ packageId, ownerUserId, correlationId })
      if (overrides.read) return overrides.read(packageId, ownerUserId)
      return { ok: true, package: goldenPackage }
    },
    async validateGamePackage(pkg) {
      calls.validate.push(pkg.packageId)
      if (overrides.validate) return overrides.validate(pkg)
      return { ok: true, valid: true, errors: [] }
    },
    async submitEvidence(resultId, submission) {
      calls.evidence.push({ resultId, submission })
      if (overrides.evidence) return overrides.evidence(resultId, submission)
      return {
        ok: true,
        receipt: { resultId, status: 'ACCEPTED', updatedPointIds: [], changes: [] },
      }
    },
  }
}

async function createStarted(gateway) {
  const service = createSessionService({ gateway })
  const created = await service.create({
    userId: USER,
    body: { packageId: goldenPackage.packageId, clientRuntimeVersion: 'cpp-wasm-0.2.0' },
  })
  assert.equal(created.status, 201)
  return { service, session: created.body }
}

// ---------- Part 1: domain ----------

test('create freezes plan identity from the authoritative package', async () => {
  const gateway = fakeGateway()
  const { session } = await createStarted(gateway)
  assert.equal(session.reviewPlanId, goldenPackage.reviewPlanId)
  assert.equal(session.snapshotVersion, goldenPackage.snapshotVersion)
  assert.equal(session.status, 'CREATED')
  assert.equal(session.progressVersion, 0)
  assert.equal(session.currentSceneId, null)
  assert.equal(gateway.calls.read[0].ownerUserId, USER)
  assert.equal(gateway.calls.validate.length, 1)
})

test('create maps upstream failures to contract codes', async () => {
  const notFound = createSessionService({
    gateway: fakeGateway({ read: () => ({ ok: false, kind: 'not_found', status: 404, code: 'RESOURCE_NOT_FOUND' }) }),
  })
  let result = await notFound.create({ userId: USER, body: { packageId: goldenPackage.packageId, clientRuntimeVersion: 'x' } })
  assert.equal(result.status, 422)
  assert.equal(result.code, 'GAME_PACKAGE_NOT_FOUND')

  const broken = createSessionService({
    gateway: fakeGateway({ read: () => ({ ok: false, kind: 'contract', status: 200, code: 'UPSTREAM_CONTRACT_INVALID', message: 'x' }) }),
  })
  result = await broken.create({ userId: USER, body: { packageId: goldenPackage.packageId, clientRuntimeVersion: 'x' } })
  assert.equal(result.status, 502)

  const down = createSessionService({
    gateway: fakeGateway({ read: () => ({ ok: false, kind: 'unavailable', status: 0, code: 'SERVICE_UNAVAILABLE', message: 'x' }) }),
  })
  result = await down.create({ userId: USER, body: { packageId: goldenPackage.packageId, clientRuntimeVersion: 'x' } })
  assert.equal(result.status, 503)

  const invalidPackage = createSessionService({
    gateway: fakeGateway({ validate: () => ({ ok: true, valid: false, errors: [{ path: '$', code: 'X', message: 'x' }] }) }),
  })
  result = await invalidPackage.create({ userId: USER, body: { packageId: goldenPackage.packageId, clientRuntimeVersion: 'x' } })
  assert.equal(result.status, 502)
  assert.equal(result.code, 'UPSTREAM_CONTRACT_INVALID')
})

test('get hides sessions of other users as 404', async () => {
  const { service, session } = await createStarted(fakeGateway())
  assert.equal(service.get({ userId: USER, sessionId: session.sessionId }).status, 200)
  assert.equal(service.get({ userId: OTHER_USER, sessionId: session.sessionId }).status, 404)
})

test('progress uses optimistic concurrency with idempotent replay', async () => {
  const { service, session } = await createStarted(fakeGateway())
  const input = {
    expectedVersion: 0,
    currentSceneId: 'scene-001',
    visitedSceneIds: ['scene-001'],
    runtimeState: { schemaVersion: 'render-runtime-state-1' },
  }
  const saved = service.saveProgress({ userId: USER, sessionId: session.sessionId, body: input })
  assert.equal(saved.status, 200)
  assert.equal(saved.body.version, 1)

  const replay = service.saveProgress({ userId: USER, sessionId: session.sessionId, body: input })
  assert.equal(replay.status, 200)
  assert.equal(replay.body.version, 1, 'identical retry returns the stored snapshot')

  const conflict = service.saveProgress({
    userId: USER,
    sessionId: session.sessionId,
    body: { ...input, runtimeState: { changed: true } },
  })
  assert.equal(conflict.status, 409)
  assert.equal(conflict.code, 'VERSION_CONFLICT')

  const ghost = service.saveProgress({
    userId: USER,
    sessionId: session.sessionId,
    body: { ...input, expectedVersion: 1, currentSceneId: 'scene-ghost' },
  })
  assert.equal(ghost.status, 422)
  assert.equal(ghost.code, 'PROGRESS_SCENE_UNKNOWN')

  const after = service.get({ userId: USER, sessionId: session.sessionId }).body
  assert.equal(after.status, 'RUNNING')
  assert.ok(after.startedAt)
})

test('events deduplicate by clientEventId', async () => {
  const { service, session } = await createStarted(fakeGateway())
  const event = {
    clientEventId: 'e4b1f9d2-1234-4abc-8def-0123456789ab',
    type: 'CHOICE_SELECTED',
    occurredAt: '2026-08-02T09:00:00Z',
    payload: { sceneId: 'scene-001', choiceId: 'c1' },
  }
  const first = service.appendEvents({ userId: USER, sessionId: session.sessionId, body: { events: [event] } })
  assert.equal(first.status, 202)
  assert.deepEqual(first.body, { accepted: 1, duplicates: 0 })
  const second = service.appendEvents({ userId: USER, sessionId: session.sessionId, body: { events: [event] } })
  assert.deepEqual(second.body, { accepted: 0, duplicates: 1 })
  const invalid = service.appendEvents({ userId: USER, sessionId: session.sessionId, body: { events: [{ ...event, type: 'HACK' }] } })
  assert.equal(invalid.status, 400)
})

test('result submits evidence with frozen identity and stays idempotent', async () => {
  const gateway = fakeGateway()
  const { service, session } = await createStarted(gateway)

  const first = await service.submitResult({ userId: USER, sessionId: session.sessionId, body: makeResultBody() })
  assert.equal(first.status, 200)
  assert.equal(first.body.status, 'ACCEPTED')

  assert.equal(gateway.calls.evidence.length, 1)
  const { resultId, submission } = gateway.calls.evidence[0]
  assert.equal(first.body.resultId, resultId)
  assert.equal(submission.reviewPlanId, goldenPackage.reviewPlanId)
  assert.equal(submission.snapshotVersion, goldenPackage.snapshotVersion)
  assert.equal(submission.userId, USER)
  assert.equal(submission.packageId, goldenPackage.packageId)
  assert.equal(submission.idempotencyKey, makeResultBody().idempotencyKey)
  assert.ok(submission.completedAt)
  assert.equal(submission.answerResults.length, 1)
  assert.ok(!('scoreDelta' in submission.answerResults[0]), 'scoreDelta never reaches KnowledgeService')
  assert.ok(!('choiceId' in submission.answerResults[0]), 'choiceId stays local to Render')

  const completed = service.get({ userId: USER, sessionId: session.sessionId }).body
  assert.equal(completed.status, 'COMPLETED')
  assert.ok(completed.completedAt)

  const replay = await service.submitResult({ userId: USER, sessionId: session.sessionId, body: makeResultBody() })
  assert.equal(replay.status, 200)
  assert.equal(replay.body.status, 'DUPLICATE')
  assert.equal(replay.body.resultId, first.body.resultId)
  assert.equal(gateway.calls.evidence.length, 1, 'duplicate does not resubmit evidence')

  const mutated = await service.submitResult({
    userId: USER, sessionId: session.sessionId, body: makeResultBody({ durationSeconds: 187 }),
  })
  assert.equal(mutated.status, 409)
  assert.equal(mutated.code, 'IDEMPOTENCY_CONFLICT')

  const otherKey = await service.submitResult({
    userId: USER, sessionId: session.sessionId,
    body: makeResultBody({ idempotencyKey: '00000000-0000-4000-8000-000000000001' }),
  })
  assert.equal(otherKey.status, 409)
  assert.equal(otherKey.code, 'IDEMPOTENCY_CONFLICT')
})

test('result validates versions, identity and evidence consistency', async () => {
  const { service, session } = await createStarted(fakeGateway())

  let result = await service.submitResult({
    userId: USER, sessionId: session.sessionId, body: makeResultBody({ expectedProgressVersion: 3 }),
  })
  assert.equal(result.status, 409)
  assert.equal(result.code, 'VERSION_CONFLICT')

  result = await service.submitResult({
    userId: USER, sessionId: session.sessionId,
    body: makeResultBody({ reviewPlanId: '00000000-0000-4000-8000-000000000002' }),
  })
  assert.equal(result.code, 'RESULT_PLAN_MISMATCH')

  result = await service.submitResult({
    userId: USER, sessionId: session.sessionId, body: makeResultBody({ snapshotVersion: 'plan-graph-1.0:beef' }),
  })
  assert.equal(result.code, 'SNAPSHOT_VERSION_CONFLICT')

  result = await service.submitResult({
    userId: USER, sessionId: session.sessionId,
    body: makeResultBody({ answerResults: [makeAnswer({ correct: false, choiceId: 'c2', quality: 5 })] }),
  })
  assert.equal(result.code, 'RESULT_EVIDENCE_INVALID')

  result = await service.submitResult({
    userId: USER, sessionId: session.sessionId,
    body: makeResultBody({ answerResults: [makeAnswer({ hintsUsed: 2, quality: 5 })] }),
  })
  assert.equal(result.code, 'RESULT_EVIDENCE_INVALID')

  result = await service.submitResult({
    userId: USER, sessionId: session.sessionId,
    body: makeResultBody({ answerResults: [makeAnswer({ questionId: '99999999-9999-4999-8999-999999999999' })] }),
  })
  assert.equal(result.code, 'ANSWER_QUESTION_NOT_IN_PACKAGE')

  result = await service.submitResult({
    userId: USER, sessionId: session.sessionId,
    body: makeResultBody({ answerResults: [makeAnswer({ knowledgePointId: '99999999-9999-4999-8999-999999999999' })] }),
  })
  assert.equal(result.code, 'ANSWER_POINT_MISMATCH')

  result = await service.submitResult({
    userId: USER, sessionId: session.sessionId,
    body: makeResultBody({ answerResults: [makeAnswer({ choiceId: 'c9' })] }),
  })
  assert.equal(result.code, 'ANSWER_CHOICE_UNKNOWN')

  result = await service.submitResult({
    userId: USER, sessionId: session.sessionId,
    body: makeResultBody({ answerResults: [makeAnswer({ choiceId: 'c2' })] }),
  })
  assert.equal(result.code, 'ANSWER_CORRECT_MISMATCH')
})

test('knowledge outage keeps the session open and the resultId stable', async () => {
  let failNext = true
  const gateway = fakeGateway({
    evidence: (resultId) => {
      if (failNext) return { ok: false, kind: 'unavailable', status: 503, code: 'SERVICE_UNAVAILABLE', message: 'down' }
      return { ok: true, receipt: { resultId, status: 'ACCEPTED' } }
    },
  })
  const { service, session } = await createStarted(gateway)

  const outage = await service.submitResult({ userId: USER, sessionId: session.sessionId, body: makeResultBody() })
  assert.equal(outage.status, 503)
  assert.equal(service.get({ userId: USER, sessionId: session.sessionId }).body.status, 'CREATED')

  failNext = false
  const retry = await service.submitResult({ userId: USER, sessionId: session.sessionId, body: makeResultBody() })
  assert.equal(retry.status, 200)
  assert.equal(retry.body.status, 'ACCEPTED')
  assert.equal(gateway.calls.evidence.length, 2)
  assert.equal(gateway.calls.evidence[0].resultId, gateway.calls.evidence[1].resultId,
    'retries reuse the same resultId (§8.2.1)')
})

test('knowledge conflicts pass through their stable codes', async () => {
  const gateway = fakeGateway({
    evidence: () => ({ ok: false, kind: 'conflict', status: 409, code: 'STALE_REVIEW_EVIDENCE', message: 'older' }),
  })
  const { service, session } = await createStarted(gateway)
  const result = await service.submitResult({ userId: USER, sessionId: session.sessionId, body: makeResultBody() })
  assert.equal(result.status, 409)
  assert.equal(result.code, 'STALE_REVIEW_EVIDENCE')
})

test('explanation-only packages complete without touching mastery', async () => {
  const gateway = fakeGateway({ read: () => ({ ok: true, package: explanationPackage }) })
  const service = createSessionService({ gateway })
  const created = await service.create({
    userId: USER, body: { packageId: explanationPackage.packageId, clientRuntimeVersion: 'x' },
  })
  assert.equal(created.status, 201)

  const withAnswers = await service.submitResult({
    userId: USER, sessionId: created.body.sessionId, body: makeResultBody(),
  })
  assert.equal(withAnswers.code, 'ANSWER_QUESTION_NOT_IN_PACKAGE')

  const empty = await service.submitResult({
    userId: USER, sessionId: created.body.sessionId, body: makeResultBody({ answerResults: [] }),
  })
  assert.equal(empty.status, 200)
  assert.equal(empty.body.status, 'ACCEPTED')
  assert.equal(gateway.calls.evidence.length, 0, 'no evidence call for explanation-only packages')
  assert.equal(service.get({ userId: USER, sessionId: created.body.sessionId }).body.status, 'COMPLETED')
})

// ---------- Part 2: HTTP wire through the real server ----------

test('five endpoints work over HTTP with trusted headers', async () => {
  const serviceKey = 'render-wire-test-key'
  const seenHeaders = []
  const stub = createServer((request, response) => {
    seenHeaders.push({
      url: request.url,
      serviceName: request.headers['x-service-name'],
      serviceKey: request.headers['x-service-key'],
    })
    const respond = (body) => {
      response.writeHead(200, { 'Content-Type': 'application/json' })
      response.end(JSON.stringify({ data: body, meta: {}, traceId: 'stub' }))
    }
    if (request.method === 'GET' && request.url.startsWith('/internal/v1/game-packages/')) {
      respond(goldenPackage)
      return
    }
    if (request.method === 'POST' && request.url === '/internal/v1/game-package-validations') {
      respond({ valid: true, errors: [] })
      return
    }
    if (request.method === 'PUT' && request.url.startsWith('/internal/v1/review-evidence/')) {
      const resultId = request.url.split('/').pop()
      respond({ resultId, reviewPlanId: goldenPackage.reviewPlanId, status: 'ACCEPTED', updatedPointIds: [], changes: [], ignoredEvidenceCount: 0, algorithmVersion: 'sm2-graph-v1', processedAt: new Date().toISOString() })
      return
    }
    response.writeHead(404).end()
  })
  const stubPort = await listenOnTestPort(stub)

  const { child, base } = await spawnServerOnTestPort(
    fileURLToPath(new URL('server.mjs', import.meta.url)), {
      Gateway__BaseUrl: `http://127.0.0.1:${stubPort}`,
      Gateway__ServiceKey: serviceKey,
    })
  try {
    const authed = { 'X-Gateway-Key': serviceKey, 'X-User-Id': USER, 'Content-Type': 'application/json' }

    const ready = await (await fetch(`${base}/readyz`)).json()
    assert.equal(ready.data.reviewSessionsAvailable, true)
    assert.equal(ready.data.runtimeMode, 'FULL')
    assert.equal(ready.data.storage, 'ephemeral-memory')

    const manifest = await (await fetch(`${base}/api/v1/render-runtime/manifest`)).json()
    assert.equal(manifest.data.reviewSessionsAvailable, true)
    assert.equal(manifest.data.runtimeMode, 'FULL')

    const unauthenticated = await fetch(`${base}/api/v1/review-sessions`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}',
    })
    assert.equal(unauthenticated.status, 401)

    const badKey = await fetch(`${base}/api/v1/review-sessions`, {
      method: 'POST',
      headers: { ...authed, 'X-Gateway-Key': 'wrong' },
      body: JSON.stringify({ packageId: goldenPackage.packageId, clientRuntimeVersion: 'x' }),
    })
    assert.equal(badKey.status, 401)

    const createResponse = await fetch(`${base}/api/v1/review-sessions`, {
      method: 'POST', headers: authed,
      body: JSON.stringify({ packageId: goldenPackage.packageId, clientRuntimeVersion: 'cpp-wasm-0.2.0' }),
    })
    assert.equal(createResponse.status, 201)
    const session = (await createResponse.json()).data
    assert.equal(session.reviewPlanId, goldenPackage.reviewPlanId)

    assert.ok(seenHeaders.every((entry) => entry.serviceName === 'RenderService' && entry.serviceKey === serviceKey),
      'internal calls carry the precise service identity')

    const getResponse = await fetch(`${base}/api/v1/review-sessions/${session.sessionId}`, { headers: authed })
    assert.equal(getResponse.status, 200)

    const progressResponse = await fetch(`${base}/api/v1/review-sessions/${session.sessionId}/progress`, {
      method: 'PUT', headers: authed,
      body: JSON.stringify({
        expectedVersion: 0,
        currentSceneId: 'scene-001',
        visitedSceneIds: ['scene-001'],
        runtimeState: { schemaVersion: 'render-runtime-state-1' },
      }),
    })
    assert.equal(progressResponse.status, 200)
    const snapshot = (await progressResponse.json()).data
    assert.equal(snapshot.version, 1)

    const eventsResponse = await fetch(`${base}/api/v1/review-sessions/${session.sessionId}/events`, {
      method: 'POST', headers: authed,
      body: JSON.stringify({
        events: [{
          clientEventId: 'e4b1f9d2-1234-4abc-8def-0123456789ab',
          type: 'CHOICE_SELECTED',
          occurredAt: new Date().toISOString(),
          payload: { sceneId: 'scene-001', choiceId: 'c1' },
        }],
      }),
    })
    assert.equal(eventsResponse.status, 202)
    assert.deepEqual((await eventsResponse.json()).data, { accepted: 1, duplicates: 0 })

    const resultBody = makeResultBody({ expectedProgressVersion: 1 })
    const resultResponse = await fetch(`${base}/api/v1/review-sessions/${session.sessionId}/result`, {
      method: 'PUT', headers: authed, body: JSON.stringify(resultBody),
    })
    assert.equal(resultResponse.status, 200)
    const result = (await resultResponse.json()).data
    assert.equal(result.status, 'ACCEPTED')

    const replayResponse = await fetch(`${base}/api/v1/review-sessions/${session.sessionId}/result`, {
      method: 'PUT', headers: authed, body: JSON.stringify(resultBody),
    })
    assert.equal(replayResponse.status, 200)
    assert.equal((await replayResponse.json()).data.status, 'DUPLICATE')
  } finally {
    child.kill()
    stub.close()
  }
})
