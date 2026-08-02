import { api } from './api'
import { readWorkflow, updateWorkflow, type StudyWorkflow } from './workflow'
import type { KnowledgeGraphSummary, Material } from '../types/api'

let recoveryPromise: Promise<StudyWorkflow> | null = null

export function newestGraph(graphs: KnowledgeGraphSummary[]) {
  return graphs
    .filter((graph) => graph.status === 'READY' || graph.status === 'SUPERSEDED')
    .sort((left, right) => new Date(right.createdAt).getTime() - new Date(left.createdAt).getTime() || right.version - left.version)[0]
}

async function loadLatestGraph(materials: Material[]) {
  const results = await Promise.allSettled(materials.map((material) => api.getAllKnowledgeGraphs(material.materialId)))
  const graphs = results.flatMap((result) => result.status === 'fulfilled' ? result.value : [])
  return newestGraph(graphs)
}

export async function recoverWorkflow(): Promise<StudyWorkflow> {
  const current = readWorkflow()
  if (current.graph && current.material && current.chapters) return current
  if (recoveryPromise) return recoveryPromise

  recoveryPromise = (async () => {
    const materials = (await api.getAllMaterials()).filter((material) => material.status !== 'DELETED')
    const graph = await loadLatestGraph(materials)
    if (!graph) return current
    const material = materials.find((item) => item.materialId === graph.materialId)
    const chapters = await api.getChapters(graph.graphId)
    return updateWorkflow({ material, graph, chapters })
  })().finally(() => { recoveryPromise = null })

  return recoveryPromise
}
