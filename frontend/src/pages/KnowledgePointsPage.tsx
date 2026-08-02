import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router'
import { api } from '../lib/api'
import { readWorkflow } from '../lib/workflow'
import type { KnowledgePoint } from '../types/api'

export default function KnowledgePointsPage() {
  const workflow = readWorkflow()
  const [points, setPoints] = useState<KnowledgePoint[]>([])
  const [loading, setLoading] = useState(Boolean(workflow.graph))
  const [error, setError] = useState('')

  useEffect(() => {
    if (!workflow.graph) return
    let active = true
    setLoading(true)
    setError('')
    void api.getAllPoints(workflow.graph.graphId).then((items) => {
      if (active) setPoints(items)
    }).catch((reason: unknown) => {
      if (active) setError(reason instanceof Error ? reason.message : '知识点读取失败。')
    }).finally(() => {
      if (active) setLoading(false)
    })
    return () => { active = false }
  }, [workflow.graph?.graphId])

  const statistics = useMemo(() => {
    const averageMastery = points.length
      ? Math.round(points.reduce((sum, point) => sum + point.mastery.score, 0) / points.length)
      : 0
    const tagCount = new Set(points.flatMap((point) => point.tags)).size
    return { averageMastery, tagCount }
  }, [points])

  if (!workflow.graph) {
    return <main className="empty-workspace"><h1>还没有知识点</h1><p>先上传一份资料，系统会按章节提取其中的知识。</p><Link to="/materials">上传资料</Link></main>
  }

  return (
    <main className="workspace-page">
      <header className="workspace-header">
        <div><p>{workflow.graph.subjectCode}</p><h1>知识点</h1></div>
        <nav><Link to="/home">返回主页</Link><Link to="/knowledge-graph">查看图谱</Link></nav>
      </header>
      {error ? <p className="error-banner">{error}</p> : null}
      <section className="graph-summary" aria-label="知识点概览">
        <span><strong>{workflow.graph.pointCount}</strong>知识点</span>
        <span><strong>{statistics.averageMastery}</strong>平均掌握度</span>
        <span><strong>{statistics.tagCount}</strong>标签</span>
      </section>
      {loading ? <p className="workspace-loading" role="status">正在读取全部知识点…</p> : null}
      {!loading && !error ? (
        <section className="knowledge-points-grid" aria-label="知识点列表">
          {points.map((point) => (
            <article className="workspace-card knowledge-point-card" key={point.pointId}>
              <span>{point.tags.join(' / ') || '未标注'}</span>
              <h2>{point.title}</h2>
              <p>{point.summary}</p>
              <footer><strong>{Math.round(point.mastery.score)}</strong><small>掌握度</small></footer>
            </article>
          ))}
        </section>
      ) : null}
    </main>
  )
}
