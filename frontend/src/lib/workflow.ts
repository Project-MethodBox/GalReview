import type {
  AnswerResult,
  Chapter,
  Difficulty,
  GameGenerationJob,
  GamePackage,
  GamePackageManifest,
  GameStyle,
  KnowledgeGraphSummary,
  Material,
  PlanGraph,
  ReviewSession,
} from '../types/api'

const WORKFLOW_KEY = 'galreview.workflow'

export interface StudyWorkflow {
  material?: Material
  graph?: KnowledgeGraphSummary
  chapters?: Chapter[]
  plan?: PlanGraph
  gameGeneration?: GameGenerationJob
  gameStyle?: GameStyle
  gameDifficulty?: Difficulty
  gameManifest?: GamePackageManifest
  gamePackage?: GamePackage
  reviewSession?: ReviewSession
  visitedSceneIds?: string[]
  answerResults?: AnswerResult[]
  resultIdempotencyKey?: string
}

export function readWorkflow(): StudyWorkflow {
  try {
    const raw = localStorage.getItem(WORKFLOW_KEY)
    return raw ? (JSON.parse(raw) as StudyWorkflow) : {}
  } catch {
    return {}
  }
}

export function updateWorkflow(patch: Partial<StudyWorkflow>): StudyWorkflow {
  const next = { ...readWorkflow(), ...patch }
  localStorage.setItem(WORKFLOW_KEY, JSON.stringify(next))
  window.dispatchEvent(new Event('galreview:workflow'))
  return next
}

export function resetWorkflow(): void {
  localStorage.removeItem(WORKFLOW_KEY)
  window.dispatchEvent(new Event('galreview:workflow'))
}
