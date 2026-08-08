import { FormEvent, useEffect, useMemo, useState } from 'react'
import { Link, useLocation, useNavigate, useParams } from 'react-router'
import AppShell, { PageHeader } from '../components/AppShell'
import { api } from '../lib/api'
import { handleCreditsRequired } from '../lib/credits'
import { pollUntil } from '../lib/poll'
import { updateWorkflow } from '../lib/workflow'
import type { Chapter, KnowledgeGraphSummary, KnowledgePoint, Material, PlanGraph, PracticeProjectDetails, PracticeQuestion, PracticeQuestionKind } from '../types/api'

const kindLabels: Record<PracticeQuestionKind, string> = { SINGLE_CHOICE: '单选题', FILL_BLANK: '填空题', TRUE_FALSE: '判断题', TERM_DEFINITION: '名词解释', ESSAY: '简答题' }

export default function PracticeProjectPage() {
  const { projectId = '' } = useParams(); const navigate = useNavigate(); const location = useLocation()
  const [details, setDetails] = useState<PracticeProjectDetails | null>(null); const [questions, setQuestions] = useState<PracticeQuestion[]>([])
  const [materials, setMaterials] = useState<Material[]>([]); const [graph, setGraph] = useState<KnowledgeGraphSummary>(); const [chapters, setChapters] = useState<Chapter[]>([])
  const [points, setPoints] = useState<KnowledgePoint[]>([]); const [selectedChapterIds, setSelectedChapterIds] = useState<string[]>([])
  const [examMaterialId, setExamMaterialId] = useState(''); const [kind, setKind] = useState<PracticeQuestionKind>('SINGLE_CHOICE')
  const [prompt, setPrompt] = useState(''); const [answer, setAnswer] = useState(''); const [options, setOptions] = useState('A. \nB. ')
  const [knowledgePointId, setKnowledgePointId] = useState(''); const [bindingSelections, setBindingSelections] = useState<Record<string, string>>({})
  const [message, setMessage] = useState((location.state as { message?: string } | null)?.message || ''); const [busy, setBusy] = useState(false); const [packageVersion, setPackageVersion] = useState('1.0.0')
  const pointTitles = useMemo(() => Object.fromEntries(points.map((point) => [point.pointId, point.title])), [points])

  async function load() {
    const [project, page, materialItems] = await Promise.all([api.getPracticeProject(projectId), api.listPracticeQuestions(projectId), api.getAllMaterials()])
    const projectMaterials = materialItems.filter((item) => project.project.materialIds.includes(item.materialId))
    setDetails(project); setQuestions(page.items); setMaterials(projectMaterials); setExamMaterialId((current) => current || project.project.materialIds[0] || '')
    if (!project.project.graphId) {
      setGraph(undefined); setChapters([]); setPoints([])
      updateWorkflow({ projectId: project.project.projectId, material: projectMaterials[0], graph: undefined, chapters: undefined })
      return
    }
    const [summary, chapterItems, pointItems] = await Promise.all([
      api.getKnowledgeGraph(project.project.graphId), api.getChapters(project.project.graphId), api.getAllPoints(project.project.graphId),
    ])
    setGraph(summary); setChapters(chapterItems); setPoints(pointItems)
    setSelectedChapterIds((current) => current.length ? current.filter((id) => chapterItems.some((chapter) => chapter.chapterId === id)) : chapterItems.map((chapter) => chapter.chapterId))
    setKnowledgePointId((current) => current || pointItems[0]?.pointId || '')
    updateWorkflow({ projectId: project.project.projectId, material: projectMaterials[0], graph: summary, chapters: chapterItems })
  }

  useEffect(() => { void load().catch((error: unknown) => setMessage(error instanceof Error ? error.message : '研习册读取失败。')) }, [projectId])

  async function run(action: () => Promise<void>, fallback: string) {
    setBusy(true); setMessage(''); try { await action() } catch (error) { if (!handleCreditsRequired(error)) setMessage(error instanceof Error ? error.message : fallback) } finally { setBusy(false) }
  }

  async function ensureGraphScope() {
    if (!details) throw new Error('研习册尚未载入。')
    if (details.project.graphId && graph && chapters.length) return { project: details.project, graph, chapters }
    const materialId = details.project.materialIds[0]
    if (!materialId) throw new Error('本册没有可用于识网的资料。')
    setMessage('正在为本册恢复知识脉络。')
    const accepted = await api.createGraphBuild(details.project.projectId, materialId, details.project.subjectCode || undefined)
    const completed = await pollUntil(() => api.getGraphBuild(accepted.buildId),
      (job) => job.status === 'SUCCEEDED' || job.status === 'FAILED',
      (job) => setMessage(`正在为本册识网 · ${job.progress}%`))
    if (completed.status === 'FAILED') throw new Error(completed.error?.message || '本册知识脉络建立失败。')
    if (!completed.graphId || completed.studyProjectId !== details.project.projectId) throw new Error('构图完成，但返回的研习册作用域不匹配。')
    const summary = await api.getKnowledgeGraph(completed.graphId)
    if (summary.studyProjectId !== details.project.projectId) throw new Error('知识图谱不属于本研习册。')
    const updated = await api.updatePracticeProject(details.project, { graphId: completed.graphId })
    const chapterItems = await api.getChapters(completed.graphId)
    if (!chapterItems.length) throw new Error('本册知识脉络没有可用章节。')
    setDetails((current) => current ? { ...current, project: updated } : current)
    setGraph(summary); setChapters(chapterItems); setSelectedChapterIds(chapterItems.map((chapter) => chapter.chapterId))
    updateWorkflow({ projectId: updated.projectId, material: materials[0], graph: summary, chapters: chapterItems })
    return { project: updated, graph: summary, chapters: chapterItems }
  }

  function requireScope(availableChapters: Chapter[], useAllChapters = false) {
    const availableIds = new Set(availableChapters.map((chapter) => chapter.chapterId))
    const selected = selectedChapterIds.filter((id) => availableIds.has(id))
    const chapterIds = useAllChapters || selected.length === 0 ? availableChapters.map((chapter) => chapter.chapterId) : selected
    if (!chapterIds.length) throw new Error('请至少选择一个章节。')
    return chapterIds
  }

  function requireReadyQuestions() {
    if ((details?.readyQuestionCount ?? 0) < 1) {
      throw new Error('本册还没有已核对入库的题目。请先在“成题”区生成或录入题目，并核对知识点后入库。')
    }
  }

  async function createPlan(maxQuestions: number, useAllChapters = false): Promise<PlanGraph> {
    const scope = await ensureGraphScope()
    return api.createAssessmentPlan(scope.graph.graphId, requireScope(scope.chapters, useAllChapters), { maxQuestions, coverageTarget: 1, maximumInferenceDepth: 3 })
  }

  async function createQuestionBankPlan(): Promise<PlanGraph> {
    const scope = await ensureGraphScope()
    return api.createLearningPlan(scope.graph.graphId, requireScope(scope.chapters, true), {
      maxPoints: 1000, maximumDependencyDepth: 8,
    })
  }

  async function addQuestion(event: FormEvent) {
    event.preventDefault(); await run(async () => {
      if (!knowledgePointId) throw new Error('请选择题目对应的知识点。')
      const parsedOptions = kind === 'SINGLE_CHOICE' ? options.split('\n').map((line) => line.trim()).filter(Boolean).map((line) => {
        const match = line.match(/^([A-Za-z0-9]+)[.、)]\s*(.+)$/); return { id: match?.[1]?.toUpperCase() || '', text: match?.[2] || '' }
      }) : []
      const correctAnswers = kind === 'FILL_BLANK' ? answer.split('\n').map((item) => item.trim()).filter(Boolean) : [answer.trim()]
      await api.createPracticeQuestion(projectId, { kind, prompt, options: parsedOptions, correctAnswers, score: 5, difficulty: 3, knowledgePointId, status: 'READY' })
      setPrompt(''); setAnswer(''); await load(); setMessage('题目已签入本册题库。')
    }, '题目保存失败。')
  }

  async function startPractice(useAllChapters = false) {
    await run(async () => {
      requireReadyQuestions()
      const plan = await createPlan(Math.min(20, Math.max(1, details?.readyQuestionCount || 20)), useAllChapters)
      if (plan.estimatedQuestionCount < 1) throw new Error('当前范围没有可复习的知识点。')
      const session = await api.createPracticeSession({ projectId, mode: 'SMART_REVIEW', questionCount: plan.estimatedQuestionCount,
        reviewPlanId: plan.reviewPlanId, snapshotVersion: plan.snapshotVersion })
      navigate(`/practice/${session.sessionId}`)
    }, '温习创建失败。')
  }

  async function generateQuestions() {
    await run(async () => {
      const plan = await createQuestionBankPlan()
      const job = await api.generatePracticeQuestions(projectId, { reviewPlanId: plan.reviewPlanId, snapshotVersion: plan.snapshotVersion,
        kinds: ['SINGLE_CHOICE', 'FILL_BLANK', 'TERM_DEFINITION', 'ESSAY'] })
       await load(); setMessage(job.createdCount > 0 ? `已按知识脉络生成并收入 ${job.createdCount} 道题。` : job.diagnostics[0]?.message || '没有生成可用题目。')
    }, '题库生成失败。')
  }

  async function importExam() {
    await run(async () => { const job = await api.importExam(projectId, examMaterialId); await load(); setMessage(job.createdCount > 0 ? `整卷识别完成，新增 ${job.createdCount} 道待补签草稿。` : job.diagnostics[0]?.message || '没有识别到题目。') }, '整卷导入失败。')
  }

  async function startExam() {
    await run(async () => {
      requireReadyQuestions()
      const plan = await createPlan(Math.min(30, Math.max(1, details?.readyQuestionCount || 30)), true)
      const paper = await api.createExamPaper(projectId, { title: `${details?.project.name || '本册'}试卷`, questionCount: plan.estimatedQuestionCount,
        durationSeconds: 3600, reviewPlanId: plan.reviewPlanId, snapshotVersion: plan.snapshotVersion })
      const session = await api.createPracticeSession({ projectId, mode: 'EXAM', examPaperId: paper.examPaperId,
        reviewPlanId: plan.reviewPlanId, snapshotVersion: plan.snapshotVersion })
      navigate(`/practice/${session.sessionId}`)
    }, '试卷创建失败。')
  }

  async function startStory() {
    await run(async () => {
      const plan = await createPlan(6)
      updateWorkflow({ projectId, plan, gameGeneration: undefined, gameStyle: undefined,
        gameDifficulty: undefined, gameManifest: undefined, gamePackage: undefined, reviewSession: undefined, visitedSceneIds: undefined,
        answerResults: undefined, resultIdempotencyKey: undefined })
      navigate(`/projects/${projectId}/story`)
    }, '故事回响准备失败。')
  }

  async function exportPackage() {
    await run(async () => { const blob = await api.exportPracticePackage(projectId); const url = URL.createObjectURL(blob); const anchor = document.createElement('a'); anchor.href = url; anchor.download = `${details?.project.name || 'practice'}.qzwlp`; anchor.click(); URL.revokeObjectURL(url); setMessage('研习册项目包已导出。') }, '项目包导出失败。')
  }

  async function publishPackage() {
    await run(async () => { await api.publishPracticePackage(projectId, packageVersion, 'PUBLIC'); setMessage(`共享版本 ${packageVersion} 已收入同窗书架。`) }, '共享包发布失败。')
  }

  async function publishQuestion(question: PracticeQuestion) {
    await run(async () => {
      const selectedPointId = question.knowledgePointId || bindingSelections[question.questionId]
      if (!selectedPointId) throw new Error('请先为题目补签知识点。')
      await api.updatePracticeQuestion({ ...question, knowledgePointId: selectedPointId }, 'READY'); await load(); setMessage('草稿已核对并收入正式题库。')
    }, '题目确认失败。')
  }

  const ready = details?.readyQuestionCount ?? 0
  return <AppShell><main className="page practice-project-page">
    <PageHeader title={details?.project.name || '研习册'} description={`${details?.project.subjectCode || '未设置学科'} · ${ready} 道可练习题 · ${points.length} 个知识点`} actions={<Link className="button button--quiet" to="/projects">返回册目</Link>} />
    {message ? <p className="status-line" role="status">{message}</p> : null}

    <section className="practice-tools workspace-card"><header><span className="section-label">择章</span><h2>本次温习范围</h2><p>普通答题、模拟试卷与故事回响都从这里取知识范围，并把结果写回同一份掌握度。</p></header>
      <div className="chapter-actions"><button type="button" onClick={() => setSelectedChapterIds(chapters.map((chapter) => chapter.chapterId))}>全选</button><button type="button" onClick={() => setSelectedChapterIds([])}>清空</button>{details?.project.graphId ? <Link to={`/knowledge-graph?projectId=${encodeURIComponent(projectId)}`}>查看识网</Link> : null}</div>
      <div className="chapter-picker">{chapters.map((chapter) => <label key={chapter.chapterId} style={{ paddingLeft: `${chapter.depth * 14}px` }}><input type="checkbox" checked={selectedChapterIds.includes(chapter.chapterId)} onChange={() => setSelectedChapterIds((current) => current.includes(chapter.chapterId) ? current.filter((id) => id !== chapter.chapterId) : [...current, chapter.chapterId])} /><span>{chapter.title}</span></label>)}</div>
    </section>

    {details && ready === 0 ? <aside className="practice-readiness-note" role="note">
      <div><span className="section-label">题库待成</span><strong>本册还没有可练习题目</strong><p>先生成或手工录入题目，核对答案与知识点并收入正式题库，随后即可开始章节练习、智能复习和模拟试卷。</p></div>
      <a className="button button--quiet" href="#practice-question-tools">前往成题</a>
    </aside> : null}

    <section className="practice-mode-grid" aria-label="温习方式">
      <article><span className="section-label">温故</span><h2>章节练习</h2><p>在所选章节中循知识脉络出题，答题结果更新掌握度与下一次复习时间。</p><button className="button button--primary" aria-busy={busy} disabled={busy || !details} onClick={() => void startPractice()}>开始温习</button></article>
      <article><span className="section-label">循网</span><h2>智能复习</h2><p>先由 SM-2 的到期时间确定复习范围，再沿图谱先修关系覆盖本册值得回看的知识点。</p><button className="button button--quiet" aria-busy={busy} disabled={busy || !details} onClick={() => void startPractice(true)}>温习薄弱处</button></article>
      <article><span className="section-label">回响</span><h2>故事复习</h2><p>把所选知识范围编入视觉小说；故事作答与章节答题使用同一份掌握度记录。</p><button className="button button--quiet" aria-busy={busy} disabled={busy || !details} onClick={() => void startStory()}>进入故事回响</button></article>
      <article><span className="section-label">试锋</span><h2>模拟试卷</h2><p>从已核对且补签知识点的题目中组卷，交卷结果同样形成复习证据。</p><button className="button button--quiet" aria-busy={busy} disabled={busy || !details} onClick={() => void startExam()}>生成并开卷</button></article>
    </section>

    <section className="practice-tools workspace-card" id="practice-question-tools"><header><span className="section-label">成题</span><h2>从复习资料整理题库</h2><p>立册时会自动成题；这里用于追加或失败重试。只有能与知识点和原文精确核对的题目才会收入题库，其余内容只留下诊断。</p></header><div>
      <button className="button button--primary" aria-busy={busy} disabled={busy || !details} onClick={() => void generateQuestions()}>{questions.length === 0 ? '恢复自动成题' : '循知识脉络追加题目'}</button>
      <label>整卷资料<select value={examMaterialId} onChange={(event) => setExamMaterialId(event.target.value)}>{materials.map((item) => <option key={item.materialId} value={item.materialId}>{item.displayName}</option>)}</select></label>
      <button className="button button--quiet" disabled={busy || !examMaterialId} onClick={() => void importExam()}>识别整卷题目</button>
      <button className="button button--quiet" disabled={busy || !details} onClick={() => void exportPackage()}>导出研习册</button>
      <label>共享版本<input value={packageVersion} maxLength={64} onChange={(event) => setPackageVersion(event.target.value)} /></label>
      <button className="button button--quiet" disabled={busy || !details || !packageVersion.trim()} onClick={() => void publishPackage()}>收入同窗书架</button>
    </div></section>

    <div className="practice-project-layout">
      <section className="workspace-card"><header><span className="section-label">题笺</span><h2>本册题库</h2></header><div className="practice-question-list">
        {questions.map((question, index) => <article key={question.questionId}><span>{String(index + 1).padStart(2, '0')}</span><div><strong>{question.prompt}</strong><small>{kindLabels[question.kind]} · {question.score} 分 · 难度 {question.difficulty} · 知识点：{question.knowledgePointId ? pointTitles[question.knowledgePointId] || '待核对' : '待补签'}</small>
          {!question.knowledgePointId ? <select aria-label={`为第 ${index + 1} 题选择知识点`} value={bindingSelections[question.questionId] || ''} onChange={(event) => setBindingSelections((current) => ({ ...current, [question.questionId]: event.target.value }))}><option value="">选择知识点</option>{points.map((point) => <option key={point.pointId} value={point.pointId}>{point.title}</option>)}</select> : null}
        </div>{question.status === 'READY' && question.knowledgePointId ? <i>已入库</i> : <button className="button button--quiet" disabled={busy} onClick={() => void publishQuestion(question)}>{question.knowledgePointId ? '核对入库' : '补签入库'}</button>}</article>)}
        {questions.length === 0 ? <p className="empty-row">题库尚空。可循知识脉络重新成题，也可在右侧手工录入。</p> : null}
      </div></section>
      <form className="form-section practice-question-create" onSubmit={(event) => void addQuestion(event)}><header><span className="section-label">题录</span><h2>手工加入题目</h2><p>每道正式题都须指向一个主知识点，答案只在编辑和作答后显示。</p></header>
        <label>题型<select value={kind} onChange={(event) => setKind(event.target.value as PracticeQuestionKind)}>{Object.entries(kindLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
        <label>知识点<select required value={knowledgePointId} onChange={(event) => setKnowledgePointId(event.target.value)}><option value="">选择知识点</option>{points.map((point) => <option key={point.pointId} value={point.pointId}>{point.title}</option>)}</select></label>
        <label>题干<textarea rows={4} required value={prompt} onChange={(event) => setPrompt(event.target.value)} /></label>
        {kind === 'SINGLE_CHOICE' ? <label>选项（每行如 A. 内容）<textarea rows={5} required value={options} onChange={(event) => setOptions(event.target.value)} /></label> : null}
        <label>{kind === 'FILL_BLANK' ? '正确答案（每空一行）' : '正确答案'}<textarea rows={3} required value={answer} onChange={(event) => setAnswer(event.target.value)} /></label>
        <button className="button button--primary" disabled={busy || !knowledgePointId}>{busy ? '正在保存' : '签入题库'}</button>
      </form>
    </div>
  </main></AppShell>
}
