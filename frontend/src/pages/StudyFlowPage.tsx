import { useEffect, useMemo, useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router'
import AppShell, { PageHeader } from '../components/AppShell'
import { api, ApiClientError } from '../lib/api'
import { pollUntil } from '../lib/poll'
import { readWorkflow, resetWorkflow, updateWorkflow } from '../lib/workflow'
import { newestGraph } from '../lib/workflowRecovery'
import type { Chapter, IngestionJob, KnowledgeGraphSummary, Material, PlanGraph, ReviewPlanType } from '../types/api'

const MAX_FILE_BYTES = 10 * 1024 * 1024

function jobError(error: { message: string } | null, fallback: string): Error {
  return new Error(error?.message || fallback)
}

function ingestionText(job: IngestionJob) {
  if (job.ocrProgress) return `OCR ${job.ocrProgress.currentPage}/${job.ocrProgress.totalPages} 页 · ${job.ocrProgress.phase}`
  return `正在提取文字 · ${job.progress}%`
}

export default function StudyFlowPage() {
  const navigate = useNavigate()
  const initial = readWorkflow()
  const [materials, setMaterials] = useState<Material[]>([])
  const [material, setMaterial] = useState<Material | undefined>(initial.material)
  const [graph, setGraph] = useState<KnowledgeGraphSummary | undefined>(initial.graph)
  const [chapters, setChapters] = useState<Chapter[]>(initial.chapters || [])
  const [selectedChapterIds, setSelectedChapterIds] = useState<string[]>(initial.chapters?.[0] ? [initial.chapters[0].chapterId] : [])
  const [planType, setPlanType] = useState<ReviewPlanType>('ASSESSMENT')
  const [file, setFile] = useState<File | null>(null)
  const [displayName, setDisplayName] = useState('')
  const [subjectCode, setSubjectCode] = useState(initial.graph?.subjectCode || 'GENERAL')
  const [enableOcr, setEnableOcr] = useState(false)
  const [ocrMode, setOcrMode] = useState<'quick' | 'standard'>('standard')
  const [force, setForce] = useState(false)
  const [search, setSearch] = useState('')
  const [busy, setBusy] = useState(false)
  const [progress, setProgress] = useState(initial.graph ? '图谱已就绪，可以选择复习范围。' : '选择文件或已上传资料。')
  const [error, setError] = useState('')

  useEffect(() => {
    void api.getAllMaterials().then(setMaterials).catch((reason: unknown) => setError(reason instanceof Error ? reason.message : '资料列表读取失败。'))
  }, [])

  const visibleMaterials = useMemo(() => materials.filter((item) => item.status !== 'DELETED' && item.displayName.toLowerCase().includes(search.trim().toLowerCase())), [materials, search])
  const selectedChapters = useMemo(() => chapters.filter((chapter) => selectedChapterIds.includes(chapter.chapterId)), [chapters, selectedChapterIds])

  async function processMaterial(source: Material) {
    setBusy(true); setError(''); setMaterial(source)
    let stage = '资料处理'
    try {
      let readyMaterial = source
      if (source.status !== 'READY' || force) {
        stage = '文字提取'
        setProgress(enableOcr ? `正在准备${ocrMode === 'quick' ? '快速' : '标准'} OCR。` : '正在提取资料文字。')
        const accepted = await api.createIngestionJob(source.materialId, { force, enableOcr, ocrMode })
        const completed = await pollUntil(() => api.getIngestionJob(accepted.jobId), (job) => job.status === 'SUCCEEDED' || job.status === 'FAILED', (job) => setProgress(ingestionText(job)))
        if (completed.status === 'FAILED') throw jobError(completed.error, '资料文字提取失败。')
        readyMaterial = { ...source, status: 'READY', latestIngestionJobId: completed.jobId }
        setMaterial(readyMaterial)
        setMaterials((current) => current.map((item) => item.materialId === source.materialId ? readyMaterial : item))
        setProgress(completed.ocrUsed ? 'OCR 已完成，正在构建图谱。' : '文字提取完成，正在构建图谱。')
      }

      if (readyMaterial.status === 'READY' && !force) {
        stage = '已有图谱读取'
        setProgress('正在读取资料已有的知识图谱。')
        const existingGraph = newestGraph(await api.getAllKnowledgeGraphs(readyMaterial.materialId))
        if (existingGraph) {
          const chapterList = await api.getChapters(existingGraph.graphId)
          setGraph(existingGraph); setChapters(chapterList); setSelectedChapterIds(chapterList[0] ? [chapterList[0].chapterId] : [])
          updateWorkflow({ material: readyMaterial, graph: existingGraph, chapters: chapterList, plan: undefined, gameManifest: undefined, gamePackage: undefined, reviewSession: undefined, answerResults: undefined, resultIdempotencyKey: undefined })
          setProgress(`已恢复图谱：${existingGraph.chapterCount} 章，${existingGraph.pointCount} 个知识点。`)
          return
        }
      }

      stage = '知识图谱构建'
      const acceptedBuild = await api.createGraphBuild(readyMaterial.materialId, subjectCode)
      const completedBuild = await pollUntil(() => api.getGraphBuild(acceptedBuild.buildId), (job) => job.status === 'SUCCEEDED' || job.status === 'FAILED', (job) => setProgress(`正在构建知识图谱 · ${job.progress}%`))
      if (completedBuild.status === 'FAILED') throw jobError(completedBuild.error, '知识图谱构建失败。')
      if (!completedBuild.graphId) throw new Error('构图任务完成但没有返回 graphId。')

      const [summary, chapterList] = await Promise.all([api.getKnowledgeGraph(completedBuild.graphId), api.getChapters(completedBuild.graphId)])
      setGraph(summary); setChapters(chapterList); setSelectedChapterIds(chapterList[0] ? [chapterList[0].chapterId] : [])
      updateWorkflow({ material: readyMaterial, graph: summary, chapters: chapterList, plan: undefined, gameManifest: undefined, gamePackage: undefined, reviewSession: undefined, answerResults: undefined, resultIdempotencyKey: undefined })
      setProgress(`图谱完成：${summary.chapterCount} 章，${summary.pointCount} 个知识点。`)
    } catch (reason) {
      const suffix = reason instanceof ApiClientError && reason.traceId ? `（traceId: ${reason.traceId}）` : ''
      setError(`${stage}失败：${reason instanceof Error ? reason.message : '处理失败。'}${suffix}`)
    } finally { setBusy(false) }
  }

  async function upload(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!file) return setError('请选择要上传的文件。')
    if (file.size > MAX_FILE_BYTES) return setError('单个文件不能超过 10 MiB。')
    if ((file.type.startsWith('image/') || /\.(png|jpe?g)$/i.test(file.name)) && !enableOcr) return setError('图片资料需要先开启 OCR。')
    setBusy(true); setError(''); setProgress('正在上传资料。')
    try {
      resetWorkflow(); setGraph(undefined); setChapters([]); setSelectedChapterIds([])
      const uploaded = await api.uploadMaterial(file, displayName || file.name, subjectCode)
      setMaterial(uploaded); setMaterials((current) => [uploaded, ...current.filter((item) => item.materialId !== uploaded.materialId)]); updateWorkflow({ material: uploaded })
      setProgress('文件上传完成，正在处理资料。')
      await processMaterial(uploaded)
    } catch (reason) {
      const suffix = reason instanceof ApiClientError && reason.traceId ? `（traceId: ${reason.traceId}）` : ''
      setError(`文件上传失败：${reason instanceof Error ? reason.message : '资料上传失败。'}${suffix}`)
      setBusy(false)
    }
  }

  async function createPlan() {
    if (!graph) return
    if (selectedChapterIds.length === 0) return setError('至少选择一个章节。')
    setBusy(true); setError(''); setProgress('正在生成复习计划。')
    try {
      const plan: PlanGraph = planType === 'ASSESSMENT' ? await api.createAssessmentPlan(graph.graphId, selectedChapterIds) : await api.createLearningPlan(graph.graphId, selectedChapterIds)
      updateWorkflow({ plan, gameManifest: undefined, gamePackage: undefined, reviewSession: undefined, answerResults: undefined, resultIdempotencyKey: undefined })
      navigate('/review')
    } catch (reason) { setError(reason instanceof Error ? reason.message : '复习计划创建失败。') } finally { setBusy(false) }
  }

  async function deleteMaterial(item: Material) {
    if (!window.confirm(`删除资料“${item.displayName}”？此操作不能撤销。`)) return
    setBusy(true); setError('')
    try {
      await api.deleteMaterial(item.materialId)
      setMaterials((current) => current.filter((entry) => entry.materialId !== item.materialId))
      if (material?.materialId === item.materialId) { resetWorkflow(); setMaterial(undefined); setGraph(undefined); setChapters([]); setSelectedChapterIds([]) }
      setProgress('资料已删除。')
    } catch (reason) { setError(reason instanceof Error ? reason.message : '资料删除失败。') } finally { setBusy(false) }
  }

  return (
    <AppShell>
      <main className="page materials-page">
        <PageHeader title="资料与学习计划" description="上传文件、提取文字、构建图谱，再确定本轮复习范围。" actions={graph ? <Link className="button" to="/knowledge-graph">查看图谱</Link> : null} />

        <div className="process-layout">
          <section className="process-primary">
            <form className="form-section upload-panel" onSubmit={upload}>
              <header><h2>上传资料</h2><p>文件上限 10 MiB。图片和扫描件只有在明确开启 OCR 后才会识别。</p></header>
              <label>文件<input type="file" accept=".pdf,.docx,.md,.markdown,.html,.htm,.txt,.png,.jpg,.jpeg" onChange={(event) => setFile(event.target.files?.[0] || null)} /></label>
              <label>资料名称<input value={displayName} onChange={(event) => setDisplayName(event.target.value)} placeholder={file?.name || '选填'} /></label>
              <label>学科代码<input value={subjectCode} onChange={(event) => setSubjectCode(event.target.value.toUpperCase())} pattern="[A-Z][A-Z0-9_]{0,31}" placeholder="GENERAL" /></label>
              <div className="option-row">
                <label className="toggle-field"><span><strong>启用 OCR</strong><small>仅在图片或扫描件需要时开启。</small></span><input type="checkbox" checked={enableOcr} onChange={(event) => setEnableOcr(event.target.checked)} /></label>
                <label>OCR 模式<select disabled={!enableOcr} value={ocrMode} onChange={(event) => setOcrMode(event.target.value as 'quick' | 'standard')}><option value="standard">标准识别</option><option value="quick">快速识别</option></select></label>
              </div>
              <label className="toggle-field compact-toggle"><span><strong>重新提取</strong><small>处理已就绪资料时强制创建新任务。</small></span><input type="checkbox" checked={force} onChange={(event) => setForce(event.target.checked)} /></label>
              <button className="button button--primary" disabled={busy} type="submit">{busy ? '正在处理' : '上传并构建图谱'}</button>
            </form>

            <section className="material-library">
              <header><div><h2>资料库</h2><p>{materials.filter((item) => item.status !== 'DELETED').length} 份资料</p></div><input aria-label="搜索资料" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="搜索资料" /></header>
              <div className="material-table">
                {visibleMaterials.map((item) => <article className={material?.materialId === item.materialId ? 'selected' : ''} key={item.materialId}><button className="material-open" type="button" disabled={busy} onClick={() => void processMaterial(item)}><span><strong>{item.displayName}</strong><small>{item.originalFileName}</small></span><em>{item.status}</em></button><button className="material-delete" type="button" disabled={busy || item.status === 'PROCESSING'} onClick={() => void deleteMaterial(item)}>删除</button></article>)}
                {!visibleMaterials.length ? <p className="empty-row">没有匹配的资料。</p> : null}
              </div>
            </section>
          </section>

          <aside className="plan-panel">
            <header><span>下一步</span><h2>选择复习范围</h2></header>
            {!graph ? <p>图谱构建完成后，这里会显示章节与计划选项。</p> : <>
              <dl className="plan-summary"><div><dt>学科</dt><dd>{graph.subjectCode}</dd></div><div><dt>知识点</dt><dd>{graph.pointCount}</dd></div><div><dt>关系</dt><dd>{graph.relationCount}</dd></div></dl>
              <div className="segmented-control"><button className={planType === 'ASSESSMENT' ? 'active' : ''} type="button" onClick={() => setPlanType('ASSESSMENT')}>全面测试</button><button className={planType === 'LEARNING' ? 'active' : ''} type="button" onClick={() => setPlanType('LEARNING')}>章节学习</button></div>
              <div className="chapter-actions"><button type="button" onClick={() => setSelectedChapterIds(chapters.map((item) => item.chapterId))}>全选</button><button type="button" onClick={() => setSelectedChapterIds([])}>清空</button></div>
              <div className="chapter-picker">{chapters.map((chapter) => <label key={chapter.chapterId} style={{ paddingLeft: `${chapter.depth * 14}px` }}><input type="checkbox" checked={selectedChapterIds.includes(chapter.chapterId)} onChange={() => setSelectedChapterIds((current) => current.includes(chapter.chapterId) ? current.filter((id) => id !== chapter.chapterId) : [...current, chapter.chapterId])} /><span>{chapter.title}</span></label>)}</div>
              <button className="button button--primary" type="button" disabled={busy || selectedChapters.length === 0} onClick={() => void createPlan()}>创建{planType === 'ASSESSMENT' ? '测试' : '学习'}计划</button>
            </>}
          </aside>
        </div>
        <p className={error ? 'status-line status-line--error' : 'status-line'} role="status">{error || progress}</p>
      </main>
    </AppShell>
  )
}
