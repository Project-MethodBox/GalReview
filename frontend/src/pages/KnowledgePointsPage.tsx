import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router'
import AppShell, { PageHeader } from '../components/AppShell'
import { api } from '../lib/api'
import { readWorkflow } from '../lib/workflow'
import type { KnowledgePoint } from '../types/api'

type SortMode = 'mastery-asc' | 'mastery-desc' | 'title'

export default function KnowledgePointsPage() {
  const workflow = readWorkflow()
  const [points, setPoints] = useState<KnowledgePoint[]>([])
  const [loading, setLoading] = useState(Boolean(workflow.graph))
  const [error, setError] = useState('')
  const [search, setSearch] = useState('')
  const [chapterId, setChapterId] = useState('all')
  const [tag, setTag] = useState('all')
  const [sort, setSort] = useState<SortMode>('mastery-asc')
  const [expandedId, setExpandedId] = useState<string>()
  const [refreshVersion, setRefreshVersion] = useState(0)

  useEffect(() => {
    if (!workflow.graph) return
    let active = true
    setLoading(true)
    setError('')
    void Promise.allSettled([
      api.getAllPoints(workflow.graph.graphId),
      api.getAllMasteryRecords(workflow.graph.graphId),
    ]).then(([pointsResult, masteryResult]) => {
      if (!active) return
      if (pointsResult.status === 'rejected') throw pointsResult.reason
      const items = pointsResult.value
      const masteryRecords = masteryResult.status === 'fulfilled' ? masteryResult.value : []
      const masteryByPoint = new Map(masteryRecords.map((record) => [record.pointId, record]))
      setPoints(items.map((point) => ({ ...point, mastery: masteryByPoint.get(point.pointId) || point.mastery })))
    }).catch((reason: unknown) => {
      if (active) setError(reason instanceof Error ? reason.message : '知识点读取失败。')
    }).finally(() => {
      if (active) setLoading(false)
    })
    return () => { active = false }
  }, [refreshVersion, workflow.graph?.graphId])

  async function toggleDetails(point: KnowledgePoint) {
    if (expandedId === point.pointId) {
      setExpandedId(undefined)
      return
    }
    setExpandedId(point.pointId)
    try {
      const detail = await api.getKnowledgePoint(point.pointId)
      setPoints((current) => current.map((item) => item.pointId === detail.pointId ? detail : item))
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '知识点详情读取失败。')
    }
  }

  const chapterTitle = useMemo(() => new Map((workflow.chapters || []).map((chapter) => [chapter.chapterId, chapter.title])), [workflow.chapters])
  const tags = useMemo(() => Array.from(new Set(points.flatMap((point) => point.tags))).sort((left, right) => left.localeCompare(right, 'zh-CN')), [points])
  const visiblePoints = useMemo(() => {
    const keyword = search.trim().toLowerCase()
    return points.filter((point) => {
      const matchesSearch = !keyword || `${point.title} ${point.summary} ${point.tags.join(' ')}`.toLowerCase().includes(keyword)
      return matchesSearch && (chapterId === 'all' || point.chapterId === chapterId) && (tag === 'all' || point.tags.includes(tag))
    }).sort((left, right) => {
      if (sort === 'title') return left.title.localeCompare(right.title, 'zh-CN')
      return sort === 'mastery-asc' ? left.mastery.score - right.mastery.score : right.mastery.score - left.mastery.score
    })
  }, [chapterId, points, search, sort, tag])

  const statistics = useMemo(() => {
    const averageMastery = points.length ? Math.round(points.reduce((sum, point) => sum + point.mastery.score, 0) / points.length) : 0
    const dueCount = points.filter((point) => new Date(point.mastery.nextReviewAt).getTime() <= Date.now()).length
    return { averageMastery, dueCount }
  }, [points])

  return (
    <AppShell>
      <main className="page knowledge-page">
        <PageHeader title="知识点" description="按章节、标签和掌握度查找需要复习的内容。" actions={<><button className="button" type="button" disabled={loading} onClick={() => setRefreshVersion((value) => value + 1)}>刷新掌握度</button><Link className="button" to="/knowledge-graph">查看图谱</Link></>} />
        {!workflow.graph ? <section className="empty-state"><h2>还没有知识点</h2><p>上传并处理一份资料后，知识点会按章节显示在这里。</p><Link className="button button--primary" to="/materials">上传资料</Link></section> : <>
          <section className="data-strip" aria-label="知识点概况">
            <div><span>知识点</span><strong>{points.length || workflow.graph.pointCount}</strong></div>
            <div><span>平均掌握度</span><strong>{statistics.averageMastery}</strong></div>
            <div><span>待复习</span><strong>{statistics.dueCount}</strong></div>
          </section>
          {error ? <p className="status-line status-line--error" role="alert">{error}</p> : null}
          <div className="knowledge-layout">
            <aside className="filter-panel" aria-label="筛选知识点">
              <label>搜索<input type="search" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="标题、摘要或标签" /></label>
              <label>章节<select value={chapterId} onChange={(event) => setChapterId(event.target.value)}><option value="all">全部章节</option>{(workflow.chapters || []).map((chapter) => <option key={chapter.chapterId} value={chapter.chapterId}>{chapter.title}</option>)}</select></label>
              <label>标签<select value={tag} onChange={(event) => setTag(event.target.value)}><option value="all">全部标签</option>{tags.map((item) => <option key={item} value={item}>{item}</option>)}</select></label>
              <label>排序<select value={sort} onChange={(event) => setSort(event.target.value as SortMode)}><option value="mastery-asc">掌握度从低到高</option><option value="mastery-desc">掌握度从高到低</option><option value="title">按标题</option></select></label>
              <p>显示 {visiblePoints.length} / {points.length}</p>
            </aside>
            <section className="knowledge-list" aria-label="知识点列表">
              {loading ? <p className="empty-row" role="status">正在读取知识点…</p> : visiblePoints.map((point) => {
                const expanded = expandedId === point.pointId
                return <article key={point.pointId} className={expanded ? 'expanded' : ''}>
                  <button type="button" aria-expanded={expanded} onClick={() => void toggleDetails(point)}>
                    <span className="mastery-value">{Math.round(point.mastery.score)}</span>
                    <span className="point-copy"><small>{chapterTitle.get(point.chapterId) || point.subjectCode}</small><strong>{point.title}</strong><em>{point.tags.join(' · ') || '无标签'}</em></span>
                    <span className="row-action">{expanded ? '收起' : '查看'}</span>
                  </button>
                  {expanded ? <div className="point-detail"><p>{point.summary}</p><dl><div><dt>置信度</dt><dd>{Math.round(point.confidence * 100)}%</dd></div><div><dt>复习次数</dt><dd>{point.mastery.repetitions}</dd></div><div><dt>下次复习</dt><dd>{new Date(point.mastery.nextReviewAt).toLocaleDateString('zh-CN')}</dd></div></dl>{point.sourceReferences?.length ? <div className="source-references"><h3>资料出处</h3>{point.sourceReferences.map((source, index) => <blockquote key={`${source.location}-${index}`}><span>{source.location}</span><p>{source.quote || `文本位置 ${source.startOffset}–${source.endOffset}`}</p></blockquote>)}</div> : null}</div> : null}
                </article>
              })}
              {!loading && !visiblePoints.length ? <p className="empty-row">没有匹配的知识点。</p> : null}
            </section>
          </div>
        </>}
      </main>
    </AppShell>
  )
}
