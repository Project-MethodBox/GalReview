import { useEffect, useMemo, useRef, useState } from 'react'
import { Link, useNavigate } from 'react-router'
import AppShell, { PageHeader } from '../components/AppShell'
import LoadingIndicator from '../components/LoadingIndicator'
import { api } from '../lib/api'
import { handleCreditsRequired } from '../lib/credits'
import { pollUntil } from '../lib/poll'
import { loadRuntime } from '../lib/runtime'
import { readSession } from '../lib/session'
import { createUuidV4 } from '../lib/uuid'
import { clearCompletedReview, readWorkflow, updateWorkflow } from '../lib/workflow'
import type {
  AnswerResult,
  Difficulty,
  GameChoice,
  GameGenerationJob,
  GamePackage,
  GameScene,
  GameStyle,
  MasteryRecord,
  ReviewResult,
  ReviewSession,
  RuntimeManifest,
  WasmAdapter,
} from '../types/api'

interface AttemptState {
  answers: AnswerResult[]
  attemptsByQuestion: Record<string, number>
}

interface ChoiceFeedback {
  correct: boolean
  selectedText: string
  correctText: string | null
  knowledgeTitle: string
  nextSceneId: string | null
  nextVisitedSceneIds: string[]
  answers: AnswerResult[]
  savedSession?: ReviewSession
}

interface ReviewKnowledgeSummary {
  pointId: string
  title: string
  masteryScore: number
  nextReviewAt: string | null
}

function CompletionActionIcon({ kind }: { kind: 'restart' | 'graph' | 'plan' }) {
  if (kind === 'restart') return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4.5 9A8 8 0 1 1 5 16.2" /><path d="M4.5 4.5V9H9" /></svg>
  if (kind === 'graph') return <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="5" r="2.3" /><circle cx="6" cy="17" r="2.3" /><circle cx="18" cy="17" r="2.3" /><path d="m10.9 7-3.8 7.9M13.1 7l3.8 7.9M8.3 17h7.4" /></svg>
  return <svg viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="4" width="16" height="16" rx="4" /><path d="M12 8v8M8 12h8" /></svg>
}

function generationError(error: { message: string } | null): Error {
  return new Error(error?.message || '游戏生成失败。')
}

function attemptsFromAnswers(answers: AnswerResult[]): Record<string, number> {
  return Object.fromEntries(answers.map((answer) => [answer.questionId, answer.attemptNumber]))
}

const fixedMockSceneBackgrounds = ['/bg.png', '/bg_1.png', '/bg2.png', '/bg3.png', '/bg4.png']
const BGM_VOLUME = 0.18
const BGM_DUCKED_VOLUME = 0.06
const CHARACTER_VOICE_VOLUME = 0.9
const CHARACTER_VOICE_PLAYBACK_RATE = 1.3
// 后端最多执行两次、每次 120 秒的叙事模型请求；为排队、校验与持久化预留充足余量。
const gameGenerationPollTimeoutMs = 600_000

function preloadBackground(source: string): Promise<void> {
  return new Promise((resolve) => {
    const image = new Image()
    image.decoding = 'async'
    const complete = () => {
      if (typeof image.decode === 'function') {
        void image.decode().catch(() => undefined).finally(resolve)
      } else {
        resolve()
      }
    }
    image.addEventListener('load', complete, { once: true })
    image.addEventListener('error', () => resolve(), { once: true })
    image.src = source
    if (image.complete) complete()
  })
}

function runtimeEvent(events: Array<Record<string, unknown>>, type: string) {
  return events.find((event) => event.type === type)
}

function voiceAssetId(sceneIndex: number, lineIndex: number): string {
  return `voice-${String(sceneIndex).padStart(3, '0')}-${String(lineIndex).padStart(3, '0')}`
}

function isSessionResumable(session: ReviewSession | undefined): boolean {
  return session?.status === 'CREATED' || session?.status === 'RUNNING'
}

function formatReviewTime(value: string | null): string {
  if (!value) return '暂无安排'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return '暂无安排'
  return new Intl.DateTimeFormat('zh-CN', {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  }).format(date)
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
  const [initial] = useState(() => {
    const saved = readWorkflow()
    // 兼容修复上线前已经留在 localStorage 中的结束会话，避免旧台词和语音复活。
    return saved.reviewSession && !isSessionResumable(saved.reviewSession)
      ? clearCompletedReview()
      : saved
  })
  const navigate = useNavigate()
  const adapterRef = useRef<WasmAdapter | null>(null)
  const gameStageRef = useRef<HTMLElement | null>(null)
  const bgmRef = useRef<HTMLAudioElement | null>(null)
  const voiceAudioRef = useRef<HTMLAudioElement | null>(null)
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
  const [dialogueIndex, setDialogueIndex] = useState(0)
  const [typedLength, setTypedLength] = useState(0)
  const [backgroundsReady, setBackgroundsReady] = useState(false)
  const [choiceFeedback, setChoiceFeedback] = useState<ChoiceFeedback>()
  const [reviewKnowledge, setReviewKnowledge] = useState<ReviewKnowledgeSummary[]>([])
  const [reviewKnowledgeLoading, setReviewKnowledgeLoading] = useState(false)
  const [reviewKnowledgeError, setReviewKnowledgeError] = useState('')
  const [voiceEnabled, setVoiceEnabled] = useState(true)
  const [voicePlaying, setVoicePlaying] = useState(false)
  const scene = useMemo(
    () => gamePackage?.scenes.find((item) => item.sceneId === sceneId),
    [gamePackage, sceneId],
  )
  const gameplayActive = Boolean(scene && gamePackage && isSessionResumable(session) && adapterVersion && !result && !shellCompleted)

  useEffect(() => {
    if (!gameplayActive) return undefined
    const audio = new Audio('/bgm.mp3')
    let active = true
    audio.loop = true
    audio.preload = 'auto'
    audio.volume = BGM_VOLUME
    bgmRef.current = audio

    const startPlayback = () => {
      if (!active) return
      void audio.play().catch(() => {})
    }

    void audio.play().catch(() => {
      if (active) document.addEventListener('pointerdown', startPlayback, { once: true })
    })

    return () => {
      active = false
      document.removeEventListener('pointerdown', startPlayback)
      audio.pause()
      audio.currentTime = 0
      bgmRef.current = null
    }
  }, [gameplayActive])

  const currentDialogue = scene?.dialogue[dialogueIndex]
  const dialogueCharacters = useMemo(() => Array.from(currentDialogue?.text || ''), [currentDialogue?.text])
  const typedDialogue = dialogueCharacters.slice(0, typedLength).join('')
  const dialogueTyping = typedLength < dialogueCharacters.length
  const dialogueCompleted = !scene || dialogueIndex >= scene.dialogue.length - 1
  const hasVoiceAssets = Boolean(gamePackage?.assets.some((asset) =>
    asset.type === 'AUDIO' && asset.assetId.startsWith('voice-'),
  ))

  useEffect(() => () => adapterRef.current?.dispose(), [])

useEffect(() => {
    let active = true
    void Promise.all(fixedMockSceneBackgrounds.map(preloadBackground)).then(() => {
      if (active) setBackgroundsReady(true)
    })
    return () => { active = false }
  }, [])

  useEffect(() => {
    setDialogueIndex(0)
  }, [sceneId])

  useEffect(() => {
    setTypedLength(0)
    if (!dialogueCharacters.length) return undefined
    const timer = window.setInterval(() => {
      setTypedLength((current) => {
        const next = current + 1
        if (next >= dialogueCharacters.length) window.clearInterval(timer)
        return Math.min(next, dialogueCharacters.length)
      })
    }, 52)
    return () => window.clearInterval(timer)
  }, [dialogueCharacters])

  useEffect(() => {
    let active = true
    let objectUrl = ''
    let playback: HTMLAudioElement | null = null
    let retryOnGesture: (() => void) | null = null
    setVoicePlaying(false)

    if (!voiceEnabled
      || !adapterRef.current
      || !isSessionResumable(session)
      || !gamePackage
      || !scene
      || !currentDialogue
      || choiceFeedback
      || result
      || shellCompleted) {
      return undefined
    }

    const sceneIndex = gamePackage.scenes.findIndex((item) => item.sceneId === scene.sceneId)
    if (sceneIndex < 0) return undefined
    const assetId = voiceAssetId(sceneIndex, dialogueIndex)
    const asset = gamePackage.assets.find((item) => item.type === 'AUDIO' && item.assetId === assetId)
    if (!asset) return undefined

    const restoreBgm = () => {
      if (bgmRef.current) bgmRef.current.volume = BGM_VOLUME
    }
    const beginPlayback = () => {
      if (!active || !playback) return
      if (bgmRef.current) bgmRef.current.volume = BGM_DUCKED_VOLUME
      void playback.play().then(() => {
        if (active) setVoicePlaying(true)
      }).catch(() => {
        restoreBgm()
        if (active) setVoicePlaying(false)
      })
    }

    void api.getGameAudio(asset.uri).then((blob) => {
      if (!active) return
      objectUrl = URL.createObjectURL(blob)
      playback = new Audio(objectUrl)
      playback.preload = 'auto'
      playback.volume = CHARACTER_VOICE_VOLUME
      playback.playbackRate = CHARACTER_VOICE_PLAYBACK_RATE
      playback.preservesPitch = true
      voiceAudioRef.current = playback
      playback.addEventListener('ended', () => {
        restoreBgm()
        if (active) setVoicePlaying(false)
      }, { once: true })
      playback.addEventListener('error', () => {
        restoreBgm()
        if (active) setVoicePlaying(false)
      }, { once: true })
      void playback.play().then(() => {
        if (bgmRef.current) bgmRef.current.volume = BGM_DUCKED_VOLUME
        if (active) setVoicePlaying(true)
      }).catch(() => {
        restoreBgm()
        retryOnGesture = beginPlayback
        document.addEventListener('pointerdown', retryOnGesture, { once: true })
      })
    }).catch(() => {
      // Voice is optional. Text dialogue remains usable when audio cannot be loaded.
      restoreBgm()
    })

    return () => {
      active = false
      if (retryOnGesture) document.removeEventListener('pointerdown', retryOnGesture)
      playback?.pause()
      if (playback) playback.currentTime = 0
      if (voiceAudioRef.current === playback) voiceAudioRef.current = null
      if (objectUrl) URL.revokeObjectURL(objectUrl)
      restoreBgm()
    }
  }, [adapterVersion, choiceFeedback, currentDialogue, dialogueIndex, gamePackage, result, scene, session, shellCompleted, voiceEnabled])

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
    if (initial.plan && !initial.resultIdempotencyKey) updateWorkflow({ resultIdempotencyKey: resultKeyRef.current })
  }, [initial.plan, initial.resultIdempotencyKey])

  async function attachRuntime(manifest: RuntimeManifest, pack: GamePackage, reviewSession: ReviewSession) {
    if (!isSessionResumable(reviewSession)) {
      throw new Error('上一次复习会话已经结束，不能继续恢复，请重新生成故事。')
    }
    adapterRef.current?.dispose()
    adapterRef.current = await loadRuntime(manifest, pack, reviewSession)
    setAdapterVersion((value) => value + 1)
    setRuntimeManifest(manifest)
    const nextSceneId = reviewSession.currentSceneId || pack.entrySceneId
    const savedVisited = readWorkflow().visitedSceneIds || []
    const nextVisited = savedVisited.includes(nextSceneId) ? savedVisited : [...savedVisited, nextSceneId]
    setSceneId(nextSceneId)
    setChoiceFeedback(undefined)
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
        gameGenerationPollTimeoutMs,
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
    setChoiceFeedback(undefined)
    setReviewKnowledge([])
    setReviewKnowledgeError('')
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
      if (!handleCreditsRequired(reason)) setError(reason instanceof Error ? reason.message : '游戏准备失败。')
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
      if (!isSessionResumable(currentSession)) {
        resetGame()
        clearCompletedReview()
        navigate('/materials', { replace: true })
        return
      }
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
    if (!scene || !session || busy || choiceFeedback) return
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
      const nextAnswers = answer ? [...attempt.answers, answer] : attempt.answers
      if (answer) {
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
      let nextVisited = visitedSceneIds
      let savedSession: ReviewSession | undefined
      if (nextSceneId && !completedByRuntime) {
        nextVisited = visitedSceneIds.includes(nextSceneId) ? visitedSceneIds : [...visitedSceneIds, nextSceneId]
        savedSession = await saveSceneProgress(nextSceneId, nextVisited)
        setVisitedSceneIds(nextVisited)
        updateWorkflow({ visitedSceneIds: nextVisited })
      } else {
        savedSession = await saveSceneProgress(scene.sceneId, visitedSceneIds)
      }

      if (answer) {
        const correctChoice = scene.choices.find((item) => item.correct === true)
        const knowledgeTitle = initial.plan?.nodes.find((node) => node.pointId === answer.knowledgePointId)?.title || '当前知识点'
        setChoiceFeedback({
          correct: answer.correct,
          selectedText: choice.text,
          correctText: correctChoice?.text || null,
          knowledgeTitle,
          nextSceneId: nextSceneId && !completedByRuntime ? nextSceneId : null,
          nextVisitedSceneIds: nextVisited,
          answers: nextAnswers,
          savedSession,
        })
      } else if (nextSceneId && !completedByRuntime) {
        setSceneId(nextSceneId)
        sceneStartedAtRef.current = Date.now()
      } else {
        await finish(nextAnswers, savedSession)
      }
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '选择保存失败。')
    } finally {
      setBusy(false)
    }
  }

  async function continueAfterFeedback() {
    if (!choiceFeedback || busy) return
    if (choiceFeedback.nextSceneId) {
      setVisitedSceneIds(choiceFeedback.nextVisitedSceneIds)
      setSceneId(choiceFeedback.nextSceneId)
      setChoiceFeedback(undefined)
      sceneStartedAtRef.current = Date.now()
      return
    }
    await finish(choiceFeedback.answers, choiceFeedback.savedSession)
  }

  async function loadReviewKnowledge(answers: AnswerResult[]) {
    const workflow = readWorkflow()
    const plan = workflow.plan || initial.plan
    if (!plan) return

    const reviewedPointIds = new Set(answers.map((answer) => answer.knowledgePointId))
    const visited = new Set(workflow.visitedSceneIds || visitedSceneIds)
    for (const reviewedScene of gamePackage?.scenes || []) {
      if (!visited.has(reviewedScene.sceneId)) continue
      for (const binding of reviewedScene.knowledgeBindings) reviewedPointIds.add(binding.knowledgePointId)
    }
    const reviewedNodes = plan.nodes.filter((node) => reviewedPointIds.has(node.pointId))
    const summaryNodes = reviewedNodes.length ? reviewedNodes : plan.nodes
    const fallback = summaryNodes.map((node) => ({
      pointId: node.pointId,
      title: node.title,
      masteryScore: node.masteryScore,
      nextReviewAt: null,
    }))
    setReviewKnowledge(fallback)
    setReviewKnowledgeLoading(true)
    setReviewKnowledgeError('')
    try {
      const records = await api.getAllMasteryRecords(plan.graphId)
      const recordByPointId = new Map<string, MasteryRecord>(records.map((record) => [record.pointId, record]))
      setReviewKnowledge(fallback.map((item) => {
        const record = recordByPointId.get(item.pointId)
        return record ? { ...item, masteryScore: record.score, nextReviewAt: record.nextReviewAt } : item
      }))
    } catch {
      setReviewKnowledgeError('最新熟练度获取失败，当前显示本次计划生成时的熟练度。')
    } finally {
      setReviewKnowledgeLoading(false)
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
        clearCompletedReview()
        await loadReviewKnowledge(answers)
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
      clearCompletedReview()
      await loadReviewKnowledge(answers)
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

  async function finishReviewEarly() {
    if (!session || !gamePackage) return
    await finish(attempt.answers, session)
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
    setChoiceFeedback(undefined)
    setReviewKnowledge([])
    setReviewKnowledgeLoading(false)
    setReviewKnowledgeError('')
    setError('')
    setProgress('可以调整风格与难度，再生成一次。')
    updateWorkflow({ gameGeneration: undefined, gameManifest: undefined, gamePackage: undefined, reviewSession: undefined, visitedSceneIds: undefined, answerResults: undefined, resultIdempotencyKey: resultKeyRef.current })
  }

  async function restartReview() {
    if (busy || !initial.plan) return

    // 完成页已清理持久化的旧会话；这里只恢复不可变计划，以复用原章节范围。
    // 游戏包、会话、作答与幂等键全部重新创建，保证进入一次全新的 AI 生成流程。
    resetGame()
    updateWorkflow({
      plan: initial.plan,
      gameStyle: style,
      gameDifficulty: difficulty,
    })
    setProgress(`正在按上次选择的 ${initial.plan.selectedChapterIds.length} 个章节重新生成剧情…`)
    await generateAndStart()
  }

  if (!initial.plan) {
    return <AppShell><main className="page review-page"><PageHeader title="回响" /><section className="empty-state"><h2>还没有复习计划</h2><Link className="button button--primary" to="/materials">创建新复习计划</Link></section></main></AppShell>
  }

  function advanceDialogue() {
    if (!scene || choiceFeedback) return
    if (dialogueTyping) {
      setTypedLength(dialogueCharacters.length)
      return
    }
    if (dialogueCompleted) return
    setDialogueIndex((current) => Math.min(current + 1, scene.dialogue.length - 1))
  }

  async function toggleGameFullscreen() {
    const stage = gameStageRef.current
    if (!stage) return
    try {
      if (document.fullscreenElement) await document.exitFullscreen()
      else await stage.requestFullscreen()
    } catch {
      setError('当前浏览器无法进入全屏模式。')
    }
  }

  const showSetup = !gamePackage || !isSessionResumable(session) || !adapterRef.current

  return (
    <AppShell>
    <main className={`page review-page${showSetup ? ' review-page--setup' : ''}`}>
      <PageHeader title={initial.material?.displayName || '本次复习'} description={`${initial.plan.type === 'ASSESSMENT' ? '全面测试' : '章节学习'} · ${initial.plan.nodes.length} 个知识节点`} />

      {result || shellCompleted ? (
        <section className="review-complete workspace-card">
          <p>复习完成</p>
          <h2>{shellCompleted ? '本地体验已完成' : result?.status === 'ACCEPTED' ? '结果已提交' : '结果已去重'}</h2>
          <p>{shellCompleted ? `本地记录 ${attempt.answers.length} 条作答。当前 RenderService 仅提供基础壳，本次结果没有提交，熟练度不会更新。` : `共记录 ${attempt.answers.length} 条作答证据。`}</p>
          <div className="review-summary">
            <div className="review-summary__heading"><h3>本次复习知识点</h3>{reviewKnowledgeLoading ? <LoadingIndicator label="正在同步最新熟练度…" compact /> : null}</div>
            {reviewKnowledge.length ? <ul>{reviewKnowledge.map((item) => <li key={item.pointId}>
              <div><strong>{item.title}</strong><span>熟练度 {Math.round(item.masteryScore)} / 100</span></div>
              <p>下次复习：{formatReviewTime(item.nextReviewAt)}</p>
            </li>)}</ul> : <p>本轮没有记录到知识点。</p>}
            {reviewKnowledgeError ? <p className="review-summary__error">{reviewKnowledgeError}</p> : null}
          </div>
          <div className="completion-actions" aria-label="复习完成后操作">
            <button className="completion-action completion-action--restart" type="button" disabled={busy} onClick={() => void restartReview()}>
              <span className="completion-action__icon"><CompletionActionIcon kind="restart" /></span>
              <span className="completion-action__copy"><strong>{busy ? '正在准备新一轮…' : '重新复习'}</strong><small>沿用当前章节，重新生成剧情</small></span>
            </button>
            <Link className="completion-action completion-action--graph" to="/knowledge-graph">
              <span className="completion-action__icon"><CompletionActionIcon kind="graph" /></span>
              <span className="completion-action__copy"><strong>查看知识图谱</strong><small>回到知识结构，查看掌握情况</small></span>
            </Link>
            <Link className="completion-action completion-action--plan" to="/materials">
              <span className="completion-action__icon"><CompletionActionIcon kind="plan" /></span>
              <span className="completion-action__copy"><strong>创建新复习计划</strong><small>选择资料与章节，开始新计划</small></span>
            </Link>
          </div>
        </section>
      ) : showSetup ? (
        <section className="review-setup workspace-card" data-style={style.toLowerCase()}>
          <span className="review-setup__orb review-setup__orb--one" aria-hidden="true" />
          <span className="review-setup__orb review-setup__orb--two" aria-hidden="true" />
          <div className="review-setup__heading">
            <span className="section-label">生成设置</span>
            <h2>准备 视觉小说</h2>
            <p>选择故事氛围与挑战难度，生成一段只属于本次计划的互动复习。</p>
          </div>
          <div className="review-setup__summary" aria-label="本次复习概况">
            <div><span>预计题目</span><strong>{initial.plan.estimatedQuestionCount}</strong><small>道</small></div>
            <div><span>知识范围</span><strong>{initial.plan.nodes.length}</strong><small>个节点</small></div>
          </div>
          <div className="review-setup__controls">
            <label><span>故事风格</span><select value={style} onChange={(event) => setStyle(event.target.value as GameStyle)}><option value="CAMPUS">校园</option><option value="FANTASY">幻想</option><option value="SCIENCE">科幻</option></select></label>
            <label><span>挑战难度</span><select value={difficulty} onChange={(event) => setDifficulty(event.target.value as Difficulty)}><option value="BASIC">基础</option><option value="STANDARD">标准</option><option value="ADVANCED">进阶</option></select></label>
          </div>
          {gamePackage && isSessionResumable(session)
            ? <button className="primary-button" type="button" disabled={busy} onClick={() => void resumeRuntime()}>恢复会话</button>
            : session && !isSessionResumable(session)
              ? <Link className="primary-button" to="/materials" onClick={() => clearCompletedReview()}>创建新复习计划</Link>
            : generation && generation.status !== 'FAILED'
              ? <button className="primary-button" type="button" disabled={busy} onClick={() => void resumeGeneration()}>{busy ? '恢复中…' : `继续生成（${generation.progress}%）`}</button>
              : <button className="primary-button" type="button" disabled={busy} onClick={() => void generateAndStart()}>{busy ? '准备中…' : '生成并开始'}</button>}
        </section>
      ) : scene ? (
        <section className={`game-stage game-stage--${scene.sceneId}${backgroundsReady ? '' : ' game-stage--backgrounds-loading'}`} ref={gameStageRef}>
          {!backgroundsReady ? <LoadingIndicator className="game-stage__background-loading" label="场景加载中…" /> : null}
          <div className="game-stage__meta"><span>{runtimeManifest?.wasmVersion} · {adapterRef.current?.engine === 'wasm' ? 'WASM' : '兼容模式'}</span><span>{visitedSceneIds.length} 个场景已访问</span></div>
          <div className="game-stage__actions">
            <button className="game-stage__end" type="button" disabled={busy} onClick={() => void finishReviewEarly()}>结束复习</button>
            {hasVoiceAssets ? <button
              className={`game-stage__voice${voicePlaying ? ' is-playing' : ''}`}
              type="button"
              onClick={() => setVoiceEnabled((enabled) => !enabled)}
              aria-label={voiceEnabled ? '关闭角色语音' : '开启角色语音'}
              title={voiceEnabled ? '关闭角色语音' : '开启角色语音'}
              aria-pressed={voiceEnabled}
            >
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 10v4h4l5 4V6l-5 4H5Z" /><path d={voiceEnabled ? 'M17 9c1.3 1.6 1.3 4.4 0 6M19.5 6.5c3 3 3 8 0 11' : 'm17 9 5 6m0-6-5 6'} /></svg>
            </button> : null}
            <button className="game-stage__fullscreen" type="button" onClick={() => void toggleGameFullscreen()} aria-label="切换全屏" title="切换全屏">
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 9V5h4M20 9V5h-4M4 15v4h4M20 15v4h-4" /></svg>
            </button>
          </div>
          <article className={`dialogue-panel${!choiceFeedback && (!dialogueCompleted || dialogueTyping) ? ' dialogue-panel--advance' : ''}${choiceFeedback ? ` dialogue-panel--feedback dialogue-panel--feedback-${choiceFeedback.correct ? 'correct' : 'incorrect'}` : ''}`} onClick={choiceFeedback ? undefined : advanceDialogue}>
            {scene.title ? <h2>{scene.title}</h2> : null}
            {choiceFeedback ? <div className="dialogue-line dialogue-line--feedback" role="status" aria-live="assertive">
              <strong>{choiceFeedback.correct ? '回答正确' : '回答错误'}</strong>
              <div className="dialogue-line__text">
                <p>{choiceFeedback.correct
                  ? `你选择的「${choiceFeedback.selectedText}」是正确答案。这道题检验的是“${choiceFeedback.knowledgeTitle}”的关键判断。`
                  : `你选择了「${choiceFeedback.selectedText}」。正确答案是「${choiceFeedback.correctText || '题目给出的正确选项'}」，请留意“${choiceFeedback.knowledgeTitle}”。`}</p>
              </div>
            </div> : currentDialogue ? <div className={`dialogue-line${currentDialogue.speakerId === '旁白' ? ' dialogue-line--narration' : ''}`}>
              {currentDialogue.speakerId !== '旁白' ? <strong>{currentDialogue.speakerId}</strong> : null}
              <div className="dialogue-line__text">
                <p className="dialogue-line__measure" aria-hidden="true">{currentDialogue.text}</p>
                <p className="dialogue-line__typed">{typedDialogue}</p>
              </div>
            </div> : null}
          </article>
          {choiceFeedback ? <div className="choice-list choice-list--feedback"><button disabled={busy} type="button" onClick={() => void continueAfterFeedback()}>{choiceFeedback.nextSceneId ? '继续剧情' : '查看复习总结'}</button></div> : dialogueCompleted && !dialogueTyping ? (scene.choices.length ? <div className="choice-list">{scene.choices.map((choice) => <button key={choice.choiceId} disabled={busy} type="button" onClick={() => void choose(choice)}>{choice.text}</button>)}</div> : <button className="primary-button" disabled={busy} type="button" onClick={() => void finishCurrentScene()}>前面的区域以后再来探索吧</button>) : null}
        </section>
      ) : <section className="workspace-card"><h2>场景不存在</h2><p>游戏包没有找到当前场景，请重新生成。</p></section>}

      {busy && showSetup && !error
        ? <LoadingIndicator className="page-loading-transition" label={progress} compact />
        : <p className={error ? 'status-line status-line--error' : 'status-line'} aria-live="polite">{error || progress}</p>}
    </main>
    </AppShell>
  )
}
