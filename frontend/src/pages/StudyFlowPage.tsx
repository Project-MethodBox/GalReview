import { useEffect, useMemo, useState, type FormEvent } from 'react'
import { Link } from 'react-router'
import AppShell, { PageHeader } from '../components/AppShell'
import LoadingIndicator from '../components/LoadingIndicator'
import { api, ApiClientError } from '../lib/api'
import { pollUntil } from '../lib/poll'
import { readWorkflow, resetWorkflow, updateWorkflow } from '../lib/workflow'
import type { ExtractedTextDocument, IngestionJob, Material } from '../types/api'

const MAX_FILE_BYTES = 10 * 1024 * 1024

function jobError(error: { message: string } | null, fallback: string): Error {
  return new Error(error?.message || fallback)
}

function ingestionText(job: IngestionJob) {
  if (job.ocrProgress) return `OCR ${job.ocrProgress.currentPage}/${job.ocrProgress.totalPages} 页 · ${job.ocrProgress.phase}`
  return `正在提取文字 · ${job.progress}%`
}

function formatUploadTime(value: string) {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return '上传时间未知'
  return `上传于 ${date.toLocaleString('zh-CN', { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false })}`
}

export default function StudyFlowPage() {
  const initial = readWorkflow()
  const [materials, setMaterials] = useState<Material[]>([])
  const [material, setMaterial] = useState<Material | undefined>(initial.material)
  const [file, setFile] = useState<File | null>(null)
  const [displayName, setDisplayName] = useState('')
  const [subjectCode, setSubjectCode] = useState('GENERAL')
  const [enableOcr, setEnableOcr] = useState(false)
  const [ocrMode, setOcrMode] = useState<'quick' | 'standard'>('standard')
  const [force, setForce] = useState(false)
  const [search, setSearch] = useState('')
  const [busy, setBusy] = useState(false)
  const [progress, setProgress] = useState('选择文件或已上传资料。')
  const [error, setError] = useState('')
  const [preview, setPreview] = useState<ExtractedTextDocument>()
  const [previewName, setPreviewName] = useState('')
  const [previewBusy, setPreviewBusy] = useState(false)

  useEffect(() => {
    void api.getAllMaterials().then(setMaterials).catch((reason: unknown) => setError(reason instanceof Error ? reason.message : '资料列表读取失败。'))
  }, [])

  const visibleMaterials = useMemo(() => materials.filter((item) => item.status !== 'DELETED' && item.displayName.toLowerCase().includes(search.trim().toLowerCase())), [materials, search])

  async function processMaterial(source: Material) {
    setBusy(true); setError(''); setMaterial(source)
    let stage = '资料处理'
    try {
      let readyMaterial = source
      let ingestionJobId = source.status === 'PROCESSING' && !force
        ? source.latestIngestionJobId
        : null

      if (source.status !== 'READY' || force) {
        stage = '文字提取'
        if (ingestionJobId) {
          setProgress('正在恢复进行中的文字提取任务。')
        } else {
          setProgress(enableOcr ? `正在准备${ocrMode === 'quick' ? '快速' : '标准'} OCR。` : '正在提取资料文字。')
          const accepted = await api.createIngestionJob(source.materialId, { force, enableOcr, ocrMode })
          ingestionJobId = accepted.jobId
          const processingMaterial: Material = {
            ...source,
            status: 'PROCESSING',
            latestIngestionJobId: accepted.jobId,
            updatedAt: new Date().toISOString(),
          }
          setMaterial(processingMaterial)
          setMaterials((current) => current.map((item) => item.materialId === source.materialId ? processingMaterial : item))
        }

        const completed = await pollUntil(
          () => api.getIngestionJob(ingestionJobId!),
          (job) => job.status === 'SUCCEEDED' || job.status === 'FAILED',
          (job) => setProgress(ingestionText(job)),
          900_000,
        )
        if (completed.status === 'FAILED') throw jobError(completed.error, '资料文字提取失败。')
        readyMaterial = await api.getMaterial(source.materialId)
        setMaterial(readyMaterial)
        setMaterials((current) => current.map((item) => item.materialId === source.materialId ? readyMaterial : item))
        setProgress(completed.ocrUsed ? 'OCR 与文字提取已完成。' : '文字提取已完成。')
      }

      setMaterial(readyMaterial)
      updateWorkflow({ projectId: undefined, material: readyMaterial, graph: undefined, chapters: undefined, plan: undefined,
        gameGeneration: undefined, gameStyle: undefined, gameDifficulty: undefined, gameManifest: undefined,
        gamePackage: undefined, reviewSession: undefined, visitedSceneIds: undefined, answerResults: undefined,
        resultIdempotencyKey: undefined })
      setProgress(readyMaterial.status === 'READY' ? '资料解析已就绪，可据此建立研习册。' : '资料已选中。')
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
      resetWorkflow()
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

  async function deleteMaterial(item: Material) {
    if (!window.confirm(`删除资料“${item.displayName}”？此操作不能撤销。`)) return
    setBusy(true); setError('')
    try {
      await api.deleteMaterial(item.materialId)
      setMaterials((current) => current.filter((entry) => entry.materialId !== item.materialId))
      if (material?.materialId === item.materialId) { resetWorkflow(); setMaterial(undefined) }
      setProgress('资料已删除。')
    } catch (reason) { setError(reason instanceof Error ? reason.message : '资料删除失败。') } finally { setBusy(false) }
  }

  async function openTextPreview(item: Material) {
    setPreviewBusy(true)
    setError('')
    try {
      const document = await api.getExtractedTextPreview(item.materialId)
      setPreview(document)
      setPreviewName(item.displayName)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '提取文本预览读取失败。')
    } finally {
      setPreviewBusy(false)
    }
  }

  return (
    <AppShell>
      <main className="page materials-page">
        <PageHeader title="藏书阁" />

        <div className="process-layout process-layout--materials">
          <section className="process-primary">
            <section className="form-section upload-panel">
              <header className="upload-panel__header"><div><h2>上传资料</h2><p>文件上限为 10 MiB。图片和扫描件需要开启 OCR 才能识别文字。</p></div></header>
              <form className="upload-panel__form" onSubmit={upload}>
              <label>文件<input type="file" accept=".pdf,.docx,.md,.markdown,.html,.htm,.txt,.png,.jpg,.jpeg" onChange={(event) => setFile(event.target.files?.[0] || null)} /></label>
              <label>资料名称<input value={displayName} onChange={(event) => setDisplayName(event.target.value)} placeholder={file?.name || '选填'} /></label>
              <label>学科代码<input value={subjectCode} onChange={(event) => setSubjectCode(event.target.value.toUpperCase())} pattern="[A-Z][A-Z0-9_]{0,31}" placeholder="GENERAL" /></label>
              <div className="option-row">
                <label className="toggle-field"><span><strong>启用 OCR</strong><small>仅在图片或扫描件需要时开启。</small></span><input type="checkbox" role="switch" aria-label="启用 OCR" checked={enableOcr} onChange={(event) => setEnableOcr(event.target.checked)} /></label>
                <label className={`inline-select-field${enableOcr ? ' is-enabled' : ''}`}><span>OCR 模式</span><select aria-label="OCR 模式" disabled={!enableOcr} value={ocrMode} onChange={(event) => setOcrMode(event.target.value as 'quick' | 'standard')}><option value="standard">标准</option><option value="quick">快速</option></select></label>
              </div>
              <label className="toggle-field compact-toggle"><span><strong>重新提取</strong><small>再次处理已完成的资料并更新提取结果。</small></span><input type="checkbox" role="switch" aria-label="重新提取" checked={force} onChange={(event) => setForce(event.target.checked)} /></label>
              <button className="button button--primary" disabled={busy} type="submit">{busy ? '正在处理' : '上传并解析'}</button>
              </form>
            </section>

            <section className="material-library">
              <header><div><h2>资料库</h2><p>{materials.filter((item) => item.status !== 'DELETED').length} 份资料</p></div><input aria-label="搜索资料" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="搜索资料" /></header>
              <div className="material-table">
                {visibleMaterials.map((item) => <article className={material?.materialId === item.materialId ? 'selected' : ''} key={item.materialId}><button className="material-open" type="button" disabled={busy} onClick={() => void processMaterial(item)}><span><strong>{item.displayName}</strong><small>{formatUploadTime(item.createdAt)}</small>{item.ocrUsed ? <em className="material-ocr-badge">OCR</em> : null}</span><em className={`material-status material-status--${item.status.toLowerCase()}`}>{item.status}</em></button><div className="material-actions">{item.status === 'READY' ? <><button type="button" disabled={previewBusy} onClick={() => void openTextPreview(item)}>文本</button><Link to={`/projects?materialId=${encodeURIComponent(item.materialId)}`}>立册</Link></> : null}<button className="material-delete" type="button" disabled={busy && item.status !== 'PROCESSING'} onClick={() => void deleteMaterial(item)}>删除</button></div></article>)}
                {!visibleMaterials.length ? <p className="empty-row">没有匹配的资料。</p> : null}
              </div>
            </section>
          </section>
        </div>
        {busy && !error
          ? <LoadingIndicator className="page-loading-transition" label={progress || '正在处理…'} compact />
          : error || progress ? <p className={error ? 'status-line status-line--error' : 'status-line'} role="status">{error || progress}</p> : null}
        {preview ? <div className="preview-overlay" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) setPreview(undefined) }}>
          <section className="text-preview" role="dialog" aria-modal="true" aria-labelledby="text-preview-title">
            <header><div><span>提取文本</span><h2 id="text-preview-title">{previewName}</h2><p>{preview.textLength.toLocaleString('zh-CN')} 字符 · {preview.parserVersion}</p></div><button type="button" aria-label="关闭文本预览" onClick={() => setPreview(undefined)}>关闭</button></header>
            <pre>{preview.text}</pre>
          </section>
        </div> : null}
      </main>
    </AppShell>
  )
}
