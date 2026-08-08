import { useEffect, useState } from 'react'
import { Link, useLocation } from 'react-router'
import AppShell from '../components/AppShell'
import { BookIcon, GraphIcon, MaterialsIcon, ReviewIcon } from '../components/icons'
import { api } from '../lib/api'
import { readProfile, saveProfile } from '../lib/session'
import { readColorTheme, saveColorTheme, type ColorTheme } from '../lib/theme'
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
  const [colorTheme, setColorTheme] = useState<ColorTheme>(readColorTheme())
  const [message, setMessage] = useState((location.state as { message?: string } | null)?.message || '')
  const resume = resumeState()
  const workflow = readWorkflow()

  function changeColorTheme(value: ColorTheme) {
    setColorTheme(value)
    saveColorTheme(value)
  }

  useEffect(() => {
    if (profile) return
    void api.getCurrentUser().then((value) => { saveProfile(value); setProfile(value) }).catch((reason: unknown) => setMessage(reason instanceof Error ? reason.message : '用户资料读取失败。'))
  }, [profile])

  return (
    <AppShell>
      <main className="page home-dashboard">
        {message ? <p className="status-line" role="status">{message}</p> : null}

        <section className="home-welcome">
          <label className="toggle-field home-theme-toggle">
            <span><strong>深色模式</strong></span>
            <input type="checkbox" role="switch" aria-label="深色模式" checked={colorTheme === 'dark'} onChange={(event) => changeColorTheme(event.target.checked ? 'dark' : 'light')} />
          </label>
          <div className="home-welcome__intro">
            <div><span>{resume.step}</span><h2>欢迎回来，{profile?.displayName || '学习者'}</h2><p>{resume.detail}</p></div>
            {resume.action === '选择复习范围' ? null : <Link className="button button--primary" to={resume.to}>{resume.action}</Link>}
          </div>
          <div className="home-quick-actions" aria-label="页面快捷入口">
            <Link to="/projects"><span className="quick-action-icon"><BookIcon /></span><span><strong>学习项目</strong><small>管理题库与学习范围</small></span><i aria-hidden="true">→</i></Link>
            <Link to="/projects"><span className="quick-action-icon"><MaterialsIcon /></span><span><strong>日常练习</strong><small>从项目题库开始复习</small></span><i aria-hidden="true">→</i></Link>
            <Link to="/knowledge-graph"><span className="quick-action-icon quick-action-icon--graph"><GraphIcon /></span><span><strong>知识图谱</strong><small>查看知识关系与掌握度</small></span><i aria-hidden="true">→</i></Link>
            <Link to="/projects"><span className="quick-action-icon quick-action-icon--review"><ReviewIcon /></span><span><strong>故事复习</strong><small>从学习项目选择视觉小说模式</small></span><i aria-hidden="true">→</i></Link>
          </div>
        </section>

        <section className="home-intelligence-flow" aria-labelledby="home-intelligence-title">
          <header>
            <span>千知万理如何协助复习</span>
            <h2 id="home-intelligence-title">从资料解析到下一次复习</h2>
            <p>AI 辅助理解资料和生成候选内容；来源核对、答案确认、知识关系与 SM-2 调度共同保证复习过程可追踪。</p>
          </header>
          <div>
            <article><span>01</span><h3>解析资料</h3><p>还原文件原文，辅助识别章节、概念与可出题内容，并保留来源位置。</p></article>
            <article><span>02</span><h3>确认题库</h3><p>生成或导入五类题目，由你核对答案与解析后进入正式复习。</p></article>
            <article><span>03</span><h3>安排练习</h3><p>知识图谱连接相关概念，SM-2 结合掌握度和到期时间选择题目。</p></article>
            <article><span>04</span><h3>回写反馈</h3><p>作答结果更新复习间隔；故事复习也使用同一项目的资料与记录。</p></article>
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
