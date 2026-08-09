import { useEffect, useMemo, useState } from 'react'
import { Link, useLocation } from 'react-router'
import AppShell from '../components/AppShell'
import { BookIcon, GraphIcon, MaterialsIcon, ReviewIcon } from '../components/icons'
import { api } from '../lib/api'
import { readProfile, saveProfile } from '../lib/session'
import { readColorTheme, saveColorTheme, type ColorTheme } from '../lib/theme'
import type { StudyProject } from '../types/api'

function formatUpdatedAt(value?: string) {
  if (!value) return '尚无记录'
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? '时间未知' : date.toLocaleDateString('zh-CN', { month: '2-digit', day: '2-digit' })
}

export default function HomePage() {
  const location = useLocation()
  const [profile, setProfile] = useState(readProfile())
  const [projects, setProjects] = useState<StudyProject[]>([])
  const [colorTheme, setColorTheme] = useState<ColorTheme>(readColorTheme())
  const [message, setMessage] = useState((location.state as { message?: string } | null)?.message || '')
  const recentProjects = useMemo(() => [...projects].sort((left, right) => right.updatedAt.localeCompare(left.updatedAt)).slice(0, 3), [projects])
  const latestProject = recentProjects[0]

  function changeColorTheme(value: ColorTheme) {
    setColorTheme(value)
    saveColorTheme(value)
  }

  useEffect(() => {
    let active = true
    void Promise.all([profile ? Promise.resolve(profile) : api.getCurrentUser(), api.listPracticeProjects()])
      .then(([currentProfile, projectPage]) => {
        if (!active) return
        saveProfile(currentProfile); setProfile(currentProfile); setProjects(projectPage.items)
      })
      .catch((reason: unknown) => { if (active) setMessage(reason instanceof Error ? reason.message : '复习资料库读取失败。') })
    return () => { active = false }
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
            <div>
              <span>{latestProject ? '旧卷待温' : '新卷待启'}</span>
              <h2>欢迎回来，{profile?.displayName || '学习者'}</h2>
              <p>{latestProject ? `“${latestProject.name}”已备好题库、图谱与复习记录。` : '先在藏书阁整理一份资料与知识脉络，再建立属于你的经典复习项目。'}</p>
            </div>
            <Link className="button button--primary" to={latestProject ? `/projects/${latestProject.projectId}` : '/materials'}>{latestProject ? '继续温习' : '前往藏书阁'}</Link>
          </div>
          <div className="home-quick-actions" aria-label="复习快捷入口">
            <Link to="/materials"><span className="quick-action-icon quick-action-icon--materials"><MaterialsIcon /></span><span><strong>藏书阁</strong><small>解析资料并整理章节</small></span><i aria-hidden="true">→</i></Link>
            <Link to="/projects"><span className="quick-action-icon quick-action-icon--knowledge"><BookIcon /></span><span><strong>研习册</strong><small>创建、导入与续读复习项目</small></span><i aria-hidden="true">→</i></Link>
            <Link to={latestProject ? `/projects/${latestProject.projectId}` : '/projects'}><span className="quick-action-icon quick-action-icon--review"><ReviewIcon /></span><span><strong>章节温习</strong><small>从项目题库开始答题</small></span><i aria-hidden="true">→</i></Link>
            <Link to="/knowledge-graph"><span className="quick-action-icon quick-action-icon--graph"><GraphIcon /></span><span><strong>识网</strong><small>查看知识脉络与掌握度</small></span><i aria-hidden="true">→</i></Link>
          </div>
        </section>

        <section className="home-summary" aria-label="研习概况">
          <article><span>研习册</span><strong>{projects.length}</strong></article>
          <article><span>已识网</span><strong>{projects.filter((project) => project.graphId).length}</strong></article>
          <article><span>资料引用</span><strong>{projects.reduce((total, project) => total + project.materialIds.length, 0)}</strong></article>
          <article><span>最近温习</span><strong>{formatUpdatedAt(latestProject?.updatedAt)}</strong></article>
        </section>

        <section className="home-intelligence-flow" aria-labelledby="home-intelligence-title">
          <header>
            <span>千知万理如何陪你温习</span>
            <h2 id="home-intelligence-title">一卷成册，循知而习</h2>
            <p>资料解析就绪后即可立册；系统会为本册独立识网并依据原文自动成题，知识图谱与 SM-2 再依照真实作答安排下一轮。章节练习和故事回响写回同一份掌握度。</p>
          </header>
          <div>
            <article><span>01</span><h3>收卷</h3><p>读取资料原文，保留章节、概念与每道题目的来源位置。</p></article>
            <article><span>02</span><h3>成题</h3><p>立册时自动生成单选、填空、名词解释与简答题，并逐题标明知识点和原文出处。</p></article>
            <article><span>03</span><h3>循网</h3><p>SM-2 判断遗忘风险，知识图谱补全先修关系并避免重复覆盖。</p></article>
            <article><span>04</span><h3>回响</h3><p>普通答题与故事答题都形成学习证据，更新下一次复习时机。</p></article>
          </div>
        </section>

        {recentProjects.length ? <section className="workspace-card home-recent-projects"><header><h2>最近的研习册</h2></header><div className="practice-project-list">
          {recentProjects.map((project) => <Link key={project.projectId} to={`/projects/${project.projectId}`}><span><strong>{project.name}</strong><small>{project.subjectCode || '未设置学科'} · {project.materialIds.length} 份资料 · {project.graphId ? '知识脉络已建立' : '待建立知识脉络'}</small></span><span>续读</span></Link>)}
        </div></section> : null}
      </main>
    </AppShell>
  )
}
