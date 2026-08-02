import { useEffect, useState } from 'react'
import { Link, useLocation } from 'react-router'
import AppShell, { PageHeader } from '../components/AppShell'
import { GraphIcon, KnowledgeIcon, MaterialsIcon, ReviewIcon } from '../components/icons'
import { api } from '../lib/api'
import { readProfile, saveProfile } from '../lib/session'
import { readWorkflow } from '../lib/workflow'

function resumeState() {
  const workflow = readWorkflow()
  if (workflow.gamePackage && workflow.reviewSession) return { to: '/review', action: '恢复复习', detail: '游戏包与本地进度已保存。', step: '复习进行中' }
  if (workflow.plan) return { to: '/review', action: '开始复习', detail: `计划包含 ${workflow.plan.nodes.length} 个知识节点。`, step: '计划已生成' }
  if (workflow.graph) return { to: '/materials', action: '选择复习范围', detail: `${workflow.graph.chapterCount} 章，${workflow.graph.pointCount} 个知识点。`, step: '图谱已完成' }
  if (workflow.material) return { to: '/materials', action: '继续处理资料', detail: workflow.material.displayName, step: '资料已上传' }
  return { to: '/materials', action: '上传第一份资料', detail: '吹灭读书灯，一身都是月', step: '尚未开始' }
}

export default function HomePage() {
  const location = useLocation()
  const [profile, setProfile] = useState(readProfile())
  const [message, setMessage] = useState((location.state as { message?: string } | null)?.message || '')
  const resume = resumeState()
  const workflow = readWorkflow()

  useEffect(() => {
    if (profile) return
    void api.getCurrentUser().then((value) => { saveProfile(value); setProfile(value) }).catch((reason: unknown) => setMessage(reason instanceof Error ? reason.message : '用户资料读取失败。'))
  }, [profile])

  return (
    <AppShell>
      <main className="page home-dashboard">
        <PageHeader title="主页" />
        {message ? <p className="status-line" role="status">{message}</p> : null}

        <section className="home-welcome">
          <div className="home-welcome__intro">
            <div><span>{resume.step}</span><h2>欢迎回来，{profile?.displayName || '学习者'}</h2><p>{resume.detail}</p></div>
            <Link className="button button--primary" to={resume.to}>{resume.action}</Link>
          </div>
          <div className="home-quick-actions" aria-label="页面快捷入口">
            <Link to="/materials"><span className="quick-action-icon"><MaterialsIcon /></span><span><strong>资料</strong><small>采章入卷</small></span><i aria-hidden="true">→</i></Link>
            <Link to="/knowledge"><span className="quick-action-icon"><KnowledgeIcon /></span><span><strong>知识点</strong><small>循章识要</small></span><i aria-hidden="true">→</i></Link>
            <Link to="/knowledge-graph"><span className="quick-action-icon"><GraphIcon /></span><span><strong>知识图谱</strong><small>观脉寻源</small></span><i aria-hidden="true">→</i></Link>
            <Link to="/review"><span className="quick-action-icon"><ReviewIcon /></span><span><strong>复习</strong><small>温故知新</small></span><i aria-hidden="true">→</i></Link>
          </div>
        </section>

        <section className="home-summary" aria-label="学习概况">
          <article><span>学科</span><strong>{workflow.graph?.subjectCode || profile?.preferredSubjectCodes[0] || '未设置'}</strong></article>
          <article><span>章节</span><strong>{workflow.graph?.chapterCount ?? 0}</strong></article>
          <article><span>知识点</span><strong>{workflow.graph?.pointCount ?? 0}</strong></article>
          <article><span>计划</span><strong>{workflow.plan ? '已创建' : '未创建'}</strong></article>
        </section>
      </main>
    </AppShell>
  )
}
