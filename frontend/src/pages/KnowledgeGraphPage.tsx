import { lazy, Suspense, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router'
import AppShell, { PageHeader } from '../components/AppShell'
import LoadingIndicator from '../components/LoadingIndicator'
import { api } from '../lib/api'
import { readWorkflow, updateWorkflow } from '../lib/workflow'
import type { Chapter, KnowledgeGraphSummary, KnowledgePoint, KnowledgeRelation } from '../types/api'

const KnowledgeDag = lazy(() => import('../components/KnowledgeDag'))

const relationText = { PREREQUISITE: '前置', RELATED: '相关', CONTRASTS: '对照' } as const
type RelationFilter = 'all' | 'prerequisite' | 'related'

function findChapterRoot(points: KnowledgePoint[], relations: KnowledgeRelation[], chapterId: string) {
  const chapterPoints = points.filter((point) => point.chapterId === chapterId)
  if (!chapterPoints.length) return undefined

  const pointIds = new Set(chapterPoints.map((point) => point.pointId))
  const incomingIds = new Set<string>()
  const outgoing = new Map<string, string[]>()
  for (const relation of relations) {
    if (relation.type !== 'PREREQUISITE' || !pointIds.has(relation.fromPointId) || !pointIds.has(relation.toPointId)) continue
    incomingIds.add(relation.toPointId)
    outgoing.set(relation.fromPointId, [...(outgoing.get(relation.fromPointId) || []), relation.toPointId])
  }

  const roots = chapterPoints.filter((point) => !incomingIds.has(point.pointId))
  const candidates = roots.length ? roots : chapterPoints
  const reachableCount = (rootId: string) => {
    const visited = new Set<string>([rootId])
    const pending = [rootId]
    while (pending.length) {
      const currentId = pending.pop()!
      for (const nextId of outgoing.get(currentId) || []) {
        if (visited.has(nextId)) continue
        visited.add(nextId)
        pending.push(nextId)
      }
    }
    return visited.size
  }

  return [...candidates].sort((left, right) => reachableCount(right.pointId) - reachableCount(left.pointId)
    || (left.sourceReferences[0]?.startOffset ?? Number.MAX_SAFE_INTEGER) - (right.sourceReferences[0]?.startOffset ?? Number.MAX_SAFE_INTEGER)
    || left.title.localeCompare(right.title, 'zh-CN'))[0]
}

export default function KnowledgeGraphPage() {
  const workflow = readWorkflow()
  const [graph, setGraph] = useState<KnowledgeGraphSummary | undefined>(workflow.graph)
  const [graphVersions, setGraphVersions] = useState<KnowledgeGraphSummary[]>(workflow.graph ? [workflow.graph] : [])
  const [chapters, setChapters] = useState<Chapter[]>(workflow.chapters || [])
  const [points, setPoints] = useState<KnowledgePoint[]>([])
  const [relations, setRelations] = useState<KnowledgeRelation[]>([])
  const [loading, setLoading] = useState(Boolean(graph))
  const [error, setError] = useState('')
  const [search, setSearch] = useState('')
  const [chapterId, setChapterId] = useState('all')
  const [relationFilter, setRelationFilter] = useState<RelationFilter>('all')
  const [selectedPointId, setSelectedPointId] = useState<string>()
  const [showAllRelations, setShowAllRelations] = useState(false)
  const [inspectorCollapsed, setInspectorCollapsed] = useState(false)

  useEffect(() => {
    if (!workflow.material) return
    let active = true
    void api.getAllKnowledgeGraphs(workflow.material.materialId).then((items) => {
      if (active) setGraphVersions(items.filter((item) => item.status !== 'DRAFT').sort((left, right) => right.version - left.version))
    }).catch(() => undefined)
    return () => { active = false }
  }, [workflow.material?.materialId])

  useEffect(() => {
    if (!graph) return
    let active = true
    setLoading(true)
    setError('')
    void Promise.all([
      api.getChapters(graph.graphId),
      api.getAllPoints(graph.graphId),
      api.getAllRelations(graph.graphId),
    ]).then(([chapterList, pointList, relationList]) => {
      if (!active) return
      setChapters(chapterList)
      setPoints(pointList)
      setRelations(relationList)
      setSelectedPointId(pointList[0]?.pointId)
      updateWorkflow({ graph, chapters: chapterList })
    }).catch((reason: unknown) => {
      if (active) setError(reason instanceof Error ? reason.message : '图谱读取失败。')
    }).finally(() => {
      if (active) setLoading(false)
    })
    return () => { active = false }
  }, [graph?.graphId])

  async function switchGraph(graphId: string) {
    const nextGraph = graphVersions.find((item) => item.graphId === graphId)
    if (!nextGraph || nextGraph.graphId === graph?.graphId) return
    setGraph(nextGraph)
    setChapters([])
    setPoints([])
    setRelations([])
    setChapterId('all')
    setShowAllRelations(false)
    setSelectedPointId(undefined)
    updateWorkflow({
      graph: nextGraph,
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

  const sortedChapters = useMemo(() => [...chapters].sort((a, b) => b.depth - a.depth || a.ordinal - b.ordinal || a.title.localeCompare(b.title, 'zh-CN')), [chapters])
  const pointById = useMemo(() => new Map(points.map((point) => [point.pointId, point])), [points])
  const visiblePoints = useMemo(() => {
    const keyword = search.trim().toLowerCase()
    return points.filter((point) => (chapterId === 'all' || point.chapterId === chapterId) && (!keyword || `${point.title} ${point.summary}`.toLowerCase().includes(keyword)))
  }, [chapterId, points, search])
  const visiblePointIds = useMemo(() => new Set(visiblePoints.map((point) => point.pointId)), [visiblePoints])
  const visibleRelations = useMemo(() => relations.filter((relation) => visiblePointIds.has(relation.fromPointId) && visiblePointIds.has(relation.toPointId)), [relations, visiblePointIds])
  const graphMode = chapterId === 'all' && !search.trim() ? (showAllRelations ? 'all' : 'overview') : 'detail'
  const selectedPoint = selectedPointId ? pointById.get(selectedPointId) : undefined
  const relevantRelations = useMemo(() => relations.filter((relation) => {
    const matchesPoint = Boolean(selectedPointId) && (relation.fromPointId === selectedPointId || relation.toPointId === selectedPointId)
    if (!matchesPoint) return false
    if (relationFilter === 'prerequisite') return relation.type === 'PREREQUISITE'
    if (relationFilter === 'related') return relation.type !== 'PREREQUISITE'
    return true
  }), [relationFilter, relations, selectedPointId])

  useEffect(() => {
    if (loading) return
    if (!visiblePoints.length) {
      if (selectedPointId) setSelectedPointId(undefined)
      return
    }
    if (!selectedPointId || !visiblePointIds.has(selectedPointId)) setSelectedPointId(visiblePoints[0].pointId)
  }, [loading, selectedPointId, visiblePointIds, visiblePoints])

  function selectChapter(nextChapterId: string) {
    setChapterId(nextChapterId)
    setSearch('')
    if (nextChapterId !== 'all') setShowAllRelations(false)
    const nextPoint = nextChapterId === 'all'
      ? points[0]
      : findChapterRoot(points, relations, nextChapterId)
    if (nextPoint) setSelectedPointId(nextPoint.pointId)
  }

  function toggleGraphView() {
    setChapterId('all')
    setSearch('')
    setShowAllRelations((current) => !current)
  }

  function revealAndSelect(pointId: string) {
    setChapterId('all')
    setSearch('')
    setSelectedPointId(pointId)
  }

  return (
    <AppShell>
      <main className="page graph-page">
        <PageHeader title="识网" description={workflow.material?.displayName} actions={<>{graphVersions.length > 1 ? <label className="graph-version-control"><span>图谱版本</span><select value={graph?.graphId || ''} onChange={(event) => void switchGraph(event.target.value)}>{graphVersions.map((item) => <option key={item.graphId} value={item.graphId}>v{item.version} · {item.status}</option>)}</select></label> : null}<Link className="button graph-create-plan-button" to="/materials">创建计划</Link></>} />
        {!graph ? <section className="empty-state"><h2>还没有知识图谱</h2><Link className="button button--primary" to="/materials">上传资料</Link></section> : <>
          <section className="data-strip" aria-label="图谱概况"><div><span>章节</span><strong>{chapters.length || graph.chapterCount}</strong></div><div><span>知识点</span><strong>{points.length || graph.pointCount}</strong></div><div><span>关系</span><strong>{relations.length || graph.relationCount}</strong></div></section>
          {error ? <p className="status-line status-line--error" role="alert">{error}</p> : null}
          <div className={`graph-workbench${inspectorCollapsed ? ' graph-workbench--inspector-collapsed' : ''}`}>
            <aside className="chapter-outline">
              <header><div><h2>章节</h2><p>按层级深度排列</p></div><button className={chapterId === 'all' ? 'active' : ''} type="button" onClick={() => selectChapter('all')}>全部</button></header>
              <nav>{sortedChapters.map((chapter) => <button className={chapterId === chapter.chapterId ? 'active' : ''} key={chapter.chapterId} type="button" onClick={() => selectChapter(chapter.chapterId)}><span>{chapter.title}</span><small>深度 {chapter.depth}</small></button>)}</nav>
            </aside>
            <section className="graph-board">
              <header><div><h2>知识路径</h2><p>{graphMode === 'overview' ? `${chapters.length} 个章节 · 点击章节查看详细路径` : graphMode === 'all' ? `${visiblePoints.length} 个节点 · ${visibleRelations.length} 条关系` : `${visiblePoints.length} 个节点 · 拖动画布，滚轮缩放`}</p></div><div className="graph-board-view-tools"><div className={`graph-view-switch graph-view-switch--${showAllRelations ? 'relations' : 'overview'}`} aria-label="图谱视图"><button className={!showAllRelations ? 'active' : ''} type="button" aria-pressed={!showAllRelations} onClick={toggleGraphView}>章节概览</button><button className={showAllRelations ? 'active' : ''} type="button" aria-pressed={showAllRelations} onClick={toggleGraphView}>全部关系</button></div><input type="search" aria-label="搜索知识节点" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="搜索知识点" /></div></header>
              {loading ? <LoadingIndicator label="正在读取完整图谱…" /> : <Suspense fallback={<LoadingIndicator label="正在加载图谱引擎…" />}><KnowledgeDag points={visiblePoints} relations={visibleRelations} chapters={chapters} mode={graphMode} selectedPointId={selectedPointId} onSelect={setSelectedPointId} onSelectChapter={selectChapter} /></Suspense>}
            </section>
            <aside className="graph-inspector">
              <header className="graph-inspector__header"><h2>节点详情</h2><button className="graph-inspector__toggle" type="button" aria-label={inspectorCollapsed ? '展开节点详情' : '收起节点详情'} title={inspectorCollapsed ? '展开节点详情' : '收起节点详情'} aria-expanded={!inspectorCollapsed} onClick={() => setInspectorCollapsed((current) => !current)}><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m9 6 6 6-6 6" /></svg></button></header>
              <div className="graph-inspector__content" aria-hidden={inspectorCollapsed}>
              {selectedPoint ? <>
                <span className="inspector-score">掌握度 {Math.round(selectedPoint.mastery.score)}</span>
                <h3>{selectedPoint.title}</h3>
                <p>{selectedPoint.summary}</p>
                <div className={`relation-filter relation-filter--${relationFilter}`} aria-label="关系类型">
                  <button className={`relation-filter__button relation-filter__button--all${relationFilter === 'all' ? ' is-active' : ''}`} type="button" onClick={() => setRelationFilter('all')}>全部</button>
                  <button className={`relation-filter__button relation-filter__button--prerequisite${relationFilter === 'prerequisite' ? ' is-active' : ''}`} type="button" onClick={() => setRelationFilter('prerequisite')}>前置</button>
                  <button className={`relation-filter__button relation-filter__button--related${relationFilter === 'related' ? ' is-active' : ''}`} type="button" onClick={() => setRelationFilter('related')}>相关</button>
                </div>
                <div className="relation-rows">{relevantRelations.map((relation) => {
                  const outbound = relation.fromPointId === selectedPoint.pointId
                  const other = pointById.get(outbound ? relation.toPointId : relation.fromPointId)
                  return <button type="button" key={relation.relationId} onClick={() => other && revealAndSelect(other.pointId)}><span>{outbound ? '→' : '←'} {relationText[relation.type]}</span><span className="relation-copy"><strong>{other?.title || '未知知识点'}</strong><small>{relation.rationale}</small></span></button>
                })}{!relevantRelations.length ? <p>当前筛选下没有关系。</p> : null}</div>
              </> : <p>选择一个知识节点查看详情。</p>}
              </div>
            </aside>
          </div>
        </>}
      </main>
    </AppShell>
  )
}
