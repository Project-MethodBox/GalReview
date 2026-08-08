import { api, ApiClientError } from './api'
import { readWorkflow, updateWorkflow, type StudyWorkflow } from './workflow'
import type { KnowledgeGraphSummary } from '../types/api'

let recoveryPromise: Promise<StudyWorkflow> | null = null
let lastRecoveryAt = 0
const RECOVERY_CACHE_MS = 30_000

export function newestGraph(graphs: KnowledgeGraphSummary[]) {
  return graphs
    .filter((graph) => graph.status === 'READY' || graph.status === 'SUPERSEDED')
    .sort((left, right) => new Date(right.createdAt).getTime() - new Date(left.createdAt).getTime() || right.version - left.version)[0]
}

export async function recoverWorkflow(): Promise<StudyWorkflow> {
  const current = readWorkflow()
  if (Date.now() - lastRecoveryAt < RECOVERY_CACHE_MS) return current
  if (recoveryPromise) return recoveryPromise

  recoveryPromise = (async () => {
    const [materials, projectPage] = await Promise.all([api.getAllMaterials(), api.listPracticeProjects()])
    const availableMaterials = materials.filter((material) => material.status !== 'DELETED')
    const projects = projectPage.items.filter((project) => project.graphId)
    const project = projects.find((item) => item.projectId === current.projectId) || projects[0]
    if (!project?.graphId) {
      return updateWorkflow({ projectId: undefined, material: undefined, graph: undefined, chapters: undefined, plan: undefined,
        gameGeneration: undefined, gameManifest: undefined, gamePackage: undefined, reviewSession: undefined,
        visitedSceneIds: undefined, answerResults: undefined })
    }
    const currentMaterial = current.material
      ? availableMaterials.find((item) => item.materialId === current.material?.materialId && project.materialIds.includes(item.materialId))
      : undefined
    const graph = current.graph?.graphId === project.graphId
      ? current.graph
      : await api.getKnowledgeGraph(project.graphId)

    if (!graph) {
      return updateWorkflow({
        material: undefined,
        graph: undefined,
        chapters: undefined,
        plan: undefined,
        gameGeneration: undefined,
        gameManifest: undefined,
        gamePackage: undefined,
        reviewSession: undefined,
        visitedSceneIds: undefined,
        answerResults: undefined,
      })
    }

    const material = currentMaterial?.materialId === graph.materialId
      ? currentMaterial
      : availableMaterials.find((item) => item.materialId === graph.materialId && project.materialIds.includes(item.materialId))
    const chapters = current.chapters?.length && current.chapters.every((chapter) => chapter.graphId === graph.graphId)
      ? current.chapters
      : await api.getChapters(graph.graphId)

    let plan = current.plan?.graphId === graph.graphId ? current.plan : undefined
    if (plan) {
      try {
        plan = await api.getReviewPlan(plan.reviewPlanId)
      } catch (reason) {
        plan = reason instanceof ApiClientError && reason.status === 404 ? undefined : current.plan
      }
    }

    let gameGeneration = plan ? current.gameGeneration : undefined
    let gameManifest = plan ? current.gameManifest : undefined
    let gamePackage = plan ? current.gamePackage : undefined
    let reviewSession = plan ? current.reviewSession : undefined
    let visitedSceneIds = plan ? current.visitedSceneIds : undefined

    if (gameGeneration && gameGeneration.status !== 'FAILED') {
      try {
        gameGeneration = await api.getGameGeneration(gameGeneration.generationId)
        if (gameGeneration.status === 'SUCCEEDED' && gameGeneration.packageId && !gameManifest) {
          gameManifest = await api.getGamePackage(gameGeneration.packageId)
        }
      } catch (reason) {
        gameGeneration = reason instanceof ApiClientError && reason.status === 404 ? undefined : current.gameGeneration
      }
    }
    if (gameManifest && !gamePackage) {
      try {
        gamePackage = await api.getGamePackageContent(gameManifest.contentUrl)
      } catch {
        gamePackage = undefined
      }
    }
    if (gamePackage && (gamePackage.reviewPlanId !== plan?.reviewPlanId || gamePackage.snapshotVersion !== plan.snapshotVersion)) {
      gameGeneration = undefined
      gameManifest = undefined
      gamePackage = undefined
      reviewSession = undefined
      visitedSceneIds = undefined
    }

    return updateWorkflow({ projectId: project.projectId, material, graph, chapters, plan, gameGeneration, gameManifest, gamePackage, reviewSession, visitedSceneIds })
  })().then((workflow) => {
    lastRecoveryAt = Date.now()
    return workflow
  }).finally(() => { recoveryPromise = null })

  return recoveryPromise
}
