import { useEffect, useRef, useState } from 'react'
import { Link, useParams } from 'react-router'
import AppShell, { PageHeader } from '../components/AppShell'
import { api } from '../lib/api'
import type { PracticeAnswer, PracticeSession, QuestionHelp } from '../types/api'

export default function PracticeSessionPage() {
  const { sessionId = '' } = useParams(); const [session, setSession] = useState<PracticeSession | null>(null)
  const [index, setIndex] = useState(0); const [value, setValue] = useState(''); const [result, setResult] = useState<PracticeAnswer | null>(null)
  const [message, setMessage] = useState(''); const [busy, setBusy] = useState(false); const startedAt = useRef(performance.now())
  const [help, setHelp] = useState<QuestionHelp | null>(null)
  useEffect(() => { void api.getPracticeSession(sessionId).then(setSession).catch((error: unknown) => setMessage(error instanceof Error ? error.message : '练习读取失败。')) }, [sessionId])
  const question = session?.questions[index]

  async function submit(answerValue?: string) {
    if (!question) return; setBusy(true); setMessage('')
    try {
      const parts = question.kind === 'FILL_BLANK' ? (answerValue ?? value).split('\n').filter(Boolean) : [answerValue ?? value]
      const answer = await api.savePracticeAnswer(sessionId, question.questionId, parts, Math.round(performance.now() - startedAt.current)); setResult(answer)
    } catch (error) { setMessage(error instanceof Error ? error.message : '答案提交失败。') } finally { setBusy(false) }
  }
  async function next() {
    if (!session) return
    if (index + 1 < session.questions.length) { setIndex(index + 1); setValue(''); setResult(null); setHelp(null); startedAt.current = performance.now(); return }
    setBusy(true)
    try { const completed = await api.completePracticeSession(sessionId); setSession((current) => current ? { ...current, ...completed.session, questions: current.questions } : completed.session); setResult(null); setHelp(null) }
    catch (error) { setMessage(error instanceof Error ? error.message : '练习完成失败。') } finally { setBusy(false) }
  }
  async function requestHelp() {
    if (!question) return; setBusy(true); setMessage(''); try { setHelp(await api.getQuestionHelp(question.questionId, true)) } catch (error) { setMessage(error instanceof Error ? error.message : '帮助内容读取失败。') } finally { setBusy(false) }
  }

  return <AppShell><main className="page practice-session-page">
    <PageHeader title={session?.status === 'COMPLETED' ? '练习完成' : '日常练习'} description={session ? `${Math.min(index + 1, session.questions.length)} / ${session.questions.length}` : '正在读取题目'} actions={<Link className="button button--quiet" to={session ? `/projects/${session.projectId}` : '/projects'}>退出练习</Link>} />
    {message ? <p className="status-line status-line--error" role="alert">{message}</p> : null}
    {session?.status === 'COMPLETED' ? <section className="practice-complete workspace-card"><span className="section-label">结果</span><h2>本轮练习已经记录</h2><p>共作答 {session.answers.length} 道，正确 {session.answers.filter((item) => item.correct).length} 道。带知识图谱计划的会话会由 KnowledgeService 更新掌握度。</p><Link className="button button--primary" to={`/projects/${session.projectId}`}>返回题库</Link></section> : question ? <section className="practice-question-card">
      <header><span>{question.kind.replaceAll('_', ' ')}</span><strong>{question.score} 分</strong></header>
      <h2>{question.prompt}</h2>
      {!result && question.kind === 'SINGLE_CHOICE' ? <div className="practice-options">{question.options.map((option) => <button key={option.id} disabled={busy} onClick={() => void submit(option.id)}><b>{option.id}</b><span>{option.text}</span></button>)}</div> : null}
      {!result && question.kind === 'TRUE_FALSE' ? <div className="practice-options practice-options--binary"><button disabled={busy} onClick={() => void submit('true')}>正确</button><button disabled={busy} onClick={() => void submit('false')}>错误</button></div> : null}
      {!result && question.kind !== 'SINGLE_CHOICE' && question.kind !== 'TRUE_FALSE' ? <div className="practice-written-answer"><textarea rows={question.kind === 'FILL_BLANK' ? 5 : 8} value={value} placeholder={question.kind === 'FILL_BLANK' ? '每个空的答案单独一行' : '写下你的答案'} onChange={(event) => setValue(event.target.value)} /><button className="button button--primary" disabled={busy || !value.trim()} onClick={() => void submit()}>{busy ? '正在判分' : '提交答案'}</button></div> : null}
      {result ? <div className={`practice-result ${result.correct ? 'is-correct' : 'is-wrong'}`}><strong>{result.correct ? '回答正确' : '需要再复习'}</strong><span>得分 {result.awardedScore} · quality {result.quality}{result.similarity == null ? '' : ` · 相似度 ${Math.round(result.similarity * 100)}%`}</span>{!result.correct ? <button className="button button--quiet" disabled={busy} onClick={() => void requestHelp()}>查看资料依据</button> : null}{help ? <div className="practice-help"><strong>资料依据</strong>{help.matches.map((item, matchIndex) => <blockquote key={`${item.excerpt}-${matchIndex}`}>{item.excerpt}</blockquote>)}{help.generatedExplanation ? <p>{help.generatedExplanation}</p> : null}{!help.grounded ? <p>当前题目没有可用的资料出处，系统不会自由补写答案。</p> : null}</div> : null}<button className="button button--primary" disabled={busy} onClick={() => void next()}>{index + 1 < session.questions.length ? '下一题' : '完成练习'}</button></div> : null}
    </section> : <p className="empty-row">正在读取练习。</p>}
  </main></AppShell>
}
