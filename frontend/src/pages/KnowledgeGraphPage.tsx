import { useEffect, useState } from 'react'
import { Link } from 'react-router'
import { api } from '../lib/api'
import { readWorkflow } from '../lib/workflow'
import type { Chapter, KnowledgePoint, KnowledgeRelation } from '../types/api'

export default function KnowledgeGraphPage() {
  const workflow = readWorkflow()
  const [chapters, setChapters] = useState<Chapter[]>(workflow.chapters || [])
  const [points, setPoints] = useState<KnowledgePoint[]>([])
  const [relations, setRelations] = useState<KnowledgeRelation[]>([])
  const [loading, setLoading] = useState(Boolean(workflow.graph))
  const [error, setError] = useState('')

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
    }).catch((reason: unknown) => {
      if (active) setError(reason instanceof Error ? reason.message : '图谱读取失败。')
    }).finally(() => {
      if (active) setLoading(false)
    })
    return () => { active = false }
  }, [workflow.graph?.graphId])

  if (!workflow.graph) {
    return <main className="empty-workspace"><h1>还没有知识图谱</h1><p>先上传一份资料，系统会按章节整理其中的知识。</p><Link to="/materials">上传资料</Link></main>
  }

  const pointTitle = new Map(points.map((point) => [point.pointId, point.title]))
  return (
    <main className="workspace-page">
      <header className="workspace-header">
        <div><p>{workflow.graph.subjectCode}</p><h1>{workflow.material?.displayName || '知识图谱'}</h1></div>
        <nav><Link to="/home">返回主页</Link><Link to="/materials">创建计划</Link></nav>
      </header>
      {error ? <p className="error-banner">{error}</p> : null}
      {loading ? <p className="workspace-loading" role="status">正在读取完整图谱…</p> : null}
      <section className="graph-summary">
        <span><strong>{workflow.graph.chapterCount}</strong>章节</span>
        <span><strong>{workflow.graph.pointCount}</strong>知识点</span>
        <span><strong>{workflow.graph.relationCount}</strong>关系</span>
      </section>
      <div className="graph-columns">
        <section className="workspace-card"><h2>章节</h2>{chapters.map((chapter) => <p key={chapter.chapterId} style={{ paddingLeft: `${chapter.depth * 18}px` }}>{chapter.title}</p>)}</section>
        <section className="workspace-card point-list"><h2>知识点</h2>{points.map((point) => <article key={point.pointId}><h3>{point.title}</h3><p>{point.summary}</p><small>掌握度 {Math.round(point.mastery.score)} · {point.tags.join(' / ') || '未标注'}</small></article>)}</section>
        <section className="workspace-card relation-list"><h2>依赖与关联</h2>{relations.map((relation) => <p key={relation.relationId}><span>{pointTitle.get(relation.fromPointId) || relation.fromPointId}</span><b>{relation.type}</b><span>{pointTitle.get(relation.toPointId) || relation.toPointId}</span></p>)}</section>
      </div>
    </main>
  )
}
