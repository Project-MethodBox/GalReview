import { useEffect, useMemo, useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router'
import { api, ApiClientError } from '../lib/api'
import { pollUntil } from '../lib/poll'
import { readWorkflow, resetWorkflow, updateWorkflow } from '../lib/workflow'
import type { Chapter, Material, PlanGraph, ReviewPlanType } from '../types/api'

const MAX_FILE_BYTES = 10 * 1024 * 1024

function jobError(error: { message: string } | null, fallback: string): Error {
  return new Error(error?.message || fallback)
}

export default function StudyFlowPage() {
  const navigate = useNavigate()
  const initial = readWorkflow()
  const [materials, setMaterials] = useState<Material[]>([])
  const [material, setMaterial] = useState<Material | undefined>(initial.material)
  const [chapters, setChapters] = useState<Chapter[]>(initial.chapters || [])
  const [selectedChapterIds, setSelectedChapterIds] = useState<string[]>(initial.chapters?.[0] ? [initial.chapters[0].chapterId] : [])
  const [planType, setPlanType] = useState<ReviewPlanType>('ASSESSMENT')
  const [file, setFile] = useState<File | null>(null)
  const [displayName, setDisplayName] = useState('')
  const [subjectCode, setSubjectCode] = useState('GENERAL')
  const [busy, setBusy] = useState(false)
  const [progress, setProgress] = useState(initial.graph ? '图谱已就绪，可以创建复习计划。' : '选择资料开始。')
  const [error, setError] = useState('')
  const graph = readWorkflow().graph

  useEffect(() => {
    void api.listMaterials().then((page) => setMaterials(page.items)).catch((reason: unknown) => {
      setError(reason instanceof Error ? reason.message : '资料列表读取失败。')
    })
  }, [])

  const selectedChapters = useMemo(
    () => chapters.filter((chapter) => selectedChapterIds.includes(chapter.chapterId)),
    [chapters, selectedChapterIds],
  )

  async function processMaterial(source: Material) {
    setBusy(true)
    setError('')
    try {
      let readyMaterial = source
      if (source.status !== 'READY') {
        setProgress('正在提取资料中的文字…')
        const accepted = await api.createIngestionJob(source.materialId)
        const completed = await pollUntil(
          () => api.getIngestionJob(accepted.jobId),
          (job) => job.status === 'SUCCEEDED' || job.status === 'FAILED',
          (job) => setProgress(`正在提取资料中的文字… ${job.progress}%`),
        )
        if (completed.status === 'FAILED') throw jobError(completed.error, '资料文字提取失败。')
        readyMaterial = { ...source, status: 'READY', latestIngestionJobId: completed.jobId }
        setMaterial(readyMaterial)
        updateWorkflow({ material: readyMaterial })
      }

      setProgress('正在按章节构建知识图谱…')
      const acceptedBuild = await api.createGraphBuild(readyMaterial.materialId, subjectCode)
      const completedBuild = await pollUntil(
        () => api.getGraphBuild(acceptedBuild.buildId),
        (job) => job.status === 'SUCCEEDED' || job.status === 'FAILED',
        (job) => setProgress(`正在按章节构建知识图谱… ${job.progress}%`),
      )
      if (completedBuild.status === 'FAILED') throw jobError(completedBuild.error, '知识图谱构建失败。')
      if (!completedBuild.graphId) throw new Error('构图任务完成但没有返回 graphId。')

      const [summary, chapterList] = await Promise.all([
        api.getKnowledgeGraph(completedBuild.graphId),
        api.getChapters(completedBuild.graphId),
      ])
      setChapters(chapterList)
      setSelectedChapterIds(chapterList[0] ? [chapterList[0].chapterId] : [])
      updateWorkflow({
        material: readyMaterial,
        graph: summary,
        chapters: chapterList,
        plan: undefined,
        gameManifest: undefined,
        gamePackage: undefined,
        reviewSession: undefined,
        answerResults: undefined,
        resultIdempotencyKey: undefined,
      })
      setProgress(`图谱构建完成：${summary.chapterCount} 章，${summary.pointCount} 个知识点。`)
    } catch (reason) {
      const suffix = reason instanceof ApiClientError && reason.traceId ? `（traceId: ${reason.traceId}）` : ''
      setError(`${reason instanceof Error ? reason.message : '处理失败。'}${suffix}`)
    } finally {
      setBusy(false)
    }
  }

  async function upload(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!file) {
      setError('请先选择文件。')
      return
    }
    if (file.size > MAX_FILE_BYTES) {
      setError('单个文件不能超过 10 MiB。')
      return
    }
    setBusy(true)
    setError('')
    setProgress('正在上传资料…')
    try {
      resetWorkflow()
      const uploaded = await api.uploadMaterial(file, displayName || file.name, subjectCode)
      setMaterial(uploaded)
      setMaterials((current) => [uploaded, ...current.filter((item) => item.materialId !== uploaded.materialId)])
      updateWorkflow({ material: uploaded })
      await processMaterial(uploaded)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '资料上传失败。')
      setBusy(false)
    }
  }

  async function createPlan() {
    const currentGraph = readWorkflow().graph
    if (!currentGraph) return
    if (planType === 'LEARNING' && selectedChapterIds.length === 0) {
      setError('学习计划至少需要选择一个章节。')
      return
    }
    setBusy(true)
    setError('')
    setProgress('正在选择本次最值得复习的知识点…')
    try {
      const plan: PlanGraph = planType === 'ASSESSMENT'
        ? await api.createAssessmentPlan(currentGraph.graphId, selectedChapterIds)
        : await api.createLearningPlan(currentGraph.graphId, selectedChapterIds)
      updateWorkflow({
        plan,
        gameManifest: undefined,
        gamePackage: undefined,
        reviewSession: undefined,
        answerResults: undefined,
        resultIdempotencyKey: undefined,
      })
      navigate('/review')
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '复习计划创建失败。')
    } finally {
      setBusy(false)
    }
  }

  function toggleChapter(chapterId: string) {
    setSelectedChapterIds((current) => current.includes(chapterId)
      ? current.filter((id) => id !== chapterId)
      : [...current, chapterId])
  }

  return (
    <main className="workspace-page">
      <header className="workspace-header">
        <div><p>学习准备</p><h1>把资料变成一场复习</h1></div>
        <nav><Link to="/home">返回主页</Link>{graph ? <Link to="/knowledge-graph">查看图谱</Link> : null}</nav>
      </header>

      <div className="workflow-grid">
        <section className="workspace-card">
          <span className="step-number">01</span>
          <h2>上传资料</h2>
          <p>支持契约约定的 PDF、DOCX、Markdown、HTML 与文本文件；本页固定使用非 OCR 提取。</p>
          <form className="upload-form" onSubmit={upload}>
            <input type="file" onChange={(event) => setFile(event.target.files?.[0] || null)} />
            <input value={displayName} onChange={(event) => setDisplayName(event.target.value)} placeholder="资料名称（可选）" />
            <input value={subjectCode} onChange={(event) => setSubjectCode(event.target.value.toUpperCase())} placeholder="学科代码，如 GENERAL" pattern="[A-Z][A-Z0-9_]{0,31}" />
            <button type="submit" disabled={busy}>{busy ? '处理中…' : '上传并构建图谱'}</button>
          </form>
          {materials.length ? (
            <details className="material-list">
              <summary>使用已上传的资料</summary>
              {materials.filter((item) => item.status !== 'DELETED').map((item) => (
                <button key={item.materialId} type="button" disabled={busy} onClick={() => { setMaterial(item); void processMaterial(item) }}>
                  <span>{item.displayName}</span><small>{item.status}</small>
                </button>
              ))}
            </details>
          ) : null}
        </section>

        <section className="workspace-card">
          <span className="step-number">02</span>
          <h2>选择复习范围</h2>
          {!graph ? <p>图谱完成后，这里会列出识别到的章节。</p> : (
            <>
              <p>{graph.subjectCode} · {graph.pointCount} 个知识点 · {graph.relationCount} 条关系</p>
              <div className="segmented-control">
                <button className={planType === 'ASSESSMENT' ? 'active' : ''} type="button" onClick={() => setPlanType('ASSESSMENT')}>全面测试</button>
                <button className={planType === 'LEARNING' ? 'active' : ''} type="button" onClick={() => setPlanType('LEARNING')}>章节学习</button>
              </div>
              <div className="chapter-picker">
                {chapters.map((chapter) => (
                  <label key={chapter.chapterId} style={{ paddingLeft: `${chapter.depth * 16}px` }}>
                    <input type="checkbox" checked={selectedChapterIds.includes(chapter.chapterId)} onChange={() => toggleChapter(chapter.chapterId)} />
                    <span>{chapter.title}</span>
                  </label>
                ))}
              </div>
              <button className="primary-button" type="button" disabled={busy || (planType === 'LEARNING' && selectedChapters.length === 0)} onClick={() => void createPlan()}>
                生成{planType === 'ASSESSMENT' ? '测试' : '学习'}计划
              </button>
            </>
          )}
        </section>
      </div>

      <div className="workflow-status" aria-live="polite">
        <strong>{material?.displayName || '尚未选择资料'}</strong>
        <span>{error || progress}</span>
      </div>
    </main>
  )
}
