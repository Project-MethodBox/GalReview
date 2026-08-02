import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const adapterSource = readFileSync(new URL("./runtime-adapter.js", import.meta.url), "utf8");
const { createWasmAdapter, validateGamePackage } = await import(
  `data:text/javascript;base64,${Buffer.from(adapterSource).toString("base64")}`
);

const ids = {
  package: "11111111-1111-4111-8111-111111111111",
  plan: "22222222-2222-4222-8222-222222222222",
  question: "33333333-3333-4333-8333-333333333333",
  point: "44444444-4444-4444-8444-444444444444",
  session: "55555555-5555-4555-8555-555555555555",
  user: "66666666-6666-4666-8666-666666666666"
};

function validPackage() {
  return {
    schemaVersion: "1.0",
    packageId: ids.package,
    generatorVersion: "test",
    reviewPlanId: ids.plan,
    snapshotVersion: "plan-graph-1.0:test",
    entrySceneId: "scene-1",
    scenes: [{
      sceneId: "scene-1",
      title: null,
      dialogue: [{ speakerId: "narrator", text: "question", emotion: null }],
      choices: [{
        choiceId: "c1",
        questionId: ids.question,
        text: "answer",
        nextSceneId: null,
        scoreDelta: 1,
        knowledgePointId: ids.point,
        answerKind: "CHOICE",
        correct: true
      }],
      knowledgeBindings: [{
        knowledgePointId: ids.point,
        questionId: ids.question,
        purpose: "QUESTION"
      }]
    }],
    assets: []
  };
}

test("accepts the frozen minimal schema", () => {
  assert.deepEqual(validateGamePackage(validPackage()), { valid: true, errors: [] });
});

test("enforces scene count and UUID v4", () => {
  const value = validPackage();
  value.packageId = "not-a-uuid";
  value.scenes = Array.from({ length: 101 }, (_, index) => ({
    ...structuredClone(value.scenes[0]),
    sceneId: `scene-${index}`
  }));
  const result = validateGamePackage(value);
  assert.equal(result.valid, false);
  assert(result.errors.some((error) => error.code === "SCENE_COUNT_OUT_OF_RANGE"));
  assert(result.errors.some((error) => error.path === "$.packageId"));
});

test("rejects missing scene references", () => {
  const value = validPackage();
  value.scenes[0].choices[0].nextSceneId = "missing-scene";
  const result = validateGamePackage(value);
  assert(result.errors.some((error) => error.code === "SCENE_REFERENCE_INVALID"));
});

test("rejects a QUESTION scene unreachable from entrySceneId", () => {
  const value = validPackage();
  value.scenes[0].knowledgeBindings[0].purpose = "EXPLAIN";
  value.scenes[0].choices[0].answerKind = null;
  value.scenes[0].choices[0].correct = null;
  const second = structuredClone(validPackage().scenes[0]);
  second.sceneId = "scene-2";
  value.scenes.push(second);
  const result = validateGamePackage(value);
  assert(result.errors.some((error) => error.code === "UNREACHABLE_QUESTION_SCENE"));
});

test("requires package arrays and dialogue fields", () => {
  const value = validPackage();
  delete value.assets;
  value.scenes[0].dialogue[0].text = "";
  const result = validateGamePackage(value);
  assert(result.errors.some((error) => error.path === "$.assets"));
  assert(result.errors.some((error) => error.code === "DIALOGUE_INVALID"));
});

test("startSession freezes package, plan and snapshot together", async () => {
  const wasm = Buffer.from("AGFzbQEAAAA=", "base64");
  globalThis.fetch = async () => ({
    ok: true,
    arrayBuffer: async () => wasm.buffer.slice(wasm.byteOffset, wasm.byteOffset + wasm.byteLength)
  });
  const adapter = await createWasmAdapter({ wasmUrl: "https://runtime.test/runtime.wasm" });
  const gamePackage = validPackage();
  assert.equal(adapter.loadPackage(gamePackage).valid, true);
  const session = {
    sessionId: ids.session,
    userId: ids.user,
    packageId: gamePackage.packageId,
    reviewPlanId: gamePackage.reviewPlanId,
    snapshotVersion: gamePackage.snapshotVersion,
    status: "CREATED",
    currentSceneId: null,
    progressVersion: 0,
    startedAt: null,
    completedAt: null
  };

  assert.throws(() => adapter.startSession({ ...session, reviewPlanId: ids.user }), /do not match/);
  assert.throws(() => adapter.startSession({ ...session, snapshotVersion: "changed" }), /do not match/);
  adapter.startSession(session);
  assert.equal(adapter.serializeState().currentSceneId, gamePackage.entrySceneId);
});
