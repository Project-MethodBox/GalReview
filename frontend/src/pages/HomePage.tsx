import { useEffect, useState } from 'react'
import { Link, useLocation } from 'react-router'
import AppShell, { PageHeader } from '../components/AppShell'
import { api } from '../lib/api'
import { readProfile, saveProfile } from '../lib/session'
import { readWorkflow } from '../lib/workflow'

function resumeState() {
  const workflow = readWorkflow()
  if (workflow.gamePackage && workflow.reviewSession) return { to: '/review', action: '恢复复习', detail: '游戏包与本地进度已保存。', step: '复习进行中' }
  if (workflow.plan) return { to: '/review', action: '开始复习', detail: `计划包含 ${workflow.plan.nodes.length} 个知识节点。`, step: '计划已生成' }
  if (workflow.graph) return { to: '/materials', action: '选择复习范围', detail: `${workflow.graph.chapterCount} 章，${workflow.graph.pointCount} 个知识点。`, step: '图谱已完成' }
  if (workflow.material) return { to: '/materials', action: '继续处理资料', detail: workflow.material.displayName, step: '资料已上传' }
  return { to: '/materials', action: '上传第一份资料', detail: '支持 PDF、DOCX、Markdown、HTML、文本与图片。', step: '尚未开始' }
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
        <PageHeader title={`你好，${profile?.displayName || '学习者'}`} description="继续尚未完成的复习，也可以上传新的学习资料。" />
        {message ? <p className="status-line" role="status">{message}</p> : null}

        <section className="home-workspace">
          <article className="resume-panel">
            <div><span>{resume.step}</span><h2>{resume.action}</h2><p>{resume.detail}</p></div>
            <Link className="button button--light" to={resume.to}>{resume.action}</Link>
          </article>

          <aside className="study-snapshot">
            <h2>当前学习档案</h2>
            <dl>
              <div><dt>学科</dt><dd>{workflow.graph?.subjectCode || profile?.preferredSubjectCodes[0] || '未设置'}</dd></div>
              <div><dt>章节</dt><dd>{workflow.graph?.chapterCount ?? 0}</dd></div>
              <div><dt>知识点</dt><dd>{workflow.graph?.pointCount ?? 0}</dd></div>
              <div><dt>计划状态</dt><dd>{workflow.plan?.status || '无计划'}</dd></div>
            </dl>
            <Link to="/settings">编辑个人设置</Link>
          </aside>
        </section>

        <section className="home-destinations" aria-label="主要功能">
          <header><h2>学习工具</h2><p>上传资料后，可以在这里查看知识点、梳理依赖关系并开始复习。</p></header>
          <div className="destination-list">
            <Link to="/materials"><span>资料</span><strong>上传、解析并创建计划</strong><small>从文件开始</small></Link>
            <Link to="/knowledge"><span>知识点</span><strong>查找知识点并查看掌握情况</strong><small>{workflow.graph ? `${workflow.graph.pointCount} 项` : '尚未生成'}</small></Link>
            <Link to="/knowledge-graph"><span>图谱</span><strong>查看章节和知识依赖</strong><small>{workflow.graph ? `${workflow.graph.relationCount} 条关系` : '尚未生成'}</small></Link>
            <Link to="/review"><span>复习</span><strong>生成 GalGame 并作答</strong><small>{workflow.plan ? '计划可用' : '需要计划'}</small></Link>
          </div>
        </section>
      </main>
    </AppShell>
  )
}
