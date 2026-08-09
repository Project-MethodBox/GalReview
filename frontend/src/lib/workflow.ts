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
  projectId?: string
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
  try {
    localStorage.setItem(WORKFLOW_KEY, JSON.stringify(next))
  } catch (error) {
    console.warn('无法保存完整工作流状态', error)
    try {
      const minimal = { projectId: next.projectId, material: next.material, graph: next.graph }
      localStorage.setItem(WORKFLOW_KEY, JSON.stringify(minimal))
    } catch {
      // 最终降级：静默失败
    }
  }
  window.dispatchEvent(new Event('galreview:workflow'))
  return next
}

/**
 * 结束一轮复习后只保留创建新计划仍需使用的资料与知识图谱上下文。
 * 旧计划、游戏包、会话和作答不能再被 /review 或首页恢复。
 */
export function clearCompletedReview(): StudyWorkflow {
  const current = readWorkflow()
  const next: StudyWorkflow = {
    projectId: current.projectId,
    material: current.material,
    graph: current.graph,
    chapters: current.chapters,
  }
  localStorage.setItem(WORKFLOW_KEY, JSON.stringify(next))
  window.dispatchEvent(new Event('galreview:workflow'))
  return next
}

export function resetWorkflow(): void {
  localStorage.removeItem(WORKFLOW_KEY)
  window.dispatchEvent(new Event('galreview:workflow'))
}
