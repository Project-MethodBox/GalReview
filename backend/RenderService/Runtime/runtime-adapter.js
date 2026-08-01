const DEFAULT_WASM_URL = "/api/v1/render-runtime/runtime.wasm";
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const PURPOSES = new Set(["EXPLAIN", "QUESTION", "FEEDBACK"]);
const ASSET_TYPES = new Set(["BACKGROUND", "CHARACTER", "AUDIO", "OTHER"]);

function issue(path, code, message) {
  return { path, code, message };
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isNonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function isUuidV4(value) {
  return typeof value === "string" && UUID_V4.test(value);
}

export function validateGamePackage(gamePackage) {
  const errors = [];
  if (!isObject(gamePackage)) {
    return { valid: false, errors: [issue("$", "PACKAGE_REQUIRED", "gamePackage must be an object")] };
  }
  if (gamePackage.schemaVersion !== "1.0") {
    errors.push(issue("$.schemaVersion", "SCHEMA_UNSUPPORTED", "only schemaVersion 1.0 is supported"));
  }
  if (!isUuidV4(gamePackage.packageId)) {
    errors.push(issue("$.packageId", "UUID_V4_REQUIRED", "packageId must be a lowercase UUID v4"));
  }
  if (!isNonEmptyString(gamePackage.generatorVersion)) {
    errors.push(issue("$.generatorVersion", "FIELD_REQUIRED", "generatorVersion is required"));
  }
  if (!isUuidV4(gamePackage.reviewPlanId)) {
    errors.push(issue("$.reviewPlanId", "UUID_V4_REQUIRED", "reviewPlanId must be a lowercase UUID v4"));
  }
  if (!isNonEmptyString(gamePackage.snapshotVersion)) {
    errors.push(issue("$.snapshotVersion", "FIELD_REQUIRED", "snapshotVersion is required"));
  }
  if (!isNonEmptyString(gamePackage.entrySceneId)) {
    errors.push(issue("$.entrySceneId", "FIELD_REQUIRED", "entrySceneId is required"));
  }
  if (!Array.isArray(gamePackage.scenes) || gamePackage.scenes.length < 1 || gamePackage.scenes.length > 100) {
    errors.push(issue("$.scenes", "SCENE_COUNT_OUT_OF_RANGE", "scenes must contain 1-100 entries"));
    if (!Array.isArray(gamePackage.scenes)) return { valid: false, errors };
  }
  if (!Array.isArray(gamePackage.assets)) {
    errors.push(issue("$.assets", "FIELD_REQUIRED", "assets must be an array"));
  }

  const sceneIds = new Set();
  const questionIds = new Set();
  const questionSceneIds = new Set();
  const nextReferences = [];
  for (let index = 0; index < gamePackage.scenes.length; index += 1) {
    const scene = gamePackage.scenes[index];
    const base = `$.scenes[${index}]`;
    if (!isObject(scene)) {
      errors.push(issue(base, "SCENE_REQUIRED", "scene must be an object"));
      continue;
    }
    if (!isNonEmptyString(scene.sceneId) || sceneIds.has(scene.sceneId)) {
      errors.push(issue(`${base}.sceneId`, "SCENE_ID_INVALID", "sceneId must be non-empty and unique"));
    } else {
      sceneIds.add(scene.sceneId);
    }

    if (!Array.isArray(scene.dialogue) || scene.dialogue.length < 1 || scene.dialogue.length > 200) {
      errors.push(issue(`${base}.dialogue`, "DIALOGUE_COUNT_OUT_OF_RANGE", "dialogue must contain 1-200 entries"));
    } else {
      scene.dialogue.forEach((line, dialogueIndex) => {
        if (!isObject(line) || !isNonEmptyString(line.speakerId) || !isNonEmptyString(line.text)) {
          errors.push(issue(`${base}.dialogue[${dialogueIndex}]`, "DIALOGUE_INVALID", "speakerId and text are required"));
        }
      });
    }

    const choices = Array.isArray(scene.choices) ? scene.choices : [];
    if (!Array.isArray(scene.choices) || choices.length > 6) {
      errors.push(issue(`${base}.choices`, "CHOICE_COUNT_OUT_OF_RANGE", "choices must contain 0-6 entries"));
    }
    const choiceIds = new Set();
    choices.forEach((choice, choiceIndex) => {
      const choicePath = `${base}.choices[${choiceIndex}]`;
      if (!isObject(choice)) {
        errors.push(issue(choicePath, "CHOICE_INVALID", "choice must be an object"));
        return;
      }
      if (!isNonEmptyString(choice.choiceId) || choiceIds.has(choice.choiceId)) {
        errors.push(issue(`${choicePath}.choiceId`, "CHOICE_ID_INVALID", "choiceId must be non-empty and unique in its scene"));
      } else {
        choiceIds.add(choice.choiceId);
      }
      if (!isUuidV4(choice.questionId)) errors.push(issue(`${choicePath}.questionId`, "UUID_V4_REQUIRED", "questionId must be UUID v4"));
      if (!isNonEmptyString(choice.text)) errors.push(issue(`${choicePath}.text`, "FIELD_REQUIRED", "choice text is required"));
      if (!isUuidV4(choice.knowledgePointId)) errors.push(issue(`${choicePath}.knowledgePointId`, "UUID_V4_REQUIRED", "knowledgePointId must be UUID v4"));
      if (typeof choice.scoreDelta !== "number" || !Number.isFinite(choice.scoreDelta)) {
        errors.push(issue(`${choicePath}.scoreDelta`, "NUMBER_REQUIRED", "scoreDelta must be a finite number"));
      }
      if (choice.nextSceneId !== null && !isNonEmptyString(choice.nextSceneId)) {
        errors.push(issue(`${choicePath}.nextSceneId`, "SCENE_REFERENCE_INVALID", "nextSceneId must be null or a non-empty string"));
      } else if (isNonEmptyString(choice.nextSceneId)) {
        nextReferences.push({ from: scene.sceneId, to: choice.nextSceneId, path: `${choicePath}.nextSceneId` });
      }
    });

    const allBindings = Array.isArray(scene.knowledgeBindings) ? scene.knowledgeBindings : [];
    if (!Array.isArray(scene.knowledgeBindings)) {
      errors.push(issue(`${base}.knowledgeBindings`, "FIELD_REQUIRED", "knowledgeBindings must be an array"));
    }
    allBindings.forEach((binding, bindingIndex) => {
      const bindingPath = `${base}.knowledgeBindings[${bindingIndex}]`;
      if (!isObject(binding)) {
        errors.push(issue(bindingPath, "BINDING_INVALID", "knowledge binding must be an object"));
        return;
      }
      if (!isUuidV4(binding.knowledgePointId)) errors.push(issue(`${bindingPath}.knowledgePointId`, "UUID_V4_REQUIRED", "knowledgePointId must be UUID v4"));
      if (!PURPOSES.has(binding.purpose)) errors.push(issue(`${bindingPath}.purpose`, "PURPOSE_INVALID", "purpose is invalid"));
      if (binding.questionId !== null && !isUuidV4(binding.questionId)) {
        errors.push(issue(`${bindingPath}.questionId`, "UUID_V4_REQUIRED", "questionId must be null or UUID v4"));
      }
      if (binding.purpose === "QUESTION" && !isUuidV4(binding.questionId)) {
        errors.push(issue(`${bindingPath}.questionId`, "QUESTION_ID_INVALID", "QUESTION binding requires a UUID v4 questionId"));
      }
    });

    const bindings = allBindings.filter((binding) => isObject(binding) && binding.purpose === "QUESTION");
    if (bindings.length > 1) {
      errors.push(issue(`${base}.knowledgeBindings`, "QUESTION_BINDING_COUNT", "a scene may contain at most one QUESTION binding"));
    }
    if (bindings.length === 1) {
      const binding = bindings[0];
      if (!isUuidV4(binding.questionId) || questionIds.has(binding.questionId)) {
        errors.push(issue(`${base}.knowledgeBindings`, "QUESTION_ID_INVALID", "questionId must be unique"));
      } else {
        questionIds.add(binding.questionId);
      }
      if (isNonEmptyString(scene.sceneId)) questionSceneIds.add(scene.sceneId);
      if (choices.length === 0 || !choices.some((choice) => isObject(choice) && choice.correct === true)) {
        errors.push(issue(`${base}.choices`, "QUESTION_CHOICES_INVALID", "a QUESTION needs choices and at least one correct answer"));
      }
      if (choices.some((choice) => !isObject(choice)
          || choice.questionId !== binding.questionId
          || typeof choice.correct !== "boolean"
          || choice.answerKind !== "CHOICE"
          || choice.knowledgePointId !== binding.knowledgePointId)) {
        errors.push(issue(`${base}.choices`, "QUESTION_BINDING_MISMATCH", "choices must match the same-scene QUESTION binding"));
      }
    } else if (choices.some((choice) => isObject(choice)
        && (choice.answerKind != null || choice.correct != null))) {
      errors.push(issue(`${base}.choices`, "SCORING_WITHOUT_QUESTION", "non-QUESTION scenes cannot carry answerKind/correct"));
    }
  }

  if (!sceneIds.has(gamePackage.entrySceneId)) {
    errors.push(issue("$.entrySceneId", "ENTRY_SCENE_INVALID", "entrySceneId must reference a scene"));
  }
  nextReferences.forEach((reference) => {
    if (!sceneIds.has(reference.to)) {
      errors.push(issue(reference.path, "SCENE_REFERENCE_INVALID", "nextSceneId must reference an existing scene"));
    }
  });

  if (sceneIds.has(gamePackage.entrySceneId)) {
    const reachable = new Set([gamePackage.entrySceneId]);
    const pending = [gamePackage.entrySceneId];
    while (pending.length > 0) {
      const current = pending.shift();
      nextReferences.filter((reference) => reference.from === current && sceneIds.has(reference.to))
        .forEach((reference) => {
          if (!reachable.has(reference.to)) {
            reachable.add(reference.to);
            pending.push(reference.to);
          }
        });
    }
    questionSceneIds.forEach((sceneId) => {
      if (!reachable.has(sceneId)) {
        errors.push(issue("$.scenes", "UNREACHABLE_QUESTION_SCENE", `QUESTION scene ${sceneId} is not reachable from entrySceneId`));
      }
    });
  }

  if (Array.isArray(gamePackage.assets)) {
    gamePackage.assets.forEach((asset, index) => {
      const path = `$.assets[${index}]`;
      if (!isObject(asset)
          || !isNonEmptyString(asset.assetId)
          || !ASSET_TYPES.has(asset.type)
          || !isNonEmptyString(asset.uri)) {
        errors.push(issue(path, "ASSET_INVALID", "assetId, supported type and uri are required"));
      }
    });
  }
  return { valid: errors.length === 0, errors };
}

async function instantiateWasm(url) {
  const response = await fetch(url, { credentials: "same-origin" });
  if (!response.ok) throw new Error(`Unable to load RenderService WASM: HTTP ${response.status}`);
  const bytes = await response.arrayBuffer();
  return WebAssembly.instantiate(bytes, {});
}

export async function createWasmAdapter(options = {}) {
  const wasmUrl = options.wasmUrl || DEFAULT_WASM_URL;
  const wasm = await instantiateWasm(wasmUrl);
  let gamePackage = null;
  let session = null;
  let runtimeState = null;
  let disposed = false;

  const ensureActive = () => {
    if (disposed) throw new Error("WasmAdapter has been disposed");
  };

  return {
    async initialize(_config = {}) {
      ensureActive();
    },
    loadPackage(value) {
      ensureActive();
      const validation = validateGamePackage(value);
      if (validation.valid) gamePackage = structuredClone(value);
      return validation;
    },
    startSession(value) {
      ensureActive();
      if (!gamePackage) throw new Error("loadPackage must succeed before startSession");
      if (!isObject(value)
          || value.packageId !== gamePackage.packageId
          || value.reviewPlanId !== gamePackage.reviewPlanId
          || value.snapshotVersion !== gamePackage.snapshotVersion) {
        throw new Error("ReviewSession packageId/reviewPlanId/snapshotVersion do not match the loaded package");
      }
      session = structuredClone(value);
      runtimeState = {
        sessionId: value.sessionId,
        packageId: value.packageId,
        currentSceneId: value.currentSceneId || gamePackage.entrySceneId,
        visitedSceneIds: value.currentSceneId ? [value.currentSceneId] : [gamePackage.entrySceneId]
      };
    },
    dispatchInput(_input) {
      ensureActive();
      // RuntimeInput / RenderEvent are still OWNER-TBD in contract.md §8.3.
      return [];
    },
    renderFrame(_deltaMs) {
      ensureActive();
    },
    serializeState() {
      ensureActive();
      if (!session || !runtimeState) throw new Error("startSession must be called first");
      return structuredClone(runtimeState);
    },
    dispose() {
      gamePackage = null;
      session = null;
      runtimeState = null;
      disposed = true;
    },
    // Kept private-by-convention for diagnostics; the module is intentionally not
    // advertised as the complete C++ ABI until contract.md §8.5 is resolved.
    _wasmInstance: wasm.instance
  };
}
