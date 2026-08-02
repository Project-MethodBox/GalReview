import { useEffect, useRef, type ReactNode } from 'react'
import { BrowserRouter, Navigate, Route, Routes, useLocation } from 'react-router'
import ForgotPasswordPage from './pages/ForgotPasswordPage'
import HomePage from './pages/HomePage'
import KnowledgeGraphPage from './pages/KnowledgeGraphPage'
import KnowledgePointsPage from './pages/KnowledgePointsPage'
import LoginPage from './pages/LoginPage'
import NotFoundPage from './pages/NotFoundPage'
import RegisterPage from './pages/RegisterPage'
import ReviewPage from './pages/ReviewPage'
import StudyFlowPage from './pages/StudyFlowPage'
import { readSession } from './lib/session'

const routeDepth: Record<string, number> = {
  '/login': 0,
  '/register': 1,
  '/forgot-password': 1,
  '/home': 2,
  '/materials': 3,
  '/knowledge': 3,
  '/knowledge-graph': 3,
  '/review': 3,
}

function Protected({ children }: { children: ReactNode }) {
  return readSession() ? children : <Navigate replace to="/login" state={{ message: '请先登录。' }} />
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

  return (
    <div className={`route-transition route-transition--${direction}`} key={location.key}>
      <Routes location={location}>
        <Route path="/" element={<Navigate replace to={readSession() ? '/home' : '/login'} />} />
        <Route path="/login" element={<LoginPage />} />
        <Route path="/register" element={<RegisterPage />} />
        <Route path="/forgot-password" element={<ForgotPasswordPage />} />
        <Route path="/home" element={<Protected><HomePage /></Protected>} />
        <Route path="/materials" element={<Protected><StudyFlowPage /></Protected>} />
        <Route path="/knowledge" element={<Protected><KnowledgePointsPage /></Protected>} />
        <Route path="/knowledge-graph" element={<Protected><KnowledgeGraphPage /></Protected>} />
        <Route path="/review" element={<Protected><ReviewPage /></Protected>} />
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
