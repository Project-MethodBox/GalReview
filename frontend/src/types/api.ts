export type Uuid = string
export type DateTime = string
export type JobStatus = 'QUEUED' | 'RUNNING' | 'SUCCEEDED' | 'FAILED'

export interface ApiSuccess<T> {
  data: T
  meta: Record<string, unknown>
  traceId: string
}

export interface ApiErrorDetail {
  code: string
  message: string
  details: Record<string, unknown>
}

export interface ApiFailure {
  data: null
  error: ApiErrorDetail
  traceId: string
}

export interface AuthSession {
  sessionId: Uuid
  userId: Uuid
  status: 'ACTIVE' | 'REVOKED' | 'EXPIRED'
  createdAt: DateTime
  expiresAt: DateTime
}

export interface TokenPair {
  accessToken: string
  refreshToken: string
  tokenType: 'Bearer'
  expiresInSeconds: number
}

export interface AuthSessionResponse {
  session: AuthSession
  tokens: TokenPair
}

export interface UserProfile {
  userId: Uuid
  displayName: string
  avatarUrl: string | null
  locale: string
  preferredSubjectCodes: string[]
  createdAt: DateTime
  updatedAt: DateTime
}

export type ContentDifficulty = 'BASIC' | 'STANDARD' | 'ADVANCED'

export interface UserPreferencesInput {
  dailyGoalMinutes: number
  contentDifficulty: ContentDifficulty
  reducedMotion: boolean
}

export interface UserPreferences extends UserPreferencesInput {
  updatedAt: DateTime
}

export type MaterialStatus = 'UPLOADED' | 'PROCESSING' | 'READY' | 'FAILED' | 'DELETED'

export interface Material {
  materialId: Uuid
  ownerUserId: Uuid
  displayName: string
  originalFileName: string
  mediaType: string
  sizeBytes: number
  checksum: string
  status: MaterialStatus
  latestIngestionJobId: Uuid | null
  ocrUsed: boolean
  createdAt: DateTime
  updatedAt: DateTime
}

export interface MaterialPage {
  items: Material[]
  nextCursor: string | null
}

export interface TextSourceSpan {
  startOffset: number
  endOffset: number
  pageNumber: number | null
  paragraphIndex: number | null
  sourceLabel: string | null
}

export interface TextDocumentBlock {
  kind: string
  level: number | null
  text: string
  source: TextSourceSpan
}

export interface ExtractedTextDocument {
  materialId: Uuid
  ownerUserId: Uuid
  status: string
  text: string
  encoding: string
  normalization: string
  lineEnding: string
  textChecksum: string
  textLength: number
  parserVersion: string
  sourceMapVersion: string
  sourceMap: TextSourceSpan[]
  blocks: TextDocumentBlock[]
  createdAt: DateTime
}

export interface IngestionJob {
  jobId: Uuid
  materialId: Uuid
  status: JobStatus
  progress: number
  parserVersion: string
  error: ApiErrorDetail | null
  createdAt: DateTime
  updatedAt: DateTime
  enableOcr: boolean
  ocrMode: 'quick' | 'standard'
  ocrUsed: boolean
  ocrProgress?: {
    status: string
    currentPage: number
    totalPages: number
    phase: string
  }
}

export type ChapterSegmentationMode = 'AUTO' | 'HEADING_RULES' | 'MARKDOWN' | 'DELIMITER' | 'FIXED_WINDOW'

export interface GraphBuildJob {
  buildId: Uuid
  materialId: Uuid
  studyProjectId: Uuid | null
  status: JobStatus
  progress: number
  graphId: Uuid | null
  sourceTextChecksum: string | null
  segmentationMode: ChapterSegmentationMode
  segmenterVersion: string
  extractorVersion: string
  error: ApiErrorDetail | null
  createdAt: DateTime
  updatedAt: DateTime
}

export interface KnowledgeGraphSummary {
  graphId: Uuid
  materialId: Uuid
  studyProjectId: Uuid | null
  version: number
  subjectCode: string
  chapterCount: number
  pointCount: number
  relationCount: number
  status: 'DRAFT' | 'READY' | 'SUPERSEDED'
  textChecksum: string
  createdAt: DateTime
}

export interface KnowledgeGraphPage {
  items: KnowledgeGraphSummary[]
  nextCursor: string | null
}

export interface Chapter {
  chapterId: Uuid
  graphId: Uuid
  parentChapterId: Uuid | null
  title: string
  ordinal: number
  depth: number
  startOffset: number
  endOffset: number
  segmentationMode: ChapterSegmentationMode
}

export interface MasteryRecord {
  userId: Uuid
  pointId: Uuid
  score: number
  reason: string
  repetitions: number
  easinessFactor: number
  intervalDays: number
  nextReviewAt: DateTime
  lastReviewedAt: DateTime | null
  lapses: number
  version: number
}

export interface KnowledgePoint {
  pointId: Uuid
  graphId: Uuid
  chapterId: Uuid
  conceptKey: string
  title: string
  summary: string
  subjectCode: string
  tags: string[]
  confidence: number
  sourceReferences: Array<{
    materialId: Uuid
    startOffset: number
    endOffset: number
    location: string
    quote: string | null
  }>
  mastery: MasteryRecord
  createdAt: DateTime
  updatedAt: DateTime
}

export interface KnowledgePointPage {
  items: KnowledgePoint[]
  nextCursor: string | null
}

export type RelationType = 'PREREQUISITE' | 'RELATED' | 'CONTRASTS'

export interface KnowledgeRelation {
  relationId: Uuid
  graphId: Uuid
  fromPointId: Uuid
  toPointId: Uuid
  type: RelationType
  confidence: number
  rationale: string
}

export interface KnowledgeRelationPage {
  items: KnowledgeRelation[]
  nextCursor: string | null
}

export interface MasteryRecordPage {
  items: MasteryRecord[]
  nextCursor: string | null
}

export type ReviewPlanType = 'ASSESSMENT' | 'LEARNING'

export interface PlanNode {
  pointId: Uuid
  chapterId: Uuid
  title: string
  summary: string
  tags: string[]
  masteryScore: number
  role: 'TARGET' | 'PREREQUISITE' | 'CONTEXT'
  weight: number
  selectionReason: string
  dependencyDepth: number
  questionTarget: boolean
  outsideRequestedChapters: boolean
  coversPointIds: Uuid[]
  supportsPointIds: Uuid[]
}

export interface PlanEdge {
  fromPointId: Uuid
  toPointId: Uuid
  type: RelationType
  confidence: number
  influenceWeight: number
}

export interface PlanGraph {
  schemaVersion: '1.0'
  reviewPlanId: Uuid
  type: ReviewPlanType
  status: 'OPEN' | 'COMPLETED' | 'EXPIRED'
  graphId: Uuid
  graphVersion: number
  ownerUserId: Uuid
  selectedChapterIds: Uuid[]
  snapshotVersion: string
  algorithmVersion: string
  nodes: PlanNode[]
  edges: PlanEdge[]
  rootPointIds: Uuid[]
  estimatedQuestionCount: number
  estimatedCoverage: number
  totalWeight: number
  createdAt: DateTime
  expiresAt: DateTime
}

export type GameStyle = 'CAMPUS' | 'FANTASY' | 'SCIENCE'
export type Difficulty = 'BASIC' | 'STANDARD' | 'ADVANCED'

export interface GameGenerationJob {
  generationId: Uuid
  status: JobStatus
  progress: number
  packageId: Uuid | null
  generatorVersion: string
  error: ApiErrorDetail | null
  createdAt: DateTime
  updatedAt: DateTime
}

export interface AdminUser {
  id: Uuid
  email: string
  displayName: string
  isActive: boolean
}

export interface CreditBalance {
  userId: Uuid
  balance: number
  available: number
  held: number
  updatedAt: DateTime
}

export interface AdminCreditCode {
  codeId: Uuid
  code: string
  credits: number
  status: 'ACTIVE' | 'REDEEMED' | 'REVOKED' | 'EXPIRED'
  redeemedBy: Uuid | null
  redeemedAt: DateTime | null
  expiresAt: DateTime | null
  createdAt: DateTime
}

export interface CreateCreditCodeBatchInput {
  count: number
  creditsPerCode: number
  expiresAt?: DateTime
}

export interface GamePackageManifest {
  packageId: Uuid
  schemaVersion: string
  generatorVersion: string
  reviewPlanId: Uuid
  snapshotVersion: string
  entrySceneId: string
  sceneCount: number
  checksum: string
  contentUrl: string
  createdAt: DateTime
}

export type AnswerKind = 'CHOICE' | 'FILL_BLANK' | 'TRUE_FALSE' | 'SHORT_ANSWER' | 'OTHER'

export interface GameChoice {
  choiceId: string
  questionId: Uuid
  text: string
  nextSceneId: string | null
  scoreDelta: number
  knowledgePointId: Uuid
  answerKind?: AnswerKind | null
  correct?: boolean | null
}

export interface GameScene {
  sceneId: string
  title?: string
  dialogue: Array<{ speakerId: string; text: string; emotion?: string }>
  choices: GameChoice[]
  knowledgeBindings: Array<{
    knowledgePointId: Uuid
    questionId: Uuid | null
    purpose: 'EXPLAIN' | 'QUESTION' | 'FEEDBACK'
  }>
}

export interface GamePackage {
  schemaVersion: '1.0'
  packageId: Uuid
  generatorVersion: string
  reviewPlanId: Uuid
  snapshotVersion: string
  entrySceneId: string
  scenes: GameScene[]
  assets: Array<{ assetId: string; type: 'BACKGROUND' | 'CHARACTER' | 'AUDIO' | 'OTHER'; uri: string }>
}

export interface RuntimeManifest {
  wasmVersion: string
  supportedSchemaVersions: string[]
  wasmUrl: string
  jsAdapterUrl: string
  checksum: string
  runtimeMode?: 'SHELL' | 'FULL'
  reviewSessionsAvailable?: boolean
  wasmAbiComplete?: boolean
}

export interface ReviewSession {
  sessionId: Uuid
  userId: Uuid
  packageId: Uuid
  reviewPlanId: Uuid
  snapshotVersion: string
  status: 'CREATED' | 'RUNNING' | 'COMPLETED' | 'ABANDONED'
  currentSceneId: string | null
  progressVersion: number
  startedAt: DateTime | null
  completedAt: DateTime | null
}

export interface ProgressSnapshot {
  sessionId: Uuid
  version: number
  currentSceneId: string
  visitedSceneIds: string[]
  runtimeState: Record<string, unknown>
  savedAt: DateTime
}

export interface AnswerResult {
  attemptId: Uuid
  questionId: Uuid
  knowledgePointId: Uuid
  answerKind: AnswerKind
  choiceId: string | null
  correct: boolean
  quality: number
  scoreDelta: number
  responseTimeMs: number
  hintsUsed: number
  attemptNumber: number
  occurredAt: DateTime
}

export interface ReviewResult {
  resultId: Uuid
  sessionId: Uuid
  status: 'ACCEPTED' | 'DUPLICATE'
  submittedAt: DateTime
}

export interface WasmAdapter {
  readonly engine?: 'wasm' | 'js'
  readonly runtimeVersion?: string
  readonly abiVersion?: number
  initialize(config: Record<string, unknown>): Promise<void>
  loadPackage(gamePackage: GamePackage): { valid: boolean; errors: Array<{ path: string; code: string; message: string }> }
  startSession(bootstrap: Record<string, unknown>): void
  dispatchInput(input: Record<string, unknown>): Array<Record<string, unknown>>
  renderFrame(deltaMs: number): void
  serializeState(): Record<string, unknown>
  lastError?(): { code: string; message: string; details: Record<string, unknown> }
  dispose(): void
}

export type PracticeQuestionKind = 'SINGLE_CHOICE' | 'FILL_BLANK' | 'TRUE_FALSE' | 'TERM_DEFINITION' | 'ESSAY'
export interface StudyProject {
  projectId: Uuid
  ownerUserId: Uuid
  name: string
  subjectCode: string | null
  materialIds: Uuid[]
  graphId: Uuid | null
  questionBankId: Uuid
  status: 'ACTIVE' | 'ARCHIVED'
  version: number
  createdAt: DateTime
  updatedAt: DateTime
}
export interface PracticeProjectDetails {
  project: StudyProject
  questionCounts: Partial<Record<PracticeQuestionKind, number>>
  readyQuestionCount: number
}
export interface PracticeQuestionOption { id: string; text: string }
export interface PracticeQuestion {
  questionId: Uuid
  projectId: Uuid
  questionBankId: Uuid
  kind: PracticeQuestionKind
  prompt: string
  options: PracticeQuestionOption[]
  correctAnswers: string[]
  explanation: string | null
  score: number
  difficulty: number
  knowledgePointId: Uuid | null
  sourceReferences: Array<{ materialId: Uuid; startOffset: number; endOffset: number; sourceMapVersion: string; excerptChecksum: string }>
  status: 'DRAFT' | 'READY' | 'DELETED'
  version: number
  createdAt: DateTime
  updatedAt: DateTime
}
export interface PracticeSessionQuestion {
  questionId: Uuid
  kind: PracticeQuestionKind
  prompt: string
  options: PracticeQuestionOption[]
  score: number
  difficulty: number
  knowledgePointId: Uuid | null
}
export interface PracticeAnswer {
  attemptId: Uuid
  questionId: Uuid
  correct: boolean
  similarity: number | null
  quality: number
  awardedScore: number
  answerJudgeVersion: string
}
export interface PracticeSession {
  sessionId: Uuid
  projectId: Uuid
  mode: 'RANDOM' | 'SMART_REVIEW' | 'EXAM'
  questions: PracticeSessionQuestion[]
  answers: PracticeAnswer[]
  durationSeconds: number | null
  status: 'CREATED' | 'ACTIVE' | 'COMPLETED' | 'ABANDONED'
  createdAt: DateTime
  completedAt: DateTime | null
}
export interface ExamPaper {
  examPaperId: Uuid
  projectId: Uuid
  title: string
  questionIds: Uuid[]
  durationSeconds: number
  seed: number
  totalScore: number
  createdAt: DateTime
}
export interface PracticeJobDiagnostic { materialId: Uuid | null; code: string; message: string; retryable: boolean }
export interface PracticeJob {
  jobId: Uuid
  projectId: Uuid
  kind: 'QUESTION_GENERATION' | 'EXAM_IMPORT'
  status: 'QUEUED' | 'RUNNING' | 'SUCCEEDED' | 'PARTIALLY_SUCCEEDED' | 'FAILED'
  progress: number
  createdCount: number
  diagnostics: PracticeJobDiagnostic[]
}
export interface QuestionHelp {
  questionId: Uuid
  matches: Array<{ knowledgePointId: Uuid | null; title: string; excerpt: string; similarity: number }>
  generatedExplanation: string | null
  grounded: boolean
  generatorVersion: string | null
}
export interface SharedPracticePackage {
  packageId: Uuid
  ownerUserId: Uuid
  sourceProjectId: Uuid
  version: string
  title: string
  subjectCode: string | null
  visibility: 'PRIVATE' | 'UNLISTED' | 'PUBLIC'
  sizeBytes: number
  downloadCount: number
  createdAt: DateTime
}
