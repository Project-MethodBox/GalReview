import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router'
import AppShell, { PageHeader } from '../components/AppShell'
import KnowledgeDag from '../components/KnowledgeDag'
import { api } from '../lib/api'
import { readWorkflow } from '../lib/workflow'
import type { Chapter, KnowledgePoint, KnowledgeRelation } from '../types/api'

const relationText = { PREREQUISITE: '前置', RELATED: '相关', CONTRASTS: '对照' } as const
type RelationFilter = 'all' | 'prerequisite' | 'related'

export default function KnowledgeGraphPage() {
  const workflow = readWorkflow()
  const [chapters, setChapters] = useState<Chapter[]>(workflow.chapters || [])
  const [points, setPoints] = useState<KnowledgePoint[]>([])
  const [relations, setRelations] = useState<KnowledgeRelation[]>([])
  const [loading, setLoading] = useState(Boolean(workflow.graph))
  const [error, setError] = useState('')
  const [search, setSearch] = useState('')
  const [chapterId, setChapterId] = useState('all')
  const [relationFilter, setRelationFilter] = useState<RelationFilter>('all')
  const [selectedPointId, setSelectedPointId] = useState<string>()

  useEffect(() => {
    if (!workflow.graph) return
    let active = true
    setLoading(true)
    setError('')
    void Promise.all([
      api.getChapters(workflow.graph.graphId),
      api.getAllPoints(workflow.graph.graphId),
      api.getAllRelations(workflow.graph.graphId),
    ]).then(([chapterList, pointList, relationList]) => {
      if (!active) return
      setChapters(chapterList)
      setPoints(pointList)
      setRelations(relationList)
      setSelectedPointId(pointList[0]?.pointId)
    }).catch((reason: unknown) => {
      if (active) setError(reason instanceof Error ? reason.message : '图谱读取失败。')
    }).finally(() => {
      if (active) setLoading(false)
    })
    return () => { active = false }
  }, [workflow.graph?.graphId])

  const sortedChapters = useMemo(() => [...chapters].sort((a, b) => b.depth - a.depth || a.ordinal - b.ordinal || a.title.localeCompare(b.title, 'zh-CN')), [chapters])
  const pointById = useMemo(() => new Map(points.map((point) => [point.pointId, point])), [points])
  const visiblePoints = useMemo(() => {
    const keyword = search.trim().toLowerCase()
    return points.filter((point) => (chapterId === 'all' || point.chapterId === chapterId) && (!keyword || `${point.title} ${point.summary}`.toLowerCase().includes(keyword)))
  }, [chapterId, points, search])
  const visiblePointIds = useMemo(() => new Set(visiblePoints.map((point) => point.pointId)), [visiblePoints])
  const visibleRelations = useMemo(() => relations.filter((relation) => visiblePointIds.has(relation.fromPointId) && visiblePointIds.has(relation.toPointId)), [relations, visiblePointIds])
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
    const nextPoint = points.find((point) => nextChapterId === 'all' || point.chapterId === nextChapterId)
    if (nextPoint) setSelectedPointId(nextPoint.pointId)
  }

  function revealAndSelect(pointId: string) {
    setChapterId('all')
    setSearch('')
    setSelectedPointId(pointId)
  }

  return (
    <AppShell>
      <main className="page graph-page">
        <PageHeader title="知识图谱" description={workflow.material?.displayName || '查看知识点之间的先修路径和关联。'} actions={<Link className="button" to="/materials">创建计划</Link>} />
        {!workflow.graph ? <section className="empty-state"><h2>还没有知识图谱</h2><p>处理资料后，章节、知识点和关系会显示在这里。</p><Link className="button button--primary" to="/materials">上传资料</Link></section> : <>
          <section className="data-strip" aria-label="图谱概况"><div><span>章节</span><strong>{chapters.length || workflow.graph.chapterCount}</strong></div><div><span>知识点</span><strong>{points.length || workflow.graph.pointCount}</strong></div><div><span>关系</span><strong>{relations.length || workflow.graph.relationCount}</strong></div></section>
          {error ? <p className="status-line status-line--error" role="alert">{error}</p> : null}
          <div className="graph-workbench">
            <aside className="chapter-outline">
              <header><div><h2>章节</h2><p>按层级深度排列</p></div><button className={chapterId === 'all' ? 'active' : ''} type="button" onClick={() => selectChapter('all')}>全部</button></header>
              <nav>{sortedChapters.map((chapter) => <button className={chapterId === chapter.chapterId ? 'active' : ''} key={chapter.chapterId} type="button" onClick={() => selectChapter(chapter.chapterId)}><span>{chapter.title}</span><small>深度 {chapter.depth}</small></button>)}</nav>
            </aside>
            <section className="graph-board">
              <header><div><h2>知识路径</h2><p>{visiblePoints.length} 个节点 · 拖动画布，滚轮缩放</p></div><input type="search" aria-label="搜索知识节点" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="搜索知识点" /></header>
              {loading ? <p className="empty-row" role="status">正在读取完整图谱…</p> : <KnowledgeDag points={visiblePoints} relations={visibleRelations} selectedPointId={selectedPointId} onSelect={setSelectedPointId} />}
            </section>
            <aside className="graph-inspector">
              <header><h2>节点详情</h2></header>
              {selectedPoint ? <>
                <span className="inspector-score">掌握度 {Math.round(selectedPoint.mastery.score)}</span>
                <h3>{selectedPoint.title}</h3>
                <p>{selectedPoint.summary}</p>
                <div className="relation-filter" aria-label="关系类型">
                  <button className={relationFilter === 'all' ? 'active' : ''} type="button" onClick={() => setRelationFilter('all')}>全部</button>
                  <button className={relationFilter === 'prerequisite' ? 'active' : ''} type="button" onClick={() => setRelationFilter('prerequisite')}>前置</button>
                  <button className={relationFilter === 'related' ? 'active' : ''} type="button" onClick={() => setRelationFilter('related')}>相关</button>
                </div>
                <div className="relation-rows">{relevantRelations.map((relation) => {
                  const outbound = relation.fromPointId === selectedPoint.pointId
                  const other = pointById.get(outbound ? relation.toPointId : relation.fromPointId)
                  return <button type="button" key={relation.relationId} onClick={() => other && revealAndSelect(other.pointId)}><span>{outbound ? '→' : '←'} {relationText[relation.type]}</span><span className="relation-copy"><strong>{other?.title || '未知知识点'}</strong><small>{relation.rationale}</small></span></button>
                })}{!relevantRelations.length ? <p>当前筛选下没有关系。</p> : null}</div>
              </> : <p>选择一个知识节点查看详情。</p>}
            </aside>
          </div>
        </>}
      </main>
    </AppShell>
  )
}
