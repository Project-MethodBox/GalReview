import { FormEvent, useEffect, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router'
import AppShell, { PageHeader } from '../components/AppShell'
import { api } from '../lib/api'
import { handleCreditsRequired } from '../lib/credits'
import { readWorkflow } from '../lib/workflow'
import type { Material, PracticeProjectDetails, PracticeQuestion, PracticeQuestionKind } from '../types/api'

const kindLabels: Record<PracticeQuestionKind, string> = { SINGLE_CHOICE: '单选题', FILL_BLANK: '填空题', TRUE_FALSE: '判断题', TERM_DEFINITION: '名词解释', ESSAY: '简答题' }

export default function PracticeProjectPage() {
  const { projectId = '' } = useParams(); const navigate = useNavigate(); const workflow = readWorkflow()
  const [details, setDetails] = useState<PracticeProjectDetails | null>(null); const [questions, setQuestions] = useState<PracticeQuestion[]>([])
  const [materials, setMaterials] = useState<Material[]>([]); const [examMaterialId, setExamMaterialId] = useState('')
  const [kind, setKind] = useState<PracticeQuestionKind>('SINGLE_CHOICE'); const [prompt, setPrompt] = useState('')
  const [answer, setAnswer] = useState(''); const [options, setOptions] = useState('A. \nB. '); const [message, setMessage] = useState(''); const [busy, setBusy] = useState(false)
  const [packageVersion, setPackageVersion] = useState('1.0.0')

  async function load() {
    const [project, page, materialItems] = await Promise.all([api.getPracticeProject(projectId), api.listPracticeQuestions(projectId), api.getAllMaterials()])
    setDetails(project); setQuestions(page.items); setMaterials(materialItems.filter((item) => project.project.materialIds.includes(item.materialId)))
    setExamMaterialId((current) => current || project.project.materialIds[0] || '')
  }
  useEffect(() => { void load().catch((error: unknown) => setMessage(error instanceof Error ? error.message : '项目读取失败。')) }, [projectId])

  async function run(action: () => Promise<void>, fallback: string) {
    setBusy(true); setMessage(''); try { await action() } catch (error) { if (!handleCreditsRequired(error)) setMessage(error instanceof Error ? error.message : fallback) } finally { setBusy(false) }
  }
  async function addQuestion(event: FormEvent) {
    event.preventDefault(); await run(async () => {
      const parsedOptions = kind === 'SINGLE_CHOICE' ? options.split('\n').map((line) => line.trim()).filter(Boolean).map((line) => {
        const match = line.match(/^([A-Za-z0-9]+)[.、)]\s*(.+)$/); return { id: match?.[1]?.toUpperCase() || '', text: match?.[2] || '' }
      }) : []
      const correctAnswers = kind === 'FILL_BLANK' ? answer.split('\n').map((item) => item.trim()).filter(Boolean) : [answer.trim()]
      await api.createPracticeQuestion(projectId, { kind, prompt, options: parsedOptions, correctAnswers, score: 5, difficulty: 3, status: 'READY' })
      setPrompt(''); setAnswer(''); await load(); setMessage('题目已加入题库。')
    }, '题目保存失败。')
  }
  async function startPractice(mode: 'RANDOM' | 'SMART_REVIEW' = 'RANDOM') {
    await run(async () => {
      const plan = mode === 'SMART_REVIEW' ? workflow.plan : null
      const session = await api.createPracticeSession({ projectId, mode, questionCount: Math.min(20, details?.readyQuestionCount || 20),
        reviewPlanId: plan?.reviewPlanId, snapshotVersion: plan?.snapshotVersion })
      navigate(`/practice/${session.sessionId}`)
    }, '练习创建失败。')
  }
  async function generateQuestions() {
    await run(async () => { const job = await api.generatePracticeQuestions(projectId, { kinds: Object.keys(kindLabels) as PracticeQuestionKind[], targetCount: 30 }); await load(); setMessage(`资料生成完成，创建 ${job.createdCount} 道草稿题。`) }, '题库生成失败。')
  }
  async function importExam() {
    await run(async () => { const job = await api.importExam(projectId, examMaterialId); await load(); setMessage(job.createdCount > 0 ? `整卷导入完成，创建 ${job.createdCount} 道草稿题。` : job.diagnostics[0]?.message || '没有导入题目。') }, '整卷导入失败。')
  }
  async function startExam() {
    await run(async () => { const paper = await api.createExamPaper(projectId, { title: `${details?.project.name || '项目'}试卷`, questionCount: Math.min(30, details?.readyQuestionCount || 30), durationSeconds: 3600 }); const session = await api.createPracticeSession({ projectId, mode: 'EXAM', examPaperId: paper.examPaperId }); navigate(`/practice/${session.sessionId}`) }, '试卷创建失败。')
  }
  async function exportPackage() {
    await run(async () => { const blob = await api.exportPracticePackage(projectId); const url = URL.createObjectURL(blob); const anchor = document.createElement('a'); anchor.href = url; anchor.download = `${details?.project.name || 'practice'}.qzwlp`; anchor.click(); URL.revokeObjectURL(url); setMessage('项目包已导出。') }, '项目包导出失败。')
  }
  async function publishPackage() {
    await run(async () => { await api.publishPracticePackage(projectId, packageVersion, 'PUBLIC'); setMessage(`共享版本 ${packageVersion} 已发布。`) }, '共享包发布失败。')
  }
  async function publishQuestion(question: PracticeQuestion) {
    await run(async () => { await api.updatePracticeQuestion(question, 'READY'); await load(); setMessage('草稿已经确认，可用于练习。') }, '题目发布失败。')
  }

  const smartReviewAvailable = Boolean(workflow.plan && details?.project.graphId && workflow.plan.graphId === details.project.graphId)
  return <AppShell><main className="page practice-project-page">
    <PageHeader title={details?.project.name || '学习项目'} description={`${details?.project.subjectCode || '未设置学科'} · ${details?.readyQuestionCount ?? 0} 道可练习题`} actions={<Link className="button button--quiet" to="/projects">返回项目</Link>} />
    {message ? <p className="status-line" role="status">{message}</p> : null}
    <section className="practice-mode-grid" aria-label="复习方式">
      <article><span className="section-label">基础</span><h2>日常练习</h2><p>使用五种题型按固定种子抽题，主观题由本地语义模型判分。</p><button className="button button--primary" disabled={busy || !details?.readyQuestionCount} onClick={() => void startPractice()}>开始练习</button></article>
      <article><span className="section-label">计划</span><h2>知识图谱复习</h2><p>按当前 PlanGraph 选题，完成后把结果交给既有 SM-2 掌握度链路。</p><button className="button button--quiet" disabled={busy || !smartReviewAvailable} onClick={() => void startPractice('SMART_REVIEW')}>{smartReviewAvailable ? '按计划复习' : '先建立匹配的复习计划'}</button></article>
      <article><span className="section-label">沉浸</span><h2>故事复习</h2><p>把现有视觉小说生成功能作为本项目的复习方式，沿用同一知识图谱计划。</p>{smartReviewAvailable ? <Link className="button button--quiet" to="/review">进入故事复习</Link> : <button className="button button--quiet" disabled>先建立匹配的复习计划</button>}</article>
      <article><span className="section-label">测验</span><h2>随机试卷</h2><p>从已发布题目中按种子组卷，题目顺序在会话创建后保持不变。</p><button className="button button--quiet" disabled={busy || !details?.readyQuestionCount} onClick={() => void startExam()}>生成并开始</button></article>
    </section>
    <section className="practice-tools workspace-card"><header><span className="section-label">题库工具</span><h2>从复习资料建立题库</h2></header><div>
      <button className="button button--primary" disabled={busy || !details} onClick={() => void generateQuestions()}>从资料生成 30 道草稿</button>
      <label>整卷资料<select value={examMaterialId} onChange={(event) => setExamMaterialId(event.target.value)}>{materials.map((item) => <option key={item.materialId} value={item.materialId}>{item.displayName}</option>)}</select></label>
      <button className="button button--quiet" disabled={busy || !examMaterialId} onClick={() => void importExam()}>识别整卷题目</button>
      <button className="button button--quiet" disabled={busy || !details} onClick={() => void exportPackage()}>导出项目包</button>
      <label>共享版本<input value={packageVersion} maxLength={64} onChange={(event) => setPackageVersion(event.target.value)} /></label>
      <button className="button button--quiet" disabled={busy || !details || !packageVersion.trim()} onClick={() => void publishPackage()}>发布到资源中心</button>
    </div></section>
    <div className="practice-project-layout">
      <section className="workspace-card"><header><span className="section-label">题库</span><h2>项目题目</h2></header><div className="practice-question-list">
        {questions.map((question, index) => <article key={question.questionId}><span>{String(index + 1).padStart(2, '0')}</span><div><strong>{question.prompt}</strong><small>{kindLabels[question.kind]} · {question.score} 分 · 难度 {question.difficulty}</small></div>{question.status === 'READY' ? <i>可练习</i> : <button className="button button--quiet" disabled={busy} onClick={() => void publishQuestion(question)}>确认可练习</button>}</article>)}
        {questions.length === 0 ? <p className="empty-row">题库为空。可从资料生成草稿，也可手工录入。</p> : null}
      </div></section>
      <form className="form-section practice-question-create" onSubmit={(event) => void addQuestion(event)}><header><span className="section-label">录入</span><h2>加入题目</h2><p>答案只在编辑和作答后显示。</p></header>
        <label>题型<select value={kind} onChange={(event) => setKind(event.target.value as PracticeQuestionKind)}>{Object.entries(kindLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
        <label>题干<textarea rows={4} required value={prompt} onChange={(event) => setPrompt(event.target.value)} /></label>
        {kind === 'SINGLE_CHOICE' ? <label>选项（每行如 A. 内容）<textarea rows={5} required value={options} onChange={(event) => setOptions(event.target.value)} /></label> : null}
        <label>{kind === 'FILL_BLANK' ? '正确答案（每空一行）' : '正确答案'}<textarea rows={3} required value={answer} onChange={(event) => setAnswer(event.target.value)} /></label>
        <button className="button button--primary" disabled={busy}>{busy ? '正在保存' : '保存并发布'}</button>
      </form>
    </div>
  </main></AppShell>
}
