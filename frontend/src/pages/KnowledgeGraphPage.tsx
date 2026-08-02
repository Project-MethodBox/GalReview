import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router'
import AppShell, { PageHeader } from '../components/AppShell'
import { api } from '../lib/api'
import { readWorkflow } from '../lib/workflow'
import type { Chapter, KnowledgePoint, KnowledgeRelation, RelationType } from '../types/api'

const relationText: Record<RelationType, string> = { PREREQUISITE: '前置', RELATED: '相关', CONTRASTS: '对照' }

export default function KnowledgeGraphPage() {
  const workflow = readWorkflow()
  const [chapters, setChapters] = useState<Chapter[]>(workflow.chapters || [])
  const [points, setPoints] = useState<KnowledgePoint[]>([])
  const [relations, setRelations] = useState<KnowledgeRelation[]>([])
  const [loading, setLoading] = useState(Boolean(workflow.graph))
  const [error, setError] = useState('')
  const [search, setSearch] = useState('')
  const [chapterId, setChapterId] = useState('all')
  const [relationType, setRelationType] = useState<'all' | RelationType>('all')
  const [selectedPointId, setSelectedPointId] = useState<string>()

  useEffect(() => {
    if (!workflow.graph) return
    let active = true
    setLoading(true)
    setError('')
    void Promise.all([api.getChapters(workflow.graph.graphId), api.getAllPoints(workflow.graph.graphId), api.getAllRelations(workflow.graph.graphId)]).then(([chapterList, pointList, relationList]) => {
      if (!active) return
      setChapters(chapterList); setPoints(pointList); setRelations(relationList); setSelectedPointId(pointList[0]?.pointId)
    }).catch((reason: unknown) => {
      if (active) setError(reason instanceof Error ? reason.message : '图谱读取失败。')
    }).finally(() => { if (active) setLoading(false) })
    return () => { active = false }
  }, [workflow.graph?.graphId])

  const pointById = useMemo(() => new Map(points.map((point) => [point.pointId, point])), [points])
  const visiblePoints = useMemo(() => {
    const keyword = search.trim().toLowerCase()
    return points.filter((point) => (chapterId === 'all' || point.chapterId === chapterId) && (!keyword || `${point.title} ${point.summary}`.toLowerCase().includes(keyword)))
  }, [chapterId, points, search])
  const selectedPoint = selectedPointId ? pointById.get(selectedPointId) : undefined
  const relevantRelations = useMemo(() => relations.filter((relation) => {
    const matchesPoint = !selectedPointId || relation.fromPointId === selectedPointId || relation.toPointId === selectedPointId
    return matchesPoint && (relationType === 'all' || relation.type === relationType)
  }), [relationType, relations, selectedPointId])

  return (
    <AppShell>
      <main className="page graph-page">
        <PageHeader title="知识图谱" description={workflow.material?.displayName || '检查章节结构与知识关系。'} actions={<Link className="button" to="/materials">创建计划</Link>} />
        {!workflow.graph ? <section className="empty-state"><h2>还没有知识图谱</h2><p>处理资料后，章节、知识点和关系会显示在这里。</p><Link className="button button--primary" to="/materials">上传资料</Link></section> : <>
          <section className="data-strip" aria-label="图谱概况"><div><span>章节</span><strong>{chapters.length || workflow.graph.chapterCount}</strong></div><div><span>知识点</span><strong>{points.length || workflow.graph.pointCount}</strong></div><div><span>关系</span><strong>{relations.length || workflow.graph.relationCount}</strong></div></section>
          {error ? <p className="status-line status-line--error" role="alert">{error}</p> : null}
          <div className="graph-workbench">
            <aside className="chapter-outline">
              <header><h2>章节</h2><button className={chapterId === 'all' ? 'active' : ''} type="button" onClick={() => setChapterId('all')}>全部</button></header>
              <nav>{chapters.map((chapter) => <button className={chapterId === chapter.chapterId ? 'active' : ''} style={{ paddingLeft: `${14 + chapter.depth * 14}px` }} key={chapter.chapterId} type="button" onClick={() => setChapterId(chapter.chapterId)}>{chapter.title}</button>)}</nav>
            </aside>
            <section className="graph-board">
              <header><div><h2>知识节点</h2><p>{visiblePoints.length} 个结果</p></div><input type="search" aria-label="搜索知识节点" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="搜索知识点" /></header>
              {loading ? <p className="empty-row" role="status">正在读取完整图谱…</p> : <div className="node-list">{visiblePoints.map((point) => <button className={selectedPointId === point.pointId ? 'active' : ''} type="button" key={point.pointId} onClick={() => setSelectedPointId(point.pointId)}><span>{Math.round(point.mastery.score)}</span><strong>{point.title}</strong><small>{point.tags.slice(0, 2).join(' · ') || '无标签'}</small></button>)}</div>}
              {!loading && !visiblePoints.length ? <p className="empty-row">没有匹配的节点。</p> : null}
            </section>
            <aside className="graph-inspector">
              <header><h2>节点详情</h2></header>
              {selectedPoint ? <><span className="inspector-score">掌握度 {Math.round(selectedPoint.mastery.score)}</span><h3>{selectedPoint.title}</h3><p>{selectedPoint.summary}</p><div className="relation-filter" aria-label="关系类型"><button className={relationType === 'all' ? 'active' : ''} type="button" onClick={() => setRelationType('all')}>全部</button>{(Object.keys(relationText) as RelationType[]).map((type) => <button className={relationType === type ? 'active' : ''} type="button" key={type} onClick={() => setRelationType(type)}>{relationText[type]}</button>)}</div><div className="relation-rows">{relevantRelations.map((relation) => { const outbound = relation.fromPointId === selectedPoint.pointId; const other = pointById.get(outbound ? relation.toPointId : relation.fromPointId); return <button type="button" key={relation.relationId} onClick={() => other && setSelectedPointId(other.pointId)}><span>{outbound ? '→' : '←'} {relationText[relation.type]}</span><strong>{other?.title || '未知知识点'}</strong><small>{relation.rationale}</small></button> })}{!relevantRelations.length ? <p>当前筛选下没有关系。</p> : null}</div></> : <p>选择一个知识节点查看详情。</p>}
            </aside>
          </div>
        </>}
      </main>
    </AppShell>
  )
}
