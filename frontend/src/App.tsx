import { useEffect, useRef, useState, type ReactNode } from 'react'
import { BrowserRouter, Navigate, Route, Routes, useLocation } from 'react-router'
import ForgotPasswordPage from './pages/ForgotPasswordPage'
import AdminLoginPage from './pages/AdminLoginPage'
import AdminPage from './pages/AdminPage'
import HomePage from './pages/HomePage'
import KnowledgeGraphPage from './pages/KnowledgeGraphPage'
import KnowledgePointsPage from './pages/KnowledgePointsPage'
import LoginPage from './pages/LoginPage'
import NotFoundPage from './pages/NotFoundPage'
import RegisterPage from './pages/RegisterPage'
import ReviewPage from './pages/ReviewPage'
import SettingsPage from './pages/SettingsPage'
import StudyFlowPage from './pages/StudyFlowPage'
import LoadingIndicator from './components/LoadingIndicator'
import { api, ApiClientError } from './lib/api'
import { clearSession, readSession } from './lib/session'
import { readAdminSession } from './lib/adminSession'
import { recoverWorkflow } from './lib/workflowRecovery'

const routeDepth: Record<string, number> = {
  '/login': 0,
  '/register': 1,
  '/forgot-password': 1,
  '/admin/login': 0,
  '/admin': 1,
  '/home': 2,
  '/materials': 3,
  '/knowledge': 3,
  '/knowledge-graph': 3,
  '/review': 3,
  '/settings': 3,
}

const pageTitles: Record<string, string> = {
  '/login': '登录',
  '/register': '注册',
  '/forgot-password': '找回密码',
  '/admin/login': '管理员登录',
  '/admin': '观测台',
  '/home': '起点',
  '/materials': '藏书阁',
  '/knowledge': '拾知',
  '/knowledge-graph': '知网',
  '/review': '回响',
  '/settings': '我的',
}

function Protected({ children }: { children: ReactNode }) {
  const session = readSession()
  const [ready, setReady] = useState(false)
  const [valid, setValid] = useState(Boolean(session))

  useEffect(() => {
    if (!session) return
    let active = true
    void api.getSession(session.session.sessionId).then((remoteSession) => {
      if (remoteSession.status !== 'ACTIVE') {
        throw new ApiClientError('登录状态已失效，请重新登录。', 'AUTH_REQUIRED', 401)
      }
      return recoverWorkflow()
    }).then(() => {
      if (active) setValid(true)
    }).catch((reason: unknown) => {
      if (!active) return
      if (reason instanceof ApiClientError && (reason.status === 401 || reason.status === 404)) {
        clearSession()
        setValid(false)
      }
    }).finally(() => { if (active) setReady(true) })
    return () => { active = false }
  }, [session?.session.sessionId])

  if (!session || !valid) return <Navigate replace to="/login" state={{ message: '登录状态已失效，请重新登录。' }} />
  if (!ready) return <main className="app-loading"><LoadingIndicator label="正在恢复学习资料" /></main>
  return children
}

function AdminProtected({ children }: { children: ReactNode }) {
  return readAdminSession() ? children : <Navigate replace to="/admin/login" />
}

function AnimatedRoutes() {
  const location = useLocation()
  const previousPath = useRef(location.pathname)
  const previousDepth = routeDepth[previousPath.current] ?? 0
  const currentDepth = routeDepth[location.pathname] ?? 0
  const direction = previousPath.current === location.pathname
    ? 'neutral'
    : currentDepth > previousDepth ? 'forward' : currentDepth < previousDepth ? 'back' : 'neutral'

  useEffect(() => {
    previousPath.current = location.pathname
  }, [location.pathname])

  useEffect(() => {
    document.title = `${pageTitles[location.pathname] ?? '页面未找到'} · 千知万理`
  }, [location.pathname])

  return (
    <div className={`route-transition route-transition--${direction}`} key={location.key}>
      <Routes location={location}>
        <Route path="/" element={<Navigate replace to={readSession() ? '/home' : '/login'} />} />
        <Route path="/login" element={<LoginPage />} />
        <Route path="/register" element={<RegisterPage />} />
        <Route path="/forgot-password" element={<ForgotPasswordPage />} />
        <Route path="/admin/login" element={<AdminLoginPage />} />
        <Route path="/admin" element={<AdminProtected><AdminPage /></AdminProtected>} />
        <Route path="/home" element={<Protected><HomePage /></Protected>} />
        <Route path="/materials" element={<Protected><StudyFlowPage /></Protected>} />
        <Route path="/knowledge" element={<Protected><KnowledgePointsPage /></Protected>} />
        <Route path="/knowledge-graph" element={<Protected><KnowledgeGraphPage /></Protected>} />
        <Route path="/review" element={<Protected><ReviewPage /></Protected>} />
        <Route path="/settings" element={<Protected><SettingsPage /></Protected>} />
        <Route path="*" element={<NotFoundPage />} />
      </Routes>
    </div>
  )
}

export default function App() {
  return (
    <BrowserRouter>
      <AnimatedRoutes />
    </BrowserRouter>
  )
}
