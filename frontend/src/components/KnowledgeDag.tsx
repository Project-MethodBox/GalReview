import { Graph, GraphEvent, NodeEvent, type EdgeData, type GraphData, type IElementEvent, type NodeData } from '@antv/g6'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { Chapter, KnowledgePoint, KnowledgeRelation } from '../types/api'

const MASTERY_COMPLETE_SCORE = 60
const ROOT_ID = '__knowledge-root__'
const CHAPTER_PREFIX = '__chapter__:'

type GraphMode = 'overview' | 'all' | 'detail'
type NodeKind = 'root' | 'chapter' | 'point'

interface NodeMeta extends Record<string, unknown> {
  kind: NodeKind
  title: string
  subtitle?: string
  pointId?: string
  chapterId?: string
  mastery?: number
}

interface EdgeMeta extends Record<string, unknown> {
  structural: boolean
  relationId?: string
}

interface HighlightState {
  availableIds: Set<string>
  pathIds: Set<string>
  pathEdgeIds: Set<string>
  selectedComplete: boolean
}

function FullscreenIcon({ active }: { active: boolean }) {
  return active ? (
    <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 3v6H3M15 3v6h6M9 21v-6H3M15 21v-6h6" /></svg>
  ) : (
    <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 3H3v5M16 3h5v5M8 21H3v-5M16 21h5v-5" /></svg>
  )
}

function nodeMeta(node: NodeData): NodeMeta {
  return (node.data || {}) as NodeMeta
}

function edgeMeta(edge: EdgeData): EdgeMeta {
  return (edge.data || {}) as EdgeMeta
}

function prerequisiteRelations(points: KnowledgePoint[], relations: KnowledgeRelation[]) {
  const pointIds = new Set(points.map((point) => point.pointId))
  return relations.filter((relation) => relation.type === 'PREREQUISITE'
    && pointIds.has(relation.fromPointId)
    && pointIds.has(relation.toPointId)
    && relation.fromPointId !== relation.toPointId)
}

function buildGraphModel(points: KnowledgePoint[], relations: KnowledgeRelation[], chapters: Chapter[], mode: GraphMode) {
  const prerequisiteEdges = prerequisiteRelations(points, relations)
  const linkedIds = new Set(prerequisiteEdges.flatMap((relation) => [relation.fromPointId, relation.toPointId]))
  const pointById = new Map(points.map((point) => [point.pointId, point]))
  const unlinkedPoints = points
    .filter((point) => !linkedIds.has(point.pointId))
    .sort((left, right) => left.title.localeCompare(right.title, 'zh-CN'))

  if (mode === 'overview') {
    const chapterById = new Map(chapters.map((chapter) => [chapter.chapterId, chapter]))
    const pointsByChapter = new Map<string, KnowledgePoint[]>()
    for (const point of points) pointsByChapter.set(point.chapterId, [...(pointsByChapter.get(point.chapterId) || []), point])
    const orderedChapterIds = [...pointsByChapter.keys()].sort((left, right) => {
      const leftChapter = chapterById.get(left)
      const rightChapter = chapterById.get(right)
      if (!leftChapter || !rightChapter) return leftChapter ? -1 : rightChapter ? 1 : left.localeCompare(right)
      return leftChapter.ordinal - rightChapter.ordinal || leftChapter.title.localeCompare(rightChapter.title, 'zh-CN')
    })
    const nodes: NodeData[] = [{
      id: ROOT_ID,
      data: { kind: 'root', title: '知识结构', subtitle: `${points.length} 个知识点 · ${chapters.length} 个章节` } satisfies NodeMeta,
    }]
    const edges: EdgeData[] = []
    for (const chapterId of orderedChapterIds) {
      const chapterPoints = pointsByChapter.get(chapterId) || []
      const chapterUnlinked = chapterPoints.filter((point) => !linkedIds.has(point.pointId)).length
      const chapter = chapterById.get(chapterId)
      const nodeId = `${CHAPTER_PREFIX}${chapterId}`
      nodes.push({
        id: nodeId,
        depth: 1,
        data: {
          kind: 'chapter',
          chapterId,
          title: chapter?.title || '其他知识点',
          subtitle: `${chapterPoints.length} 个知识点 · ${chapterUnlinked} 个未连接`,
        } satisfies NodeMeta,
      })
      edges.push({ id: `overview:${chapterId}`, source: ROOT_ID, target: nodeId, data: { structural: true } satisfies EdgeMeta })
    }
    nodes[0].children = nodes.slice(1).map((node) => node.id)
    nodes[0].depth = 0
    return { data: { nodes, edges } satisfies GraphData, unlinkedPoints: [] as KnowledgePoint[] }
  }

  const nodes: NodeData[] = [...linkedIds].flatMap((pointId) => {
    const point = pointById.get(pointId)
    if (!point) return []
    return [{
      id: pointId,
      data: {
        kind: 'point',
        pointId,
        title: point.title,
        subtitle: `掌握度 ${Math.round(point.mastery.score)}`,
        mastery: Math.round(point.mastery.score),
      } satisfies NodeMeta,
    }]
  })
  const edges: EdgeData[] = prerequisiteEdges.map((relation) => ({
    id: relation.relationId,
    source: relation.fromPointId,
    target: relation.toPointId,
    data: { structural: false, relationId: relation.relationId } satisfies EdgeMeta,
  }))
  return { data: { nodes, edges } satisfies GraphData, unlinkedPoints }
}

function buildHighlights(selectedPointId: string | undefined, points: KnowledgePoint[], relations: KnowledgeRelation[]): HighlightState {
  const empty = { availableIds: new Set<string>(), pathIds: new Set<string>(), pathEdgeIds: new Set<string>(), selectedComplete: false }
  if (!selectedPointId) return empty
  const pointById = new Map(points.map((point) => [point.pointId, point]))
  const selected = pointById.get(selectedPointId)
  if (!selected) return empty
  if (selected.mastery.score >= MASTERY_COMPLETE_SCORE) return { ...empty, selectedComplete: true }

  const prerequisiteEdges = prerequisiteRelations(points, relations)
  const incoming = new Map<string, KnowledgeRelation[]>()
  const outgoing = new Map<string, KnowledgeRelation[]>()
  for (const edge of prerequisiteEdges) {
    incoming.set(edge.toPointId, [...(incoming.get(edge.toPointId) || []), edge])
    outgoing.set(edge.fromPointId, [...(outgoing.get(edge.fromPointId) || []), edge])
  }
  const ancestorIds = new Set<string>()
  const pending = [selectedPointId]
  while (pending.length) {
    const currentId = pending.pop()!
    for (const edge of incoming.get(currentId) || []) {
      if (ancestorIds.has(edge.fromPointId)) continue
      ancestorIds.add(edge.fromPointId)
      pending.push(edge.fromPointId)
    }
  }
  const availableIds = new Set([...ancestorIds].filter((pointId) => {
    const point = pointById.get(pointId)
    if (!point || point.mastery.score >= MASTERY_COMPLETE_SCORE) return false
    return (incoming.get(pointId) || []).every((edge) => (pointById.get(edge.fromPointId)?.mastery.score || 0) >= MASTERY_COMPLETE_SCORE)
  }))
  const pathIds = new Set<string>()
  const pathEdgeIds = new Set<string>()
  const pathQueue = [...availableIds]
  const visited = new Set(pathQueue)
  while (pathQueue.length) {
    const currentId = pathQueue.shift()!
    for (const edge of outgoing.get(currentId) || []) {
      if (edge.toPointId !== selectedPointId && !ancestorIds.has(edge.toPointId)) continue
      pathEdgeIds.add(edge.relationId)
      if (edge.toPointId !== selectedPointId) pathIds.add(edge.toPointId)
      if (!visited.has(edge.toPointId)) {
        visited.add(edge.toPointId)
        pathQueue.push(edge.toPointId)
      }
    }
  }
  return { availableIds, pathIds, pathEdgeIds, selectedComplete: false }
}

export default function KnowledgeDag({ points, relations, chapters, mode, selectedPointId, onSelect, onSelectChapter }: {
  points: KnowledgePoint[]
  relations: KnowledgeRelation[]
  chapters: Chapter[]
  mode: GraphMode
  selectedPointId?: string
  onSelect: (pointId: string) => void
  onSelectChapter: (chapterId: string) => void
}) {
  const shellRef = useRef<HTMLDivElement>(null)
  const viewportRef = useRef<HTMLDivElement>(null)
  const graphRef = useRef<Graph | null>(null)
  const readyGraphRef = useRef<Graph | null>(null)
  const onSelectRef = useRef(onSelect)
  const onSelectChapterRef = useRef(onSelectChapter)
  const applyStatesRef = useRef<(graph: Graph) => Promise<void>>(async () => undefined)
  const fitSelectedPathRef = useRef<(graph: Graph, animate: boolean) => Promise<void>>(async () => undefined)
  const [fullscreen, setFullscreen] = useState(false)
  const [zoom, setZoom] = useState(1)
  const [showUnlinked, setShowUnlinked] = useState(false)
  const [darkMode, setDarkMode] = useState(() => document.documentElement.dataset.theme === 'dark')
  const [renderError, setRenderError] = useState('')
  const model = useMemo(() => buildGraphModel(points, relations, chapters, mode), [chapters, mode, points, relations])
  const graphData = model.data
  const unlinkedPoints = model.unlinkedPoints
  const highlights = useMemo(() => buildHighlights(selectedPointId, points, relations), [points, relations, selectedPointId])
  const metaById = useMemo(() => new Map((graphData.nodes || []).map((node) => [String(node.id), nodeMeta(node)])), [graphData.nodes])
  const selectedPathIds = useMemo(() => {
    if (mode !== 'detail' || !selectedPointId) return []
    const ids = new Set<string>([selectedPointId, ...highlights.availableIds, ...highlights.pathIds])
    return [...ids].filter((id) => metaById.has(id))
  }, [highlights.availableIds, highlights.pathIds, metaById, mode, selectedPointId])

  useEffect(() => { onSelectRef.current = onSelect }, [onSelect])
  useEffect(() => { onSelectChapterRef.current = onSelectChapter }, [onSelectChapter])
  useEffect(() => {
    setShowUnlinked(mode !== 'overview' && !(graphData.nodes || []).length && unlinkedPoints.length > 0)
  }, [graphData.nodes, mode, unlinkedPoints.length])
  useEffect(() => {
    const observer = new MutationObserver(() => setDarkMode(document.documentElement.dataset.theme === 'dark'))
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] })
    return () => observer.disconnect()
  }, [])

  const applyStates = useCallback(async (graph: Graph) => {
    const states: Record<string, string[]> = {}
    for (const node of graphData.nodes || []) {
      const meta = nodeMeta(node)
      if (meta.kind !== 'point' || !meta.pointId) continue
      const nodeStates: string[] = []
      if (meta.pointId === selectedPointId) nodeStates.push(highlights.selectedComplete ? 'available' : 'selected')
      else if (highlights.availableIds.has(meta.pointId)) nodeStates.push('available')
      else if (highlights.pathIds.has(meta.pointId)) nodeStates.push('path')
      else if (selectedPointId) nodeStates.push('inactive')
      states[String(node.id)] = nodeStates
    }
    for (const edge of graphData.edges || []) {
      const meta = edgeMeta(edge)
      if (meta.structural) continue
      states[String(edge.id)] = meta.relationId && highlights.pathEdgeIds.has(meta.relationId)
        ? ['highlight']
        : selectedPointId ? ['inactive'] : []
    }
    await graph.setElementState(states, false)
  }, [graphData.edges, graphData.nodes, highlights, selectedPointId])

  const fitSelectedPath = useCallback(async (graph: Graph, animate: boolean) => {
    if (mode !== 'detail') return
    if (!selectedPathIds.length) {
      await graph.fitView({ when: 'always', direction: 'both' }, animate ? { duration: 240, easing: 'ease-in-out' } : false)
      setZoom(graph.getZoom())
      return
    }

    let minX = Number.POSITIVE_INFINITY
    let minY = Number.POSITIVE_INFINITY
    let maxX = Number.NEGATIVE_INFINITY
    let maxY = Number.NEGATIVE_INFINITY
    for (const id of selectedPathIds) {
      const bounds = graph.getElementRenderBounds(id)
      minX = Math.min(minX, bounds.min[0])
      minY = Math.min(minY, bounds.min[1])
      maxX = Math.max(maxX, bounds.max[0])
      maxY = Math.max(maxY, bounds.max[1])
    }

    const viewport = viewportRef.current
    if (!viewport || !Number.isFinite(minX) || !Number.isFinite(minY) || !Number.isFinite(maxX) || !Number.isFinite(maxY)) {
      await graph.focusElement(selectedPathIds, animate ? { duration: 240, easing: 'ease-in-out' } : false)
      setZoom(graph.getZoom())
      return
    }

    const horizontalPadding = viewport.clientWidth <= 640 ? 44 : 96
    const verticalPadding = viewport.clientHeight <= 520 ? 40 : 84
    const contentWidth = Math.max(164, maxX - minX)
    const contentHeight = Math.max(50, maxY - minY)
    const availableWidth = Math.max(120, viewport.clientWidth - horizontalPadding)
    const availableHeight = Math.max(120, viewport.clientHeight - verticalPadding)
    const maximumZoom = selectedPathIds.length === 1 ? 1 : 1.08
    const targetZoom = Math.min(maximumZoom, Math.max(0.16, Math.min(
      availableWidth / contentWidth,
      availableHeight / contentHeight,
    )))
    const animation = animate ? { duration: 240, easing: 'ease-in-out' } : false

    await graph.zoomTo(targetZoom, animation)
    await graph.focusElement(selectedPathIds, animation)
    setZoom(graph.getZoom())
  }, [mode, selectedPathIds])

  useEffect(() => { applyStatesRef.current = applyStates }, [applyStates])
  useEffect(() => { fitSelectedPathRef.current = fitSelectedPath }, [fitSelectedPath])

  useEffect(() => {
    const container = viewportRef.current
    if (!container || !(graphData.nodes || []).length) return
    let active = true
    let createdGraph: Graph | null = null
    const frame = window.requestAnimationFrame(() => {
      if (!active) return
      setRenderError('')
      const colors = darkMode ? {
      text: '#f2f3f5', muted: '#a9afb8', surface: '#303238', chapter: '#242f3a', root: '#21364a', line: '#718093', structural: '#596675',
      } : {
      text: '#24272b', muted: '#66717d', surface: '#ffffff', chapter: '#eef5fb', root: '#dfefff', line: '#8997a5', structural: '#aab8c5',
      }
      const graph = new Graph({
      container,
      data: graphData,
      autoResize: true,
      autoFit: mode === 'detail' ? 'center' : { type: 'view', options: { when: 'always', direction: 'both' } },
      padding: [48, 54, 48, 54],
      zoom: mode === 'detail' ? .72 : 1,
      zoomRange: [0.12, 2.5],
      animation: false,
      layout: mode === 'overview' ? {
        type: 'compact-box',
        direction: 'H',
        getWidth: (datum: NodeData) => nodeMeta(datum).kind === 'root' ? 174 : 210,
        getHeight: (datum: NodeData) => nodeMeta(datum).kind === 'root' ? 52 : 68,
        getHGap: () => 80,
        getVGap: () => 26,
        getSubTreeSep: () => 24,
      } : {
        type: 'antv-dagre',
        rankdir: 'LR',
        ranker: 'network-simplex',
        nodesep: 20,
        ranksep: 82,
        controlPoints: true,
        edgeLabelSpace: false,
      },
      behaviors: ['drag-canvas', { type: 'zoom-canvas', sensitivity: 1.15, preventDefault: true }],
      node: {
        type: 'rect',
        style: (datum) => {
          const meta = nodeMeta(datum)
          const point = meta.kind === 'point'
          const root = meta.kind === 'root'
          return {
            size: point ? [164, 50] : root ? [174, 52] : [210, 68],
            radius: point ? 10 : 12,
            fill: point ? colors.surface : root ? colors.root : colors.chapter,
            stroke: root ? '#4c8fca' : point ? colors.line : '#8fb2d1',
            lineWidth: root ? 2 : 1.3,
            // G6 incrementally merges styles when an element leaves a state.
            // Keep the neutral shadow explicit so a previous red selection glow
            // cannot remain on nodes that are no longer selected.
            shadowColor: 'transparent',
            shadowBlur: 0,
            cursor: point || meta.kind === 'chapter' ? 'pointer' : 'default',
            labelText: meta.kind === 'chapter' ? meta.title.replace(/\s+/, '\n') : meta.title,
            labelPlacement: 'center',
            labelOffsetY: 0,
            labelFill: colors.text,
            labelFontSize: point ? 12 : 13,
            labelFontWeight: root || meta.kind === 'chapter' ? 600 : 500,
            labelLineHeight: 18,
            labelWordWrap: true,
            labelMaxWidth: point ? 144 : root ? 154 : 184,
          }
        },
        state: {
          selected: { fill: darkMode ? '#512d32' : '#fff0f0', stroke: '#f56c6c', lineWidth: 3, shadowColor: '#f56c6c', shadowBlur: 12 },
          available: { fill: darkMode ? '#253d2b' : '#f0f9eb', stroke: '#67c23a', lineWidth: 2.5 },
          path: { fill: darkMode ? '#443823' : '#fdf6ec', stroke: '#e6a23c', lineWidth: 2 },
          inactive: { opacity: 0.86 },
        },
      },
      edge: {
        type: 'polyline',
        style: (datum) => {
          const structural = edgeMeta(datum).structural
          return {
            stroke: structural ? colors.structural : colors.line,
            lineWidth: structural ? 1.2 : 1.6,
            opacity: structural ? 0.58 : 0.76,
            radius: 10,
            endArrow: !structural,
          }
        },
        state: {
          highlight: { stroke: '#e6a23c', lineWidth: 3, opacity: 1 },
          inactive: { opacity: 0.42 },
        },
      },
      })
      createdGraph = graph
      graphRef.current = graph
      graph.on(NodeEvent.CLICK, (event: IElementEvent) => {
      const meta = metaById.get(String(event.target.id))
      if (meta?.pointId) onSelectRef.current(meta.pointId)
      else if (meta?.chapterId) onSelectChapterRef.current(meta.chapterId)
      })
      graph.on(GraphEvent.AFTER_TRANSFORM, () => {
        if (active && readyGraphRef.current === graph) setZoom(graph.getZoom())
      })
      void graph.render().then(async () => {
      if (!active) return
      readyGraphRef.current = graph
      await applyStatesRef.current(graph)
      if (mode === 'detail') await fitSelectedPathRef.current(graph, false)
      setZoom(graph.getZoom())
      }).catch((reason: unknown) => {
      if (active) setRenderError(reason instanceof Error ? reason.message : '知识图谱绘制失败')
      })
    })
    return () => {
      active = false
      window.cancelAnimationFrame(frame)
      const graph = createdGraph
      if (!graph) return
      if (readyGraphRef.current === graph) readyGraphRef.current = null
      if (graphRef.current === graph) graphRef.current = null
      graph.destroy()
    }
  }, [darkMode, graphData, metaById, mode])

  useEffect(() => {
    const graph = readyGraphRef.current
    if (graph) void applyStates(graph).then(() => mode === 'detail' ? fitSelectedPath(graph, true) : undefined)
  }, [applyStates, fitSelectedPath, mode])

  useEffect(() => {
    const shell = shellRef.current
    const handleFullscreenChange = () => {
      const active = document.fullscreenElement === shell
      setFullscreen(active)
      window.setTimeout(() => {
        const graph = graphRef.current
        if (!graph) return
        if (mode === 'detail') void fitSelectedPathRef.current(graph, false)
        else void graph.fitView({ when: 'always', direction: 'both' })
      }, 0)
    }
    document.addEventListener('fullscreenchange', handleFullscreenChange)
    return () => document.removeEventListener('fullscreenchange', handleFullscreenChange)
  }, [mode])

  async function toggleFullscreen() {
    const shell = shellRef.current
    if (!shell) return
    if (document.fullscreenElement === shell) await document.exitFullscreen()
    else await shell.requestFullscreen()
  }

  async function changeZoom(factor: number) {
    const graph = graphRef.current
    if (!graph) return
    await graph.zoomTo(Math.min(2.5, Math.max(0.12, graph.getZoom() * factor)), { duration: 180 })
    setZoom(graph.getZoom())
  }

  const resetGraphView = useCallback(() => {
    const graph = graphRef.current
    if (!graph) return
    void graph.fitView({ when: 'always', direction: 'both' }, { duration: 240 }).then(() => setZoom(graph.getZoom()))
  }, [])

  const hasGraphNodes = Boolean((graphData.nodes || []).length)
  return (
    <div className="dag-shell dag-shell--g6" ref={shellRef}>
      <div className="dag-toolbar" aria-label="图谱操作">
        <div className="dag-legend" aria-label="节点颜色说明">
          {mode === 'overview' ? <span className="chapter">点击章节查看路径</span> : <><span className="available">需学习</span><span className="path">学习路径</span><span className="target">当前目标</span></>}
        </div>
        <div className="dag-zoom-controls">
          {mode !== 'overview' && unlinkedPoints.length ? <button className={`dag-unlinked-toggle${showUnlinked ? ' is-active' : ''}`} type="button" aria-expanded={showUnlinked} onClick={() => setShowUnlinked((current) => !current)}>未连接 {unlinkedPoints.length}</button> : null}
          <button type="button" aria-label="缩小图谱" disabled={!hasGraphNodes} onClick={() => void changeZoom(1 / 1.18)}>−</button>
          <span>{Math.round(zoom * 100)}%</span>
          <button type="button" aria-label="放大图谱" disabled={!hasGraphNodes} onClick={() => void changeZoom(1.18)}>＋</button>
          <button className="dag-fullscreen-button" type="button" aria-label={fullscreen ? '退出全屏' : '全屏显示知识图谱'} title={fullscreen ? '退出全屏' : '全屏'} aria-pressed={fullscreen} onClick={() => void toggleFullscreen()}><FullscreenIcon active={fullscreen} /></button>
          <button type="button" disabled={!hasGraphNodes} onClick={resetGraphView}>{mode === 'detail' ? '重置视图' : '适应画布'}</button>
        </div>
      </div>
      <div className="dag-stage">
        <div className="dag-viewport dag-viewport--g6" ref={viewportRef} onDoubleClick={resetGraphView}>
          {!points.length ? <p className="dag-empty">没有匹配的知识节点。</p> : null}
          {points.length && !hasGraphNodes ? <p className="dag-empty">当前范围没有先修关系，请从“未连接”面板选择知识点。</p> : null}
          {renderError ? <p className="dag-empty dag-empty--error" role="alert">{renderError}</p> : null}
        </div>
        {showUnlinked ? <aside className="dag-unlinked-panel" aria-label="未连接知识点">
          <header><div><strong>未连接知识点</strong><small>暂未参与先修路径</small></div><button type="button" aria-label="关闭未连接知识点" onClick={() => setShowUnlinked(false)}>×</button></header>
          <div className="dag-unlinked-grid">{unlinkedPoints.map((point) => <button className={point.pointId === selectedPointId ? 'selected' : ''} type="button" key={point.pointId} title={point.title} aria-label={`${point.title}，掌握度 ${Math.round(point.mastery.score)}`} onClick={() => onSelect(point.pointId)}><span>{point.title}</span><small>掌握度 {Math.round(point.mastery.score)}</small></button>)}</div>
        </aside> : null}
      </div>
    </div>
  )
}
