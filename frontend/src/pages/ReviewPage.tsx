import { useEffect, useMemo, useRef, useState } from 'react'
import { Link } from 'react-router'
import AppShell, { PageHeader } from '../components/AppShell'
import { api } from '../lib/api'
import { pollUntil } from '../lib/poll'
import { loadRuntime } from '../lib/runtime'
import { readSession } from '../lib/session'
import { createUuidV4 } from '../lib/uuid'
import { readWorkflow, updateWorkflow } from '../lib/workflow'
import type {
  AnswerResult,
  Difficulty,
  GameChoice,
  GameGenerationJob,
  GamePackage,
  GameScene,
  GameStyle,
  ReviewResult,
  ReviewSession,
  RuntimeManifest,
  WasmAdapter,
} from '../types/api'

interface AttemptState {
  answers: AnswerResult[]
  attemptsByQuestion: Record<string, number>
}

function generationError(error: { message: string } | null): Error {
  return new Error(error?.message || '游戏生成失败。')
}

function attemptsFromAnswers(answers: AnswerResult[]): Record<string, number> {
  return Object.fromEntries(answers.map((answer) => [answer.questionId, answer.attemptNumber]))
}

function runtimeEvent(events: Array<Record<string, unknown>>, type: string) {
  return events.find((event) => event.type === type)
}

function createShellSession(gamePackage: GamePackage): ReviewSession {
  const userId = readSession()?.session.userId
  if (!userId) throw new Error('登录会话已失效，请重新登录。')
  return {
    sessionId: createUuidV4(),
    userId,
    packageId: gamePackage.packageId,
    reviewPlanId: gamePackage.reviewPlanId,
    snapshotVersion: gamePackage.snapshotVersion,
    status: 'CREATED',
    currentSceneId: null,
    progressVersion: 0,
    startedAt: new Date().toISOString(),
    completedAt: null,
  }
}

export default function ReviewPage() {
  const initial = readWorkflow()
  const adapterRef = useRef<WasmAdapter | null>(null)
  const resultKeyRef = useRef(initial.resultIdempotencyKey || createUuidV4())
  const startedAtRef = useRef(Date.now())
  const sceneStartedAtRef = useRef(Date.now())
  const [style, setStyle] = useState<GameStyle>(initial.gameStyle || 'CAMPUS')
  const [difficulty, setDifficulty] = useState<Difficulty>(initial.gameDifficulty || 'STANDARD')
  const [generation, setGeneration] = useState<GameGenerationJob | undefined>(initial.gameGeneration)
  const [gamePackage, setGamePackage] = useState<GamePackage | undefined>(initial.gamePackage)
  const [session, setSession] = useState<ReviewSession | undefined>(initial.reviewSession)
  const [runtimeManifest, setRuntimeManifest] = useState<RuntimeManifest>()
  const [sceneId, setSceneId] = useState(initial.reviewSession?.currentSceneId || initial.gamePackage?.entrySceneId || '')
  const [visitedSceneIds, setVisitedSceneIds] = useState<string[]>(initial.visitedSceneIds?.length ? initial.visitedSceneIds : sceneId ? [sceneId] : [])
  const [attempt, setAttempt] = useState<AttemptState>({
    answers: initial.answerResults || [],
    attemptsByQuestion: attemptsFromAnswers(initial.answerResults || []),
  })
  const [busy, setBusy] = useState(false)
  const [progress, setProgress] = useState(initial.gamePackage ? '游戏包已准备好，正在等待渲染器。' : '选择风格后开始生成。')
  const [error, setError] = useState('')
  const [result, setResult] = useState<ReviewResult>()
  const [shellCompleted, setShellCompleted] = useState(false)
  const [adapterVersion, setAdapterVersion] = useState(0)

  const scene = useMemo(
    () => gamePackage?.scenes.find((item) => item.sceneId === sceneId),
    [gamePackage, sceneId],
  )

  useEffect(() => () => adapterRef.current?.dispose(), [])

  useEffect(() => {
    if (!adapterVersion) return
    let frameId = 0
    let previous = performance.now()
    const frame = (now: number) => {
      const adapter = adapterRef.current
      if (!adapter) return
      try {
        adapter.renderFrame(Math.min(100, Math.max(0, now - previous)))
      } catch (reason) {
        setError(reason instanceof Error ? reason.message : '渲染运行时已停止。')
        return
      }
      previous = now
      frameId = window.requestAnimationFrame(frame)
    }
    frameId = window.requestAnimationFrame(frame)
    return () => window.cancelAnimationFrame(frameId)
  }, [adapterVersion])

  useEffect(() => {
    if (!initial.resultIdempotencyKey) updateWorkflow({ resultIdempotencyKey: resultKeyRef.current })
  }, [initial.resultIdempotencyKey])

  async function attachRuntime(manifest: RuntimeManifest, pack: GamePackage, reviewSession: ReviewSession) {
    adapterRef.current?.dispose()
    adapterRef.current = await loadRuntime(manifest, pack, reviewSession)
    setAdapterVersion((value) => value + 1)
    setRuntimeManifest(manifest)
    const nextSceneId = reviewSession.currentSceneId || pack.entrySceneId
    const savedVisited = readWorkflow().visitedSceneIds || []
    const nextVisited = savedVisited.includes(nextSceneId) ? savedVisited : [...savedVisited, nextSceneId]
    setSceneId(nextSceneId)
    setVisitedSceneIds(nextVisited)
    updateWorkflow({ visitedSceneIds: nextVisited })
    sceneStartedAtRef.current = Date.now()
  }

  async function completeGeneration(accepted: GameGenerationJob, plan = readWorkflow().plan) {
    if (!plan) throw new Error('当前复习计划不存在，请重新创建。')
    const completed = accepted.status === 'SUCCEEDED'
      ? accepted
      : await pollUntil(
        () => api.getGameGeneration(accepted.generationId),
        (job) => job.status === 'SUCCEEDED' || job.status === 'FAILED',
        (job) => {
          setGeneration(job)
          updateWorkflow({ gameGeneration: job })
          setProgress(`GalGame 正在生成… ${job.progress}%`)
        },
      )
    setGeneration(completed)
    updateWorkflow({ gameGeneration: completed })
    if (completed.status === 'FAILED') throw generationError(completed.error)
    if (!completed.packageId) throw new Error('生成任务完成但没有返回 packageId。')

    const manifest = await api.getGamePackage(completed.packageId)
    const pack = await api.getGamePackageContent(manifest.contentUrl)
    if (pack.reviewPlanId !== plan.reviewPlanId || pack.snapshotVersion !== plan.snapshotVersion) {
      throw new Error('游戏包与当前复习计划的不可变快照不一致。')
    }
    const renderManifest = await api.getRuntimeManifest()
    const reviewSession = renderManifest.reviewSessionsAvailable === false
      ? createShellSession(pack)
      : await api.createReviewSession(pack.packageId, renderManifest.wasmVersion)
    if (reviewSession.reviewPlanId !== pack.reviewPlanId || reviewSession.snapshotVersion !== pack.snapshotVersion) {
      throw new Error('复习会话与游戏包快照不一致。')
    }
    const resultIdempotencyKey = createUuidV4()
    resultKeyRef.current = resultIdempotencyKey
    setAttempt({ answers: [], attemptsByQuestion: {} })
    setShellCompleted(false)
    setGamePackage(pack)
    setSession(reviewSession)
    updateWorkflow({ gameGeneration: completed, gameManifest: manifest, gamePackage: pack, reviewSession, visitedSceneIds: [reviewSession.currentSceneId || pack.entrySceneId], answerResults: [], resultIdempotencyKey })
    await attachRuntime(renderManifest, pack, reviewSession)
    setProgress('渲染器已加载，可以开始复习。')
    startedAtRef.current = Date.now()
  }

  async function generateAndStart() {
    const workflow = readWorkflow()
    if (!workflow.plan) {
      setError('请先从资料页创建复习计划。')
      return
    }
    setBusy(true)
    setError('')
    try {
      setProgress('GalGame 正在根据计划组织剧情与题目…')
      const accepted = await api.createGameGeneration(workflow.plan, style, difficulty)
      setGeneration(accepted)
      updateWorkflow({ gameGeneration: accepted, gameStyle: style, gameDifficulty: difficulty, gameManifest: undefined, gamePackage: undefined, reviewSession: undefined, answerResults: [], resultIdempotencyKey: undefined })
      await completeGeneration(accepted, workflow.plan)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '游戏准备失败。')
    } finally {
      setBusy(false)
    }
  }

  async function resumeGeneration() {
    const workflow = readWorkflow()
    if (!workflow.gameGeneration || !workflow.plan) return
    setBusy(true)
    setError('')
    setProgress('正在恢复游戏生成任务。')
    try {
      const current = await api.getGameGeneration(workflow.gameGeneration.generationId)
      await completeGeneration(current, workflow.plan)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '生成任务恢复失败。')
    } finally {
      setBusy(false)
    }
  }

  async function resumeRuntime() {
    const workflow = readWorkflow()
    if (!workflow.gamePackage || !workflow.reviewSession) return
    setBusy(true)
    setError('')
    try {
      const manifest = await api.getRuntimeManifest()
      const currentSession = manifest.reviewSessionsAvailable === false
        ? workflow.reviewSession
        : await api.getReviewSession(workflow.reviewSession.sessionId)
      await attachRuntime(manifest, workflow.gamePackage, currentSession)
      setSession(currentSession)
      setProgress('已恢复当前复习会话。')
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '会话恢复失败。')
    } finally {
      setBusy(false)
    }
  }

  function createAnswer(choice: GameChoice, attemptId: string, occurredAt: string, event?: Record<string, unknown>): AnswerResult | null {
    if (choice.answerKind !== 'CHOICE' || typeof choice.correct !== 'boolean') return null
    const responseTimeMs = Math.max(0, Date.now() - sceneStartedAtRef.current)
    const attemptNumber = Math.max((attempt.attemptsByQuestion[choice.questionId] || 0) + 1, typeof event?.attemptNumber === 'number' ? event.attemptNumber : 1)
    const correct = typeof event?.correct === 'boolean' ? event.correct : choice.correct
    const quality = correct ? (attemptNumber > 1 ? 3 : 5) : 0
    return {
      attemptId,
      questionId: choice.questionId,
      knowledgePointId: choice.knowledgePointId,
      answerKind: 'CHOICE',
      choiceId: choice.choiceId,
      correct,
      quality,
      scoreDelta: choice.scoreDelta,
      responseTimeMs,
      hintsUsed: 0,
      attemptNumber,
      occurredAt,
    }
  }

  async function saveSceneProgress(nextSceneId: string, nextVisited: string[]): Promise<ReviewSession | undefined> {
    if (!session || !adapterRef.current) return undefined
    if (runtimeManifest?.reviewSessionsAvailable === false) {
      const nextSession: ReviewSession = {
        ...session,
        currentSceneId: nextSceneId,
        progressVersion: session.progressVersion + 1,
        status: 'RUNNING',
      }
      setSession(nextSession)
      updateWorkflow({ reviewSession: nextSession })
      return nextSession
    }
    const saved = await api.saveProgress(session.sessionId, {
      expectedVersion: session.progressVersion,
      currentSceneId: nextSceneId,
      visitedSceneIds: nextVisited,
      runtimeState: adapterRef.current.serializeState(),
    })
    const nextSession = { ...session, currentSceneId: saved.currentSceneId, progressVersion: saved.version, status: 'RUNNING' as const }
    setSession(nextSession)
    updateWorkflow({ reviewSession: nextSession })
    return nextSession
  }

  async function choose(choice: GameChoice) {
    if (!scene || !session || busy) return
    setBusy(true)
    setError('')
    try {
      const attemptId = createUuidV4()
      const occurredAt = new Date().toISOString()
      const events = adapterRef.current?.dispatchInput({ type: 'CHOICE_SELECTED', choiceId: choice.choiceId, attemptId, occurredAt }) || []
      if (adapterRef.current?.engine === 'wasm' && !events.length) {
        const runtimeError = adapterRef.current.lastError?.()
        throw new Error(runtimeError?.message || '渲染运行时拒绝了当前选择。')
      }
      const answer = createAnswer(choice, attemptId, occurredAt, runtimeEvent(events, 'ANSWER_RECORDED'))
      if (answer) {
        const nextAnswers = [...attempt.answers, answer]
        setAttempt((current) => ({
          answers: [...current.answers, answer],
          attemptsByQuestion: { ...current.attemptsByQuestion, [answer.questionId]: answer.attemptNumber },
        }))
        updateWorkflow({ answerResults: nextAnswers })
      }
      if (runtimeManifest?.reviewSessionsAvailable !== false) {
        void api.appendEvents(session.sessionId, [{
          clientEventId: createUuidV4(),
          type: 'CHOICE_SELECTED',
          occurredAt,
          payload: {
            sceneId: scene.sceneId,
            choiceId: choice.choiceId,
            questionId: choice.questionId,
            knowledgePointId: choice.knowledgePointId,
          },
        }]).catch(() => undefined)
      }
      const entered = runtimeEvent(events, 'SCENE_ENTERED')
      const nextSceneId = typeof entered?.sceneId === 'string' ? entered.sceneId : choice.nextSceneId
      const completedByRuntime = Boolean(runtimeEvent(events, 'SESSION_COMPLETED'))
      if (nextSceneId && !completedByRuntime) {
        const nextVisited = visitedSceneIds.includes(nextSceneId) ? visitedSceneIds : [...visitedSceneIds, nextSceneId]
        await saveSceneProgress(nextSceneId, nextVisited)
        setVisitedSceneIds(nextVisited)
        updateWorkflow({ visitedSceneIds: nextVisited })
        setSceneId(nextSceneId)
        sceneStartedAtRef.current = Date.now()
      } else {
        const answers = answer ? [...attempt.answers, answer] : attempt.answers
        const savedSession = await saveSceneProgress(scene.sceneId, visitedSceneIds)
        await finish(answers, savedSession)
      }
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '选择保存失败。')
    } finally {
      setBusy(false)
    }
  }

  async function finish(answers = attempt.answers, sessionOverride?: ReviewSession) {
    const activeSession = sessionOverride || session
    if (!activeSession || !gamePackage) return
    setBusy(true)
    setError('')
    try {
      if (runtimeManifest?.reviewSessionsAvailable === false) {
        const completedSession = { ...activeSession, status: 'COMPLETED' as const, completedAt: new Date().toISOString() }
        setSession(completedSession)
        updateWorkflow({ reviewSession: completedSession })
        setShellCompleted(true)
        setProgress('C++/JS 基础壳已完成本地体验；本次结果未提交，掌握度不会更新。')
        return
      }
      const completed = await api.submitReviewResult(activeSession.sessionId, {
        expectedProgressVersion: activeSession.progressVersion,
        idempotencyKey: resultKeyRef.current,
        reviewPlanId: gamePackage.reviewPlanId,
        snapshotVersion: gamePackage.snapshotVersion,
        answerResults: answers,
        durationSeconds: Math.max(0, Math.round((Date.now() - startedAtRef.current) / 1_000)),
      })
      setResult(completed)
      const completedSession = { ...activeSession, status: 'COMPLETED' as const, completedAt: new Date().toISOString() }
      setSession(completedSession)
      updateWorkflow({ reviewSession: completedSession })
      setProgress(completed.status === 'DUPLICATE' ? '这次结果已经提交过。' : '本次复习结果已提交。')
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '结果提交失败。')
    } finally {
      setBusy(false)
    }
  }

  async function finishCurrentScene() {
    if (!scene) return
    setBusy(true)
    try {
      const events = adapterRef.current?.dispatchInput({ type: 'ADVANCE' }) || []
      if (adapterRef.current?.engine === 'wasm' && !runtimeEvent(events, 'SESSION_COMPLETED')) {
        const runtimeError = adapterRef.current.lastError?.()
        throw new Error(runtimeError?.message || '渲染运行时无法结束当前场景。')
      }
      const savedSession = await saveSceneProgress(scene.sceneId, visitedSceneIds)
      await finish(attempt.answers, savedSession)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '进度保存失败。')
      setBusy(false)
    }
  }

  function resetGame() {
    adapterRef.current?.dispose()
    adapterRef.current = null
    resultKeyRef.current = createUuidV4()
    setGamePackage(undefined)
    setGeneration(undefined)
    setSession(undefined)
    setRuntimeManifest(undefined)
    setSceneId('')
    setVisitedSceneIds([])
    setAttempt({ answers: [], attemptsByQuestion: {} })
    setResult(undefined)
    setShellCompleted(false)
    setError('')
    setProgress('可以调整风格与难度，再生成一次。')
    updateWorkflow({ gameGeneration: undefined, gameManifest: undefined, gamePackage: undefined, reviewSession: undefined, visitedSceneIds: undefined, answerResults: undefined, resultIdempotencyKey: resultKeyRef.current })
  }

  if (!initial.plan) {
    return <AppShell><main className="page review-page"><PageHeader title="复习" description="选择复习范围并生成计划后，即可开始本次复习。" /><section className="empty-state"><h2>还没有复习计划</h2><p>先选择一份资料，再确定本次需要测试或学习的章节。</p><Link className="button button--primary" to="/materials">创建计划</Link></section></main></AppShell>
  }

  return (
    <AppShell>
    <main className="page review-page">
      <PageHeader title={initial.material?.displayName || '本次复习'} description={`${initial.plan.type === 'ASSESSMENT' ? '全面测试' : '章节学习'} · ${initial.plan.nodes.length} 个知识节点`} actions={<Link className="button" to="/knowledge-graph">查看图谱</Link>} />

      {!gamePackage || !session || !adapterRef.current ? (
        <section className="review-setup workspace-card">
          <span className="section-label">生成设置</span>
          <h2>准备 GalGame</h2>
          <p>预计 {initial.plan.estimatedQuestionCount} 道题。故事风格不会改变本次复习的知识范围。</p>
          <label>故事风格<select value={style} onChange={(event) => setStyle(event.target.value as GameStyle)}><option value="CAMPUS">校园</option><option value="FANTASY">幻想</option><option value="SCIENCE">科幻</option></select></label>
          <label>难度<select value={difficulty} onChange={(event) => setDifficulty(event.target.value as Difficulty)}><option value="BASIC">基础</option><option value="STANDARD">标准</option><option value="ADVANCED">进阶</option></select></label>
          {gamePackage && session
            ? <button className="primary-button" type="button" disabled={busy} onClick={() => void resumeRuntime()}>恢复会话</button>
            : generation && generation.status !== 'FAILED'
              ? <button className="primary-button" type="button" disabled={busy} onClick={() => void resumeGeneration()}>{busy ? '恢复中…' : `继续生成（${generation.progress}%）`}</button>
              : <button className="primary-button" type="button" disabled={busy} onClick={() => void generateAndStart()}>{busy ? '准备中…' : '生成并开始'}</button>}
        </section>
      ) : result || shellCompleted ? (
        <section className="review-complete workspace-card"><p>复习完成</p><h2>{shellCompleted ? '本地体验已完成' : result?.status === 'ACCEPTED' ? '结果已提交' : '结果已去重'}</h2><p>{shellCompleted ? `本地记录 ${attempt.answers.length} 条作答。当前 RenderService 仅提供基础壳，本次结果没有提交，掌握度不会更新。` : `共记录 ${attempt.answers.length} 条作答证据。`}</p><div className="completion-actions"><Link className="button" to="/knowledge-graph">查看知识图谱</Link><button className="button button--primary" type="button" onClick={resetGame}>重新生成</button></div></section>
      ) : scene ? (
        <section className="game-stage">
          <div className="game-stage__meta"><span>{runtimeManifest?.wasmVersion} · {adapterRef.current?.engine === 'wasm' ? 'WASM' : '兼容模式'}</span><span>{visitedSceneIds.length} 个场景已访问</span></div>
          <article className="dialogue-panel">
            {scene.title ? <h2>{scene.title}</h2> : null}
            {scene.dialogue.map((line, index) => <div className="dialogue-line" key={`${line.speakerId}-${index}`}><strong>{line.speakerId}</strong><p>{line.text}</p></div>)}
          </article>
          {scene.choices.length ? <div className="choice-list">{scene.choices.map((choice) => <button key={choice.choiceId} disabled={busy} type="button" onClick={() => void choose(choice)}>{choice.text}</button>)}</div> : <button className="primary-button" disabled={busy} type="button" onClick={() => void finishCurrentScene()}>结束复习</button>}
        </section>
      ) : <section className="workspace-card"><h2>场景不存在</h2><p>游戏包没有找到当前场景，请重新生成。</p></section>}

      <p className={error ? 'status-line status-line--error' : 'status-line'} aria-live="polite">{error || progress}</p>
    </main>
    </AppShell>
  )
}
