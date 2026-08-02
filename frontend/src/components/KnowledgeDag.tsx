import { useCallback, useEffect, useMemo, useRef, useState, type PointerEvent as ReactPointerEvent, type WheelEvent as ReactWheelEvent } from 'react'
import type { KnowledgePoint, KnowledgeRelation } from '../types/api'

const NODE_WIDTH = 128
const NODE_HEIGHT = 46
const COLUMN_GAP = 128
const ROW_GAP = 34
const CANVAS_PADDING = 46
const MASTERY_COMPLETE_SCORE = 60
const DEFAULT_SCALE = .96

interface PositionedPoint {
  point: KnowledgePoint
  x: number
  y: number
}

interface DagLayout {
  width: number
  height: number
  nodes: PositionedPoint[]
  nodeById: Map<string, PositionedPoint>
  edges: KnowledgeRelation[]
}

interface ViewTransform {
  x: number
  y: number
  scale: number
}

interface HighlightState {
  availableIds: Set<string>
  pathIds: Set<string>
  pathEdgeIds: Set<string>
  selectedComplete: boolean
}

function FullscreenIcon({ active }: { active: boolean }) {
  return active ? (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M9 3v6H3M15 3v6h6M9 21v-6H3M15 21v-6h6" />
    </svg>
  ) : (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M8 3H3v5M16 3h5v5M8 21H3v-5M16 21h5v-5" />
    </svg>
  )
}

function clamp(value: number, minimum: number, maximum: number) {
  return Math.min(maximum, Math.max(minimum, value))
}

function buildLayout(points: KnowledgePoint[], relations: KnowledgeRelation[], viewportWidth = 0, viewportHeight = 0): DagLayout {
  const ids = new Set(points.map((point) => point.pointId))
  const edges = relations.filter((relation) => relation.type === 'PREREQUISITE' && ids.has(relation.fromPointId) && ids.has(relation.toPointId))
  const outgoing = new Map<string, string[]>()
  const incoming = new Map<string, string[]>()
  const indegree = new Map(points.map((point) => [point.pointId, 0]))
  const depth = new Map(points.map((point) => [point.pointId, 0]))

  for (const edge of edges) {
    outgoing.set(edge.fromPointId, [...(outgoing.get(edge.fromPointId) || []), edge.toPointId])
    incoming.set(edge.toPointId, [...(incoming.get(edge.toPointId) || []), edge.fromPointId])
    indegree.set(edge.toPointId, (indegree.get(edge.toPointId) || 0) + 1)
  }

  const queue = points.filter((point) => indegree.get(point.pointId) === 0).sort((a, b) => a.title.localeCompare(b.title, 'zh-CN')).map((point) => point.pointId)
  let cursor = 0
  while (cursor < queue.length) {
    const pointId = queue[cursor++]
    for (const targetId of outgoing.get(pointId) || []) {
      depth.set(targetId, Math.max(depth.get(targetId) || 0, (depth.get(pointId) || 0) + 1))
      const nextIndegree = (indegree.get(targetId) || 0) - 1
      indegree.set(targetId, nextIndegree)
      if (nextIndegree === 0) queue.push(targetId)
    }
  }

  const pointById = new Map(points.map((point) => [point.pointId, point]))
  const primaryParent = new Map<string, string>()
  for (const point of points) {
    const pointDepth = depth.get(point.pointId) || 0
    const candidates = (incoming.get(point.pointId) || [])
      .filter((parentId) => (depth.get(parentId) || 0) < pointDepth)
      .sort((left, right) => (depth.get(right) || 0) - (depth.get(left) || 0)
        || (pointById.get(left)?.title || '').localeCompare(pointById.get(right)?.title || '', 'zh-CN'))
    if (candidates[0]) primaryParent.set(point.pointId, candidates[0])
  }

  const treeChildren = new Map<string, string[]>()
  for (const [childId, parentId] of primaryParent) treeChildren.set(parentId, [...(treeChildren.get(parentId) || []), childId])
  for (const children of treeChildren.values()) children.sort((left, right) => (pointById.get(left)?.title || '').localeCompare(pointById.get(right)?.title || '', 'zh-CN'))
  const roots = points
    .filter((point) => !primaryParent.has(point.pointId))
    .sort((left, right) => left.title.localeCompare(right.title, 'zh-CN'))

  function countLeaves(pointId: string): number {
    const children = treeChildren.get(pointId) || []
    return children.length ? children.reduce((total, childId) => total + countLeaves(childId), 0) : 1
  }

  const leafCount = Math.max(1, roots.reduce((total, root) => total + countLeaves(root.pointId), 0))
  const maximumDepth = Math.max(0, ...depth.values())
  const naturalWidth = CANVAS_PADDING * 2 + (maximumDepth + 1) * NODE_WIDTH + maximumDepth * COLUMN_GAP
  const naturalHeight = Math.max(420, CANVAS_PADDING * 2 + leafCount * NODE_HEIGHT + Math.max(0, leafCount - 1) * ROW_GAP)
  const width = Math.max(naturalWidth, viewportWidth > 0 ? viewportWidth - 32 : 0)
  const height = Math.max(naturalHeight, viewportHeight > 0 ? viewportHeight - 32 : 0)
  const columnStep = maximumDepth > 0 ? (width - CANVAS_PADDING * 2 - NODE_WIDTH) / maximumDepth : 0
  const treeHeight = height
  const leafStep = leafCount > 1 ? Math.max(NODE_HEIGHT + ROW_GAP, (treeHeight - CANVAS_PADDING * 2 - NODE_HEIGHT) / (leafCount - 1)) : 0
  const nodes: PositionedPoint[] = []
  let leafCursor = 0

  function placeTree(pointId: string): number {
    const children = treeChildren.get(pointId) || []
    let centerY: number
    if (children.length) {
      const childCenters = children.map(placeTree)
      centerY = (childCenters[0] + childCenters[childCenters.length - 1]) / 2
    } else {
      centerY = leafCount > 1 ? CANVAS_PADDING + NODE_HEIGHT / 2 + leafCursor * leafStep : treeHeight / 2
      leafCursor += 1
    }
    const point = pointById.get(pointId)
    if (point) nodes.push({
      point,
      x: maximumDepth > 0 ? CANVAS_PADDING + (depth.get(pointId) || 0) * columnStep : (width - NODE_WIDTH) / 2,
      y: centerY - NODE_HEIGHT / 2,
    })
    return centerY
  }

  roots.forEach((root) => placeTree(root.pointId))

  return { width, height, nodes, nodeById: new Map(nodes.map((node) => [node.point.pointId, node])), edges }
}

function buildHighlights(selectedPointId: string | undefined, points: KnowledgePoint[], relations: KnowledgeRelation[]): HighlightState {
  const empty = { availableIds: new Set<string>(), pathIds: new Set<string>(), pathEdgeIds: new Set<string>(), selectedComplete: false }
  if (!selectedPointId) return empty
  const pointById = new Map(points.map((point) => [point.pointId, point]))
  const selected = pointById.get(selectedPointId)
  if (!selected) return empty
  if (selected.mastery.score >= MASTERY_COMPLETE_SCORE) return { ...empty, selectedComplete: true }

  const prerequisiteEdges = relations.filter((relation) => relation.type === 'PREREQUISITE' && pointById.has(relation.fromPointId) && pointById.has(relation.toPointId))
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

export default function KnowledgeDag({ points, relations, selectedPointId, onSelect }: {
  points: KnowledgePoint[]
  relations: KnowledgeRelation[]
  selectedPointId?: string
  onSelect: (pointId: string) => void
}) {
  const shellRef = useRef<HTMLDivElement>(null)
  const viewportRef = useRef<HTMLDivElement>(null)
  const dragRef = useRef<{ pointerId: number; clientX: number; clientY: number; originX: number; originY: number } | undefined>(undefined)
  const [transform, setTransform] = useState<ViewTransform>({ x: 24, y: 24, scale: DEFAULT_SCALE })
  const [fullscreen, setFullscreen] = useState(false)
  const [viewportSize, setViewportSize] = useState({ width: 0, height: 0 })
  const layout = useMemo(() => buildLayout(points, relations, viewportSize.width, viewportSize.height), [points, relations, viewportSize.height, viewportSize.width])
  const highlights = useMemo(() => buildHighlights(selectedPointId, points, relations), [points, relations, selectedPointId])

  const fitGraph = useCallback(() => {
    const viewport = viewportRef.current
    if (!viewport || !points.length) return
    const bounds = viewport.getBoundingClientRect()
    const isFullscreen = document.fullscreenElement === shellRef.current
    const padding = isFullscreen ? 32 : 48
    const scale = clamp(
      Math.min((bounds.width - padding) / layout.width, (bounds.height - padding) / layout.height),
      .02,
      isFullscreen ? 2.5 : 1,
    )
    setTransform({ x: (bounds.width - layout.width * scale) / 2, y: (bounds.height - layout.height * scale) / 2, scale })
  }, [layout.height, layout.width, points.length])

  const showAtDefaultScale = useCallback(() => {
    const viewport = viewportRef.current
    if (!viewport || !points.length) return
    const bounds = viewport.getBoundingClientRect()
    setTransform({
      x: (bounds.width - layout.width * DEFAULT_SCALE) / 2,
      y: (bounds.height - layout.height * DEFAULT_SCALE) / 2,
      scale: DEFAULT_SCALE,
    })
  }, [layout.height, layout.width, points.length])

  useEffect(() => {
    const frame = window.requestAnimationFrame(showAtDefaultScale)
    return () => window.cancelAnimationFrame(frame)
  }, [showAtDefaultScale])

  useEffect(() => {
    const viewport = viewportRef.current
    if (!viewport) return
    let frame = 0
    const observer = new ResizeObserver(() => {
      window.cancelAnimationFrame(frame)
      frame = window.requestAnimationFrame(() => {
        const bounds = viewport.getBoundingClientRect()
        const nextSize = { width: Math.round(bounds.width), height: Math.round(bounds.height) }
        setViewportSize((current) => current.width === nextSize.width && current.height === nextSize.height ? current : nextSize)
      })
    })
    observer.observe(viewport)
    return () => {
      window.cancelAnimationFrame(frame)
      observer.disconnect()
    }
  }, [])

  useEffect(() => {
    function handleFullscreenChange() {
      setFullscreen(document.fullscreenElement === shellRef.current)
      window.requestAnimationFrame(() => window.requestAnimationFrame(showAtDefaultScale))
    }
    document.addEventListener('fullscreenchange', handleFullscreenChange)
    return () => document.removeEventListener('fullscreenchange', handleFullscreenChange)
  }, [showAtDefaultScale])

  async function toggleFullscreen() {
    const shell = shellRef.current
    if (!shell) return
    if (document.fullscreenElement === shell) await document.exitFullscreen()
    else await shell.requestFullscreen()
  }

  function zoomAt(nextScale: number, clientX?: number, clientY?: number) {
    const viewport = viewportRef.current
    if (!viewport) return
    const bounds = viewport.getBoundingClientRect()
    const anchorX = clientX === undefined ? bounds.width / 2 : clientX - bounds.left
    const anchorY = clientY === undefined ? bounds.height / 2 : clientY - bounds.top
    setTransform((current) => {
      const scale = clamp(nextScale, .02, 2.5)
      const worldX = (anchorX - current.x) / current.scale
      const worldY = (anchorY - current.y) / current.scale
      return { x: anchorX - worldX * scale, y: anchorY - worldY * scale, scale }
    })
  }

  function handleWheel(event: ReactWheelEvent<HTMLDivElement>) {
    event.preventDefault()
    zoomAt(transform.scale * (event.deltaY > 0 ? .9 : 1.1), event.clientX, event.clientY)
  }

  function startDrag(event: ReactPointerEvent<HTMLDivElement>) {
    if ((event.target as HTMLElement).closest('button')) return
    event.currentTarget.setPointerCapture(event.pointerId)
    dragRef.current = { pointerId: event.pointerId, clientX: event.clientX, clientY: event.clientY, originX: transform.x, originY: transform.y }
    event.currentTarget.classList.add('dragging')
  }

  function moveDrag(event: ReactPointerEvent<HTMLDivElement>) {
    const drag = dragRef.current
    if (!drag || drag.pointerId !== event.pointerId) return
    setTransform((current) => ({ ...current, x: drag.originX + event.clientX - drag.clientX, y: drag.originY + event.clientY - drag.clientY }))
  }

  function endDrag(event: ReactPointerEvent<HTMLDivElement>) {
    if (dragRef.current?.pointerId !== event.pointerId) return
    dragRef.current = undefined
    event.currentTarget.classList.remove('dragging')
    event.currentTarget.releasePointerCapture(event.pointerId)
  }

  return (
    <div className={`dag-shell${selectedPointId ? ' has-selection' : ''}`} ref={shellRef}>
      <div className="dag-toolbar" aria-label="图谱操作">
        <div className="dag-legend" aria-label="节点颜色说明"><span className="available">可学习</span><span className="path">学习路径</span><span className="target">当前目标</span></div>
        <div className="dag-zoom-controls"><button type="button" aria-label="缩小图谱" onClick={() => zoomAt(transform.scale / 1.18)}>−</button><span>{Math.round(transform.scale * 100)}%</span><button type="button" aria-label="放大图谱" onClick={() => zoomAt(transform.scale * 1.18)}>＋</button><button className="dag-fullscreen-button" type="button" aria-label={fullscreen ? '退出全屏' : '全屏显示知识图谱'} title={fullscreen ? '退出全屏' : '全屏'} aria-pressed={fullscreen} onClick={() => void toggleFullscreen()}><FullscreenIcon active={fullscreen} /></button><button type="button" onClick={fitGraph}>适应画布</button></div>
      </div>
      <div
        className="dag-viewport"
        ref={viewportRef}
        onDoubleClick={fitGraph}
        onPointerDown={startDrag}
        onPointerMove={moveDrag}
        onPointerUp={endDrag}
        onPointerCancel={endDrag}
        onWheel={handleWheel}
      >
        <div className="dag-canvas" style={{ width: layout.width, height: layout.height, transform: `translate(${transform.x}px, ${transform.y}px) scale(${transform.scale})` }}>
          <svg width={layout.width} height={layout.height} aria-hidden="true">
            <defs>
              <marker id="dag-arrow" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto"><path d="M0 0 8 4 0 8Z" /></marker>
              <marker id="dag-arrow-highlighted" className="highlighted" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto"><path d="M0 0 8 4 0 8Z" /></marker>
            </defs>
            {layout.edges.map((edge) => {
              const source = layout.nodeById.get(edge.fromPointId)
              const target = layout.nodeById.get(edge.toPointId)
              if (!source || !target) return null
              const startX = source.x + NODE_WIDTH
              const startY = source.y + NODE_HEIGHT / 2
              const endX = target.x
              const endY = target.y + NODE_HEIGHT / 2
              const bend = Math.max(48, (endX - startX) * .48)
              const highlighted = highlights.pathEdgeIds.has(edge.relationId)
              return <path className={highlighted ? 'highlighted' : ''} key={edge.relationId} d={`M${startX} ${startY} C${startX + bend} ${startY},${endX - bend} ${endY},${endX} ${endY}`} markerEnd={`url(#${highlighted ? 'dag-arrow-highlighted' : 'dag-arrow'})`} />
            })}
          </svg>
          {layout.nodes.map(({ point, x, y }) => {
            const selected = point.pointId === selectedPointId
            const completeTarget = selected && highlights.selectedComplete
            const state = completeTarget || highlights.availableIds.has(point.pointId) ? 'available' : selected ? 'target' : highlights.pathIds.has(point.pointId) ? 'path' : 'default'
            return <button
              className={`dag-node dag-node--${state}${selected ? ' selected' : ''}`}
              style={{ left: x, top: y, width: NODE_WIDTH, height: NODE_HEIGHT }}
              type="button"
              key={point.pointId}
              onPointerDown={(event) => event.stopPropagation()}
              onClick={() => onSelect(point.pointId)}
              aria-pressed={selected}
              aria-label={`${point.title}，掌握度 ${Math.round(point.mastery.score)}`}
              title={`${point.title} · 掌握度 ${Math.round(point.mastery.score)}`}
            ><span>{point.title}</span><small>掌握度 {Math.round(point.mastery.score)}</small></button>
          })}
        </div>
        {!points.length ? <p className="dag-empty">没有匹配的知识节点。</p> : null}
      </div>
    </div>
  )
}
