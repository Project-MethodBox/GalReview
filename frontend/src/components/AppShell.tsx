import type { ReactNode } from 'react'
import { Link, NavLink, useNavigate } from 'react-router'
import { api } from '../lib/api'
import { clearSession, readProfile, readSession } from '../lib/session'
import { resetWorkflow } from '../lib/workflow'
import BrandMark from './BrandMark'
import { GraphIcon, HomeIcon, KnowledgeIcon, LogoutIcon, MaterialsIcon, ReviewIcon, SettingsIcon } from './icons'

const navigation = [
  { to: '/home', label: '主页', icon: HomeIcon },
  { to: '/materials', label: '资料', icon: MaterialsIcon },
  { to: '/knowledge', label: '知识点', icon: KnowledgeIcon },
  { to: '/knowledge-graph', label: '图谱', icon: GraphIcon },
  { to: '/review', label: '复习', icon: ReviewIcon },
  { to: '/settings', label: '设置', icon: SettingsIcon, mobileOnly: true },
]

export default function AppShell({ children }: { children: ReactNode }) {
  const navigate = useNavigate()
  const profile = readProfile()
  const session = readSession()
  const avatarInitial = Array.from(profile?.displayName.trim() || '学')[0]

  async function logout() {
    try {
      if (session) await api.logout(session.session.sessionId)
    } finally {
      clearSession()
      resetWorkflow()
      navigate('/login', { replace: true })
    }
  }

  return (
    <div className="app-shell">
      <header className="app-rail">
        <Link className="rail-brand" to="/home" aria-label="千知万理主页">
          <BrandMark compact />
          <span><strong>千知万理</strong><small>GalReview</small></span>
        </Link>
        <nav className="rail-nav" aria-label="主要导航">
          {navigation.map((item) => (
            <NavLink key={item.to} to={item.to} className={({ isActive }) => `${item.mobileOnly ? 'mobile-nav-only ' : ''}${isActive ? 'active' : ''}`.trim()}><item.icon /><span>{item.label}</span></NavLink>
          ))}
        </nav>
        <div className="rail-account">
          <Link className="rail-profile" to="/settings">
            <span className="rail-avatar">{avatarInitial}</span>
            <span><strong>{profile?.displayName || '学习者'}</strong><small>个人设置</small></span>
          </Link>
          <div className="rail-actions">
            <Link to="/settings" aria-label="打开设置"><SettingsIcon /><span>设置</span></Link>
            <button type="button" onClick={() => void logout()}><LogoutIcon /><span>退出</span></button>
          </div>
        </div>
      </header>
      <div className="app-shell__content">{children}</div>
    </div>
  )
}

export function PageHeader({
  title,
  description,
  actions,
}: {
  title: string
  description?: string
  actions?: ReactNode
}) {
  return (
    <header className="page-header">
      <div><h1>{title}</h1>{description ? <p>{description}</p> : null}</div>
      {actions ? <div className="page-header__actions">{actions}</div> : null}
    </header>
  )
}
