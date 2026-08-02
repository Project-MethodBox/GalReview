import type { ReactNode } from 'react'
import { Link, NavLink, useLocation, useNavigate } from 'react-router'
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
  { to: '/settings', label: '设置', icon: SettingsIcon },
]

export default function AppShell({ children }: { children: ReactNode }) {
  const navigate = useNavigate()
  const location = useLocation()
  const profile = readProfile()
  const session = readSession()
  const avatarInitial = Array.from(profile?.displayName.trim() || '学')[0]
  const currentNavigation = navigation.find((item) => item.to === location.pathname)

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
        <Link className="rail-brand" to="/home" aria-label="千知万理主页" title="千知万理">
          <BrandMark compact />
          <span><strong>千知万理</strong><small>GalReview</small></span>
        </Link>
        <nav className="rail-nav" aria-label="主要导航">
          {navigation.map((item) => (
            <NavLink key={item.to} to={item.to} data-label={item.label} title={item.label} className={({ isActive }) => isActive ? 'active' : ''}><item.icon /><span>{item.label}</span></NavLink>
          ))}
        </nav>
        <div className="rail-account">
          <Link className="rail-profile" to="/settings" data-label="个人设置" title="个人设置">
            <span className="rail-avatar">{avatarInitial}</span>
            <span><strong>{profile?.displayName || '学习者'}</strong><small>个人设置</small></span>
          </Link>
          <button className="rail-logout" type="button" data-label="退出登录" title="退出登录" aria-label="退出登录" onClick={() => void logout()}><LogoutIcon /><span>退出</span></button>
        </div>
      </header>
      <header className="mobile-shell-head">
        <Link to="/home" aria-label="千知万理主页"><BrandMark compact /><strong>千知万理</strong></Link>
        <span>{currentNavigation?.label || '工作台'}</span>
        <button type="button" aria-label="退出登录" onClick={() => void logout()}><LogoutIcon /></button>
      </header>
      <div className="app-shell__content">{children}</div>
      <footer className="app-statusbar" aria-label="应用状态">
        <span><i aria-hidden="true" />本地会话已加载</span>
        <span>{currentNavigation?.label || '工作台'} · {profile?.displayName || '学习者'}</span>
      </footer>
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
  const location = useLocation()
  const navigationItem = navigation.find((item) => item.to === location.pathname)
  const HeaderIcon = navigationItem?.icon

  return (
    <header className="page-header">
      <div className="page-header__copy">
        {HeaderIcon ? <span className="page-header__icon" aria-hidden="true"><HeaderIcon /></span> : null}
        <div><h1>{title}</h1>{description ? <p>{description}</p> : null}</div>
      </div>
      {actions ? <div className="page-header__actions">{actions}</div> : null}
    </header>
  )
}
