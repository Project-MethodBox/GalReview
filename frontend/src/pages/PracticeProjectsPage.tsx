import { FormEvent, useEffect, useState } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router'
import AppShell, { PageHeader } from '../components/AppShell'
import { api } from '../lib/api'
import { handleCreditsRequired } from '../lib/credits'
import { pollUntil } from '../lib/poll'
import type { Material, StudyProject } from '../types/api'

const INITIAL_QUESTION_KINDS = ['SINGLE_CHOICE', 'FILL_BLANK', 'TERM_DEFINITION', 'ESSAY'] as const

export default function PracticeProjectsPage() {
  const [searchParams] = useSearchParams()
  const navigate = useNavigate()
  const [projects, setProjects] = useState<StudyProject[]>([])
  const [materials, setMaterials] = useState<Material[]>([])
  const [name, setName] = useState('')
  const [subjectCode, setSubjectCode] = useState('')
  const [materialId, setMaterialId] = useState(searchParams.get('materialId') || '')
  const [packageFile, setPackageFile] = useState<File | null>(null)
  const [message, setMessage] = useState('')
  const [busy, setBusy] = useState(false)

  async function load() {
    const [projectPage, materialItems] = await Promise.all([api.listPracticeProjects(), api.getAllMaterials()])
    setProjects(projectPage.items)
    setMaterials(materialItems.filter((item) => item.status === 'READY'))
  }

  useEffect(() => { void load().catch((error: unknown) => setMessage(error instanceof Error ? error.message : '研习册读取失败。')) }, [])

  async function create(event: FormEvent) {
    event.preventDefault(); setBusy(true); setMessage('')
    let created: StudyProject | undefined
    try {
      created = await api.createPracticeProject({ name, subjectCode: subjectCode || undefined, materialIds: [materialId], graphId: null })
      setMessage('研习册已建立，正在为本册梳理知识脉络。')
      const accepted = await api.createGraphBuild(created.projectId, materialId, subjectCode || undefined)
      const completed = await pollUntil(() => api.getGraphBuild(accepted.buildId),
        (job) => job.status === 'SUCCEEDED' || job.status === 'FAILED',
        (job) => setMessage(`正在为本册识网 · ${job.progress}%`))
      if (completed.status === 'FAILED') throw new Error(completed.error?.message || '本册知识脉络建立失败。')
      if (!completed.graphId || completed.studyProjectId !== created.projectId) throw new Error('构图完成，但返回的研习册作用域不匹配。')
      const summary = await api.getKnowledgeGraph(completed.graphId)
      if (summary.studyProjectId !== created.projectId) throw new Error('知识图谱不属于刚建立的研习册。')
      created = await api.updatePracticeProject(created, { graphId: completed.graphId })
      const chapterItems = await api.getChapters(completed.graphId)
      if (chapterItems.length === 0) throw new Error('本册知识脉络没有可用于成题的章节。')
      setMessage('识网已成，正在按全部章节自动生成题目。')
      const plan = await api.createLearningPlan(completed.graphId, chapterItems.map((chapter) => chapter.chapterId), {
        maxPoints: 1000, maximumDependencyDepth: 8,
      })
      const job = await api.generatePracticeQuestions(created.projectId, {
        reviewPlanId: plan.reviewPlanId,
        snapshotVersion: plan.snapshotVersion,
        kinds: [...INITIAL_QUESTION_KINDS],
      })
      if (job.createdCount < 1) throw new Error(job.diagnostics[0]?.message || '研习册已建立，但没有从资料中生成可用题目。')
      const suffix = job.diagnostics.length ? `；另有 ${job.diagnostics.length} 项资料未能可靠成题` : ''
      setName(''); setSubjectCode('')
      navigate(`/projects/${created.projectId}`, { replace: true, state: { message: `研习册已建立并自动生成 ${job.createdCount} 道题${suffix}。` } })
    } catch (error) {
      const reason = error instanceof Error ? error.message : '研习册创建失败。'
      if (created) {
        await load().catch(() => undefined)
        if (!handleCreditsRequired(error)) navigate(`/projects/${created.projectId}`, { state: { message: `研习册已经建立，但自动成题未完成：${reason} 请在“成题”区重试。` } })
      } else if (!handleCreditsRequired(error)) setMessage(reason)
    } finally { setBusy(false) }
  }

  async function importPackage(event: FormEvent) {
    event.preventDefault(); if (!packageFile) return; setBusy(true); setMessage('')
    try { const result = await api.importPracticePackage(packageFile, [materialId]); await load(); setPackageFile(null); setMessage(`已从 ${result.importedFromSchema} 导入 ${result.importedQuestionCount} 道题。`) }
    catch (error) { setMessage(error instanceof Error ? error.message : '项目包导入失败。') } finally { setBusy(false) }
  }

  return <AppShell><main className="page practice-projects-page">
    <PageHeader title="研习册" description="每一册都是完整的经典复习项目：资料、章节、题库、练习、试卷与掌握度汇于一处；故事回响也从册中开启。" actions={<Link className="button button--quiet" to="/shared-projects">同窗书架</Link>} />
    {message ? <p className="status-line" role="status">{message}</p> : null}
    <div className="practice-project-layout">
      <section className="workspace-card">
        <header><span className="section-label">册目</span><h2>续读旧卷</h2></header>
        <div className="practice-project-list">
          {projects.map((project) => <Link key={project.projectId} to={`/projects/${project.projectId}`}>
            <span><strong>{project.name}</strong><small>{project.subjectCode || '未设置学科'} · {project.materialIds.length} 份资料</small></span>
            <span>进入</span>
          </Link>)}
          {projects.length === 0 ? <p className="empty-row">还没有研习册。先在藏书阁备好资料，再到立册区建立经典复习项目；知识脉络会归入新册。</p> : null}
        </div>
      </section>
      <div className="practice-project-side"><form className="form-section practice-project-create" onSubmit={(event) => void create(event)}>
        <header><span className="section-label">立册</span><h2>建立经典复习项目</h2><p>选取藏书阁原文后，系统会为新册独立识网并自动成题；知识脉络、题库与掌握记录都归本册保存。</p></header>
        <label>研习册名称<input value={name} maxLength={120} required onChange={(event) => setName(event.target.value)} /></label>
        <label>学科代码<input value={subjectCode} maxLength={32} placeholder="例如 CS_DS" onChange={(event) => setSubjectCode(event.target.value.toUpperCase())} /></label>
        <label>主资料<select value={materialId} required onChange={(event) => setMaterialId(event.target.value)}><option value="">选择已就绪资料</option>{materials.map((item) => <option key={item.materialId} value={item.materialId}>{item.displayName}</option>)}</select></label>
        <button className="button button--primary" aria-busy={busy} disabled={busy || materials.length === 0 || !materialId}>{busy ? '正在立册并成题' : '建立研习册'}</button>
      </form><form className="form-section" onSubmit={(event) => void importPackage(event)}><header><span className="section-label">承旧</span><h2>导入旧版项目包</h2><p>兼容 .rhproj、.rhp 与新版 .qzwlp。旧题先归入所选资料，未识别知识点的题目须补签后才能用于循网复习。</p></header><label>项目包<input type="file" accept=".rhproj,.rhp,.qzwlp" required onChange={(event) => setPackageFile(event.target.files?.[0] || null)} /></label><button className="button button--quiet" disabled={busy || !packageFile || !materialId}>导入项目包</button></form></div>
    </div>
  </main></AppShell>
}
