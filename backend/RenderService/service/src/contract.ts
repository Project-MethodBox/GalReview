// Shared contract types for the RenderService service layer, mirroring
// docs/contract.md §7/§8. Validation code deliberately receives `unknown`
// and narrows explicitly — the wire is untrusted regardless of these types.

export type Uuid = string

export interface ValidationIssue {
  path: string
  code: string
  message: string
}

export interface ValidationResult {
  valid: boolean
  errors: ValidationIssue[]
}

export interface DialogueLine {
  speakerId: string
  text: string
  emotion?: string
}

export interface Choice {
  choiceId: string
  questionId: Uuid
  text: string
  nextSceneId: string | null
  scoreDelta: number
  knowledgePointId: Uuid
  answerKind?: 'CHOICE' | null
  correct?: boolean | null
}

export type KnowledgePurpose = 'EXPLAIN' | 'QUESTION' | 'FEEDBACK'

export interface KnowledgeBinding {
  knowledgePointId: Uuid
  questionId: Uuid | null
  purpose: KnowledgePurpose
}

export interface Scene {
  sceneId: string
  title?: string
  dialogue: DialogueLine[]
  choices: Choice[]
  knowledgeBindings: KnowledgeBinding[]
}

export interface AssetRef {
  assetId: string
  type: 'BACKGROUND' | 'CHARACTER' | 'AUDIO' | 'OTHER'
  uri: string
}

export interface GamePackage {
  schemaVersion: '1.0'
  packageId: Uuid
  generatorVersion: string
  reviewPlanId: Uuid
  snapshotVersion: string
  entrySceneId: string
  scenes: Scene[]
  assets: AssetRef[]
}

export type ReviewSessionStatus = 'CREATED' | 'RUNNING' | 'COMPLETED' | 'ABANDONED'

export interface ReviewSession {
  sessionId: Uuid
  userId: Uuid
  packageId: Uuid
  reviewPlanId: Uuid
  snapshotVersion: string
  status: ReviewSessionStatus
  currentSceneId: string | null
  progressVersion: number
  startedAt: string | null
  completedAt: string | null
}

export interface ProgressSnapshot {
  sessionId: Uuid
  version: number
  currentSceneId: string
  visitedSceneIds: string[]
  runtimeState: Record<string, unknown>
  savedAt: string
}

export interface EventReceipt {
  accepted: number
  duplicates: number
}

export type AnswerKind = 'CHOICE' | 'FILL_BLANK' | 'TRUE_FALSE' | 'SHORT_ANSWER' | 'OTHER'

export interface KnowledgeAnswerEvidence {
  attemptId: Uuid
  questionId: Uuid
  knowledgePointId: Uuid
  answerKind: AnswerKind
  correct: boolean
  quality: number
  responseTimeMs: number
  hintsUsed: number
  attemptNumber: number
  occurredAt: string
}

export interface ReviewEvidenceSubmission {
  resultId: Uuid
  idempotencyKey: Uuid
  reviewPlanId: Uuid
  snapshotVersion: string
  sessionId: Uuid
  packageId: Uuid
  userId: Uuid
  completedAt: string
  durationSeconds: number
  answerResults: KnowledgeAnswerEvidence[]
}

export type ReviewResultStatus = 'ACCEPTED' | 'DUPLICATE'

export interface ReviewResult {
  resultId: Uuid
  sessionId: Uuid
  status: ReviewResultStatus
  submittedAt: string
}

export interface MasteryUpdateReceipt {
  resultId: Uuid
  status: ReviewResultStatus
  [key: string]: unknown
}

export interface RuntimeError {
  code: string
  message: string
  details: Record<string, unknown>
}

// RenderEvent v1 (frozen in backend/RenderService/README.md).
export interface RenderEvent {
  type: 'SCENE_ENTERED' | 'ANSWER_RECORDED' | 'SESSION_COMPLETED'
  [key: string]: unknown
}

export const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

export function isUuidV4(value: unknown): value is Uuid {
  return typeof value === 'string' && UUID_V4.test(value)
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

export function isNonEmptyString(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0
}
