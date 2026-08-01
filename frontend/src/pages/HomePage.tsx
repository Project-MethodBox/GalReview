import { useEffect, useState } from 'react'
import { Link, useLocation, useNavigate } from 'react-router-dom'
import HomeFeatureCard from '../components/HomeFeatureCard'
import { BookIcon, ClockIcon, FullscreenIcon, SettingsIcon } from '../components/icons'
import { clearSession, readProfile, readSession } from '../lib/session'

export default function HomePage() {
  const location = useLocation()
  const navigate = useNavigate()
  const profile = readProfile()
  const session = readSession()
  const [message, setMessage] = useState((location.state as { message?: string } | null)?.message || '')
  const [dark, setDark] = useState(document.documentElement.dataset.theme === 'dark')

  useEffect(() => {
    if (!message) return
    const id = window.setTimeout(() => setMessage(''), 5000)
    return () => window.clearTimeout(id)
  }, [message])

  function toggleTheme() {
    const next = !dark
    setDark(next)
    document.documentElement.dataset.theme = next ? 'dark' : 'light'
  }

  async function toggleFullscreen() {
    if (document.fullscreenElement) await document.exitFullscreen()
    else await document.documentElement.requestFullscreen()
  }

  return (
    <main className="home-page">
      <header className="home-header">
        <div className="home-title">
          <h1>千知万理</h1>
          <h2>主页</h2>
          <p>千知温故，万理知新。</p>
        </div>
        <div className="home-actions">
          <nav className="toolbar" aria-label="快捷导航">
            <button type="button" aria-label="切换全屏" onClick={toggleFullscreen}><FullscreenIcon /></button>
            <Link to="/materials" aria-label="资料库"><BookIcon /></Link>
            <Link to="/review" aria-label="复习记录"><ClockIcon /></Link>
            <span className="toolbar__divider" />
            <button type="button" aria-label="切换明暗主题" onClick={toggleTheme}><SettingsIcon /></button>
          </nav>
          <Link className="profile-pill" to="/settings">
            <span><strong>{profile?.displayName || 'UserNametest'}</strong><small>{session?.demo ? '测试会话' : 'Level 1'}</small></span>
            <span><strong>学习档案</strong><small>{profile?.preferredSubjectCodes[0] || '待完善'}</small></span>
            <img src="/profile-avatar.svg" alt="用户头像" />
          </Link>
        </div>
      </header>

      {message ? <p className="home-message" role="status">{message}</p> : null}

      <section className="feature-grid" aria-label="学习功能">
        <HomeFeatureCard title="继续" to="/review" icon="continue" />
        <HomeFeatureCard title="知识点" to="/knowledge" icon="points" />
        <HomeFeatureCard title="资料上传" to="/materials" icon="upload" />
        <HomeFeatureCard title="知识图谱" to="/knowledge-graph" icon="graph" wide />
      </section>

      <button className="home-logout" type="button" onClick={() => { clearSession(); navigate('/login') }}>退出登录</button>
    </main>
  )
}
