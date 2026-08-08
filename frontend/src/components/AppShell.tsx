import type { ReactNode } from 'react'
import { Link, NavLink, useLocation, useNavigate } from 'react-router'
import { api } from '../lib/api'
import { clearSession, readProfile, readSession } from '../lib/session'
import { resetWorkflow } from '../lib/workflow'
import BrandMark from './BrandMark'
import { BookIcon, GraphIcon, HomeIcon, LogoutIcon, MaterialsIcon, SettingsIcon } from './icons'

const navigation = [
  { to: '/home', label: '起点', icon: HomeIcon },
  { to: '/materials', label: '藏书阁', icon: MaterialsIcon },
  { to: '/projects', label: '研习册', icon: BookIcon },
  { to: '/knowledge-graph', label: '识网', icon: GraphIcon },
  { to: '/settings', label: '我的', icon: SettingsIcon },
]

export default function AppShell({ children }: { children: ReactNode }) {
  const navigate = useNavigate()
  const location = useLocation()
  const profile = readProfile()
  const session = readSession()
  const avatarInitial = Array.from(profile?.displayName.trim() || '学')[0]
  const currentNavigation = navigation.find((item) => item.to === location.pathname || (item.to !== '/home' && location.pathname.startsWith(`${item.to}/`)))

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
  return (
    <header className={`page-header${description ? ' page-header--has-description' : ''}${actions ? ' page-header--has-actions' : ''}`}>
      <div className="page-header__copy">
        <div><h1>{title}</h1>{description ? <p>{description}</p> : null}</div>
      </div>
      {actions ? <div className="page-header__actions">{actions}</div> : null}
    </header>
  )
}
