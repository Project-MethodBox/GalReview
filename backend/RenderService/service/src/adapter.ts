// RenderService browser adapter (contract.md §8.3).
//
// Exports the frozen factory surface: createWasmAdapter() -> WasmAdapter.
// When the served runtime.wasm exports the complete RenderService
// runtime-abi v1, every call is driven by the C++ core inside the WASM
// instance. When the artifact is a placeholder (or an unsupported ABI
// version), the adapter falls back to the local JS shell behaviour so the
// SHELL-mode browser experience keeps working.
//
// This module is served to browsers as a single standalone ES module
// (dist/adapter.js): only type-only imports are allowed here — they erase
// at compile time and keep the emitted file free of runtime imports.
import type { RenderEvent, RuntimeError, ValidationIssue, ValidationResult } from './contract.js'

const DEFAULT_WASM_URL = '/api/v1/render-runtime/runtime.wasm'
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const PURPOSES = new Set(['EXPLAIN', 'QUESTION', 'FEEDBACK'])
const ASSET_TYPES = new Set(['BACKGROUND', 'CHARACTER', 'AUDIO', 'OTHER'])

// RenderService runtime-abi v1 (see backend/RenderService/README.md).
const REQUIRED_ABI_EXPORTS = [
  'memory', 'initialize', 'loadPackage', 'startSession', 'dispatchInput',
  'renderFrame', 'serializeState', 'getLastError', 'dispose',
  'rtAbiVersion', 'rtVersion', 'rtAlloc', 'rtFree',
]
const SUPPORTED_ABI_VERSIONS = new Set([1])

type UnknownRecord = Record<string, unknown>

export interface WasmAdapter {
  readonly engine: 'wasm' | 'js'
  readonly runtimeVersion: string
  readonly abiVersion: number
  initialize(config?: UnknownRecord): Promise<void>
  loadPackage(gamePackage: unknown): ValidationResult
  startSession(session: unknown): void
  dispatchInput(input: unknown): RenderEvent[]
  renderFrame(deltaMs: number): void
  serializeState(): UnknownRecord
  lastError(): RuntimeError
  dispose(): void
  readonly _wasmInstance: WebAssembly.Instance
}

export interface WasmAdapterFactoryOptions {
  wasmUrl?: string
  wasmBytes?: BufferSource
}

interface RuntimeAbiExports {
  memory: WebAssembly.Memory
  _initialize?: () => void
  initialize(pointer: number): number
  loadPackage(pointer: number): number
  startSession(pointer: number): number
  dispatchInput(pointer: number): number
  renderFrame(deltaMs: number): void
  serializeState(): number
  getLastError(): number
  dispose(): void
  rtAbiVersion(): number
  rtVersion(): number
  rtAlloc(size: number): number
  rtFree(pointer: number): void
}

function issue(path: string, code: string, message: string): ValidationIssue {
  return { path, code, message }
}

function isObject(value: unknown): value is UnknownRecord {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0
}

function isUuidV4(value: unknown): value is string {
  return typeof value === 'string' && UUID_V4.test(value)
}

interface SceneReference {
  from: string
  to: string
  path: string
}

// Reference JS implementation of the GamePackage schema 1.0 rules. The C++
// core mirrors it check-for-check; parity is enforced by the test suites on
// both sides. Kept exported for local-shell fallback and diagnostics.
export function validateGamePackage(gamePackage: unknown): ValidationResult {
  const errors: ValidationIssue[] = []
  if (!isObject(gamePackage)) {
    return { valid: false, errors: [issue('$', 'PACKAGE_REQUIRED', 'gamePackage must be an object')] }
  }
  if (gamePackage.schemaVersion !== '1.0') {
    errors.push(issue('$.schemaVersion', 'SCHEMA_UNSUPPORTED', 'only schemaVersion 1.0 is supported'))
  }
  if (!isUuidV4(gamePackage.packageId)) {
    errors.push(issue('$.packageId', 'UUID_V4_REQUIRED', 'packageId must be a lowercase UUID v4'))
  }
  if (!isNonEmptyString(gamePackage.generatorVersion)) {
    errors.push(issue('$.generatorVersion', 'FIELD_REQUIRED', 'generatorVersion is required'))
  }
  if (!isUuidV4(gamePackage.reviewPlanId)) {
    errors.push(issue('$.reviewPlanId', 'UUID_V4_REQUIRED', 'reviewPlanId must be a lowercase UUID v4'))
  }
  if (!isNonEmptyString(gamePackage.snapshotVersion)) {
    errors.push(issue('$.snapshotVersion', 'FIELD_REQUIRED', 'snapshotVersion is required'))
  }
  if (!isNonEmptyString(gamePackage.entrySceneId)) {
    errors.push(issue('$.entrySceneId', 'FIELD_REQUIRED', 'entrySceneId is required'))
  }
  const scenes: unknown[] = Array.isArray(gamePackage.scenes) ? gamePackage.scenes : []
  if (!Array.isArray(gamePackage.scenes) || scenes.length < 1 || scenes.length > 100) {
    errors.push(issue('$.scenes', 'SCENE_COUNT_OUT_OF_RANGE', 'scenes must contain 1-100 entries'))
    if (!Array.isArray(gamePackage.scenes)) return { valid: false, errors }
  }
  if (!Array.isArray(gamePackage.assets)) {
    errors.push(issue('$.assets', 'FIELD_REQUIRED', 'assets must be an array'))
  }

  const sceneIds = new Set<string>()
  const questionIds = new Set<unknown>()
  const questionSceneIds = new Set<string>()
  const nextReferences: SceneReference[] = []
  for (let index = 0; index < scenes.length; index += 1) {
    const scene = scenes[index]
    const base = `$.scenes[${index}]`
    if (!isObject(scene)) {
      errors.push(issue(base, 'SCENE_REQUIRED', 'scene must be an object'))
      continue
    }
    const sceneId = typeof scene.sceneId === 'string' ? scene.sceneId : ''
    if (!isNonEmptyString(scene.sceneId) || sceneIds.has(sceneId)) {
      errors.push(issue(`${base}.sceneId`, 'SCENE_ID_INVALID', 'sceneId must be non-empty and unique'))
    } else {
      sceneIds.add(sceneId)
    }

    if (!Array.isArray(scene.dialogue) || scene.dialogue.length < 1 || scene.dialogue.length > 200) {
      errors.push(issue(`${base}.dialogue`, 'DIALOGUE_COUNT_OUT_OF_RANGE', 'dialogue must contain 1-200 entries'))
    } else {
      scene.dialogue.forEach((line: unknown, dialogueIndex: number) => {
        if (!isObject(line) || !isNonEmptyString(line.speakerId) || !isNonEmptyString(line.text)) {
          errors.push(issue(`${base}.dialogue[${dialogueIndex}]`, 'DIALOGUE_INVALID', 'speakerId and text are required'))
        }
      })
    }

    const choices: unknown[] = Array.isArray(scene.choices) ? scene.choices : []
    if (!Array.isArray(scene.choices) || choices.length > 6) {
      errors.push(issue(`${base}.choices`, 'CHOICE_COUNT_OUT_OF_RANGE', 'choices must contain 0-6 entries'))
    }
    const choiceIds = new Set<string>()
    choices.forEach((choice: unknown, choiceIndex: number) => {
      const choicePath = `${base}.choices[${choiceIndex}]`
      if (!isObject(choice)) {
        errors.push(issue(choicePath, 'CHOICE_INVALID', 'choice must be an object'))
        return
      }
      const choiceId = typeof choice.choiceId === 'string' ? choice.choiceId : ''
      if (!isNonEmptyString(choice.choiceId) || choiceIds.has(choiceId)) {
        errors.push(issue(`${choicePath}.choiceId`, 'CHOICE_ID_INVALID', 'choiceId must be non-empty and unique in its scene'))
      } else {
        choiceIds.add(choiceId)
      }
      if (!isUuidV4(choice.questionId)) errors.push(issue(`${choicePath}.questionId`, 'UUID_V4_REQUIRED', 'questionId must be UUID v4'))
      if (!isNonEmptyString(choice.text)) errors.push(issue(`${choicePath}.text`, 'FIELD_REQUIRED', 'choice text is required'))
      if (!isUuidV4(choice.knowledgePointId)) errors.push(issue(`${choicePath}.knowledgePointId`, 'UUID_V4_REQUIRED', 'knowledgePointId must be UUID v4'))
      if (typeof choice.scoreDelta !== 'number' || !Number.isFinite(choice.scoreDelta)) {
        errors.push(issue(`${choicePath}.scoreDelta`, 'NUMBER_REQUIRED', 'scoreDelta must be a finite number'))
      }
      if (choice.nextSceneId !== null && !isNonEmptyString(choice.nextSceneId)) {
        errors.push(issue(`${choicePath}.nextSceneId`, 'SCENE_REFERENCE_INVALID', 'nextSceneId must be null or a non-empty string'))
      } else if (isNonEmptyString(choice.nextSceneId)) {
        nextReferences.push({ from: sceneId, to: choice.nextSceneId, path: `${choicePath}.nextSceneId` })
      }
    })

    const allBindings: unknown[] = Array.isArray(scene.knowledgeBindings) ? scene.knowledgeBindings : []
    if (!Array.isArray(scene.knowledgeBindings)) {
      errors.push(issue(`${base}.knowledgeBindings`, 'FIELD_REQUIRED', 'knowledgeBindings must be an array'))
    }
    allBindings.forEach((binding: unknown, bindingIndex: number) => {
      const bindingPath = `${base}.knowledgeBindings[${bindingIndex}]`
      if (!isObject(binding)) {
        errors.push(issue(bindingPath, 'BINDING_INVALID', 'knowledge binding must be an object'))
        return
      }
      if (!isUuidV4(binding.knowledgePointId)) errors.push(issue(`${bindingPath}.knowledgePointId`, 'UUID_V4_REQUIRED', 'knowledgePointId must be UUID v4'))
      if (typeof binding.purpose !== 'string' || !PURPOSES.has(binding.purpose)) {
        errors.push(issue(`${bindingPath}.purpose`, 'PURPOSE_INVALID', 'purpose is invalid'))
      }
      if (binding.questionId !== null && !isUuidV4(binding.questionId)) {
        errors.push(issue(`${bindingPath}.questionId`, 'UUID_V4_REQUIRED', 'questionId must be null or UUID v4'))
      }
      if (binding.purpose === 'QUESTION' && !isUuidV4(binding.questionId)) {
        errors.push(issue(`${bindingPath}.questionId`, 'QUESTION_ID_INVALID', 'QUESTION binding requires a UUID v4 questionId'))
      }
    })

    const bindings = allBindings.filter(
      (binding): binding is UnknownRecord => isObject(binding) && binding.purpose === 'QUESTION')
    if (bindings.length > 1) {
      errors.push(issue(`${base}.knowledgeBindings`, 'QUESTION_BINDING_COUNT', 'a scene may contain at most one QUESTION binding'))
    }
    if (bindings.length === 1) {
      const binding = bindings[0]!
      if (!isUuidV4(binding.questionId) || questionIds.has(binding.questionId)) {
        errors.push(issue(`${base}.knowledgeBindings`, 'QUESTION_ID_INVALID', 'questionId must be unique'))
      } else {
        questionIds.add(binding.questionId)
      }
      if (isNonEmptyString(scene.sceneId)) questionSceneIds.add(sceneId)
      if (choices.length === 0 || !choices.some((choice) => isObject(choice) && choice.correct === true)) {
        errors.push(issue(`${base}.choices`, 'QUESTION_CHOICES_INVALID', 'a QUESTION needs choices and at least one correct answer'))
      }
      if (choices.some((choice) => !isObject(choice)
          || choice.questionId !== binding.questionId
          || typeof choice.correct !== 'boolean'
          || choice.answerKind !== 'CHOICE'
          || choice.knowledgePointId !== binding.knowledgePointId)) {
        errors.push(issue(`${base}.choices`, 'QUESTION_BINDING_MISMATCH', 'choices must match the same-scene QUESTION binding'))
      }
    } else if (choices.some((choice) => isObject(choice)
        && (choice.answerKind != null || choice.correct != null))) {
      errors.push(issue(`${base}.choices`, 'SCORING_WITHOUT_QUESTION', 'non-QUESTION scenes cannot carry answerKind/correct'))
    }
  }

  const entrySceneId = gamePackage.entrySceneId
  if (typeof entrySceneId !== 'string' || !sceneIds.has(entrySceneId)) {
    errors.push(issue('$.entrySceneId', 'ENTRY_SCENE_INVALID', 'entrySceneId must reference a scene'))
  }
  nextReferences.forEach((reference) => {
    if (!sceneIds.has(reference.to)) {
      errors.push(issue(reference.path, 'SCENE_REFERENCE_INVALID', 'nextSceneId must reference an existing scene'))
    }
  })

  if (typeof entrySceneId === 'string' && sceneIds.has(entrySceneId)) {
    const reachable = new Set([entrySceneId])
    const pending = [entrySceneId]
    while (pending.length > 0) {
      const current = pending.shift()
      nextReferences.filter((reference) => reference.from === current && sceneIds.has(reference.to))
        .forEach((reference) => {
          if (!reachable.has(reference.to)) {
            reachable.add(reference.to)
            pending.push(reference.to)
          }
        })
    }
    questionSceneIds.forEach((sceneId) => {
      if (!reachable.has(sceneId)) {
        errors.push(issue('$.scenes', 'UNREACHABLE_QUESTION_SCENE', `QUESTION scene ${sceneId} is not reachable from entrySceneId`))
      }
    })
  }

  if (Array.isArray(gamePackage.assets)) {
    gamePackage.assets.forEach((asset: unknown, index: number) => {
      const path = `$.assets[${index}]`
      if (!isObject(asset)
          || !isNonEmptyString(asset.assetId)
          || typeof asset.type !== 'string' || !ASSET_TYPES.has(asset.type)
          || !isNonEmptyString(asset.uri)) {
        errors.push(issue(path, 'ASSET_INVALID', 'assetId, supported type and uri are required'))
      }
    })
  }
  return { valid: errors.length === 0, errors }
}

// ---------------------------------------------------------------------------

function stubImports(module: WebAssembly.Module): WebAssembly.Imports {
  // The standalone reactor imports at most a couple of notification hooks
  // (e.g. env.emscripten_notify_memory_growth). Every function import gets a
  // no-op so artifact evolution cannot break instantiation.
  const imports: Record<string, Record<string, () => number>> = {}
  for (const descriptor of WebAssembly.Module.imports(module)) {
    if (descriptor.kind === 'function') {
      imports[descriptor.module] = imports[descriptor.module] || {}
      imports[descriptor.module]![descriptor.name] = () => 0
    }
  }
  return imports
}

async function loadWasmModule(options: WasmAdapterFactoryOptions): Promise<WebAssembly.Module> {
  if (options.wasmBytes) {
    return WebAssembly.compile(options.wasmBytes)
  }
  const wasmUrl = options.wasmUrl || DEFAULT_WASM_URL
  const response = await fetch(wasmUrl, { credentials: 'same-origin' })
  if (!response.ok) throw new Error(`Unable to load RenderService WASM: HTTP ${response.status}`)
  return WebAssembly.compile(await response.arrayBuffer())
}

function runtimeErrorFrom(lastError: RuntimeError): Error {
  const error = new Error(`RenderService runtime error ${lastError.code}: ${lastError.message}`)
  ;(error as Error & { code?: string }).code = lastError.code
  return error
}

// WASM-driven adapter: all logic lives in the C++ core; this layer only
// marshals UTF-8 strings across the runtime-abi v1 memory rules.
function createNativeAdapter(instance: WebAssembly.Instance): WasmAdapter {
  const abi = instance.exports as unknown as RuntimeAbiExports
  abi._initialize?.() // WASI reactor crt bootstrap (optional export)

  const encoder = new TextEncoder()
  const decoder = new TextDecoder()
  const heap = (): Uint8Array => new Uint8Array(abi.memory.buffer) // growth-safe view

  function readCString(pointer: number): string {
    const memory = heap()
    let end = pointer
    while (memory[end] !== 0) end += 1
    return decoder.decode(memory.subarray(pointer, end))
  }

  function withCString<T>(text: string, call: (pointer: number) => T): T {
    const bytes = encoder.encode(text)
    const pointer = abi.rtAlloc(bytes.length + 1)
    try {
      const memory = heap()
      memory.set(bytes, pointer)
      memory[pointer + bytes.length] = 0
      return call(pointer)
    } finally {
      abi.rtFree(pointer)
    }
  }

  // Returned pointers are runtime-owned and only valid until the next ABI
  // call, so every string result is copied out immediately.
  const callString = (name: 'loadPackage' | 'dispatchInput', text: string): string =>
    withCString(text, (pointer) => readCString(abi[name](pointer)))
  const callStatus = (name: 'initialize' | 'startSession', text: string): number =>
    withCString(text, (pointer) => abi[name](pointer))
  const readLastError = (): RuntimeError => JSON.parse(readCString(abi.getLastError())) as RuntimeError

  let disposed = false
  const ensureActive = (): void => {
    if (disposed) throw new Error('WasmAdapter has been disposed')
  }

  return {
    engine: 'wasm',
    runtimeVersion: readCString(abi.rtVersion()),
    abiVersion: abi.rtAbiVersion(),
    async initialize(config = {}) {
      ensureActive()
      if (callStatus('initialize', JSON.stringify(config ?? {})) !== 0) {
        throw runtimeErrorFrom(readLastError())
      }
    },
    loadPackage(gamePackage) {
      ensureActive()
      return JSON.parse(callString('loadPackage', JSON.stringify(gamePackage ?? null))) as ValidationResult
    },
    startSession(session) {
      ensureActive()
      if (callStatus('startSession', JSON.stringify(session ?? null)) !== 0) {
        throw runtimeErrorFrom(readLastError())
      }
    },
    dispatchInput(input) {
      ensureActive()
      return JSON.parse(callString('dispatchInput', JSON.stringify(input ?? null))) as RenderEvent[]
    },
    renderFrame(deltaMs) {
      ensureActive()
      abi.renderFrame(Number(deltaMs) || 0)
    },
    serializeState() {
      ensureActive()
      const state = JSON.parse(readCString(abi.serializeState())) as UnknownRecord | null
      if (state === null) throw runtimeErrorFrom(readLastError())
      return state
    },
    lastError() {
      ensureActive()
      return readLastError()
    },
    dispose() {
      if (disposed) return
      abi.dispose()
      disposed = true
    },
    _wasmInstance: instance,
  }
}

// Local JS shell: preserves the pre-ABI behaviour for placeholder artifacts,
// so a deployment whose runtime.wasm lacks runtime-abi v1 still supports the
// SHELL-mode browser experience (validate + frozen local session).
function createLocalAdapter(instance: WebAssembly.Instance): WasmAdapter {
  let gamePackage: UnknownRecord | null = null
  let session: UnknownRecord | null = null
  let runtimeState: UnknownRecord | null = null
  let disposed = false

  const ensureActive = (): void => {
    if (disposed) throw new Error('WasmAdapter has been disposed')
  }

  return {
    engine: 'js',
    runtimeVersion: 'cpp-js-shell-0.1.0',
    abiVersion: 0,
    async initialize(_config = {}) {
      ensureActive()
    },
    loadPackage(value) {
      ensureActive()
      const validation = validateGamePackage(value)
      if (validation.valid) gamePackage = structuredClone(value) as UnknownRecord
      return validation
    },
    startSession(value) {
      ensureActive()
      if (!gamePackage) throw new Error('loadPackage must succeed before startSession')
      if (!isObject(value)
          || value.packageId !== gamePackage.packageId
          || value.reviewPlanId !== gamePackage.reviewPlanId
          || value.snapshotVersion !== gamePackage.snapshotVersion) {
        throw new Error('ReviewSession packageId/reviewPlanId/snapshotVersion do not match the loaded package')
      }
      session = structuredClone(value)
      runtimeState = {
        sessionId: value.sessionId,
        packageId: value.packageId,
        currentSceneId: value.currentSceneId || gamePackage.entrySceneId,
        visitedSceneIds: value.currentSceneId ? [value.currentSceneId] : [gamePackage.entrySceneId],
      }
    },
    dispatchInput(_input) {
      ensureActive()
      // The local shell keeps RuntimeInput/RenderEvent as passthrough JSON.
      return []
    },
    renderFrame(_deltaMs) {
      ensureActive()
    },
    serializeState() {
      ensureActive()
      if (!session || !runtimeState) throw new Error('startSession must be called first')
      return structuredClone(runtimeState)
    },
    lastError() {
      ensureActive()
      return { code: 'NO_ERROR', message: '', details: {} }
    },
    dispose() {
      gamePackage = null
      session = null
      runtimeState = null
      disposed = true
    },
    _wasmInstance: instance,
  }
}

export async function createWasmAdapter(options: WasmAdapterFactoryOptions = {}): Promise<WasmAdapter> {
  const module = await loadWasmModule(options)
  const exportNames = new Set(WebAssembly.Module.exports(module).map((entry) => entry.name))
  const instance = await WebAssembly.instantiate(module, stubImports(module))

  if (REQUIRED_ABI_EXPORTS.every((name) => exportNames.has(name))) {
    const abiVersion = (instance.exports as unknown as RuntimeAbiExports).rtAbiVersion()
    if (SUPPORTED_ABI_VERSIONS.has(abiVersion)) {
      return createNativeAdapter(instance)
    }
    console.warn(`RenderService WASM ABI v${abiVersion} is not supported by this adapter; falling back to the local JS shell.`)
  }
  return createLocalAdapter(instance)
}
