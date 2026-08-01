import { useEffect, useRef } from 'react'
import { BrowserRouter, Navigate, Route, Routes, useLocation } from 'react-router-dom'
import FeaturePlaceholderPage from './pages/FeaturePlaceholderPage'
import ForgotPasswordPage from './pages/ForgotPasswordPage'
import HomePage from './pages/HomePage'
import LoginPage from './pages/LoginPage'
import NotFoundPage from './pages/NotFoundPage'
import RegisterPage from './pages/RegisterPage'
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
  '/settings': 3,
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
        <Route path="/home" element={<HomePage />} />
        <Route path="/materials" element={<FeaturePlaceholderPage title="资料上传" description="资料列表、上传和解析任务将从这里接入 FileService。" />} />
        <Route path="/knowledge" element={<FeaturePlaceholderPage title="知识点" description="知识点详情与掌握度查询将从这里接入 KnowledgeService。" />} />
        <Route path="/knowledge-graph" element={<FeaturePlaceholderPage title="知识图谱" description="章节、知识点和关系图的可视化入口已经预留。" />} />
        <Route path="/review" element={<FeaturePlaceholderPage title="继续复习" description="复习计划、GalGame 游戏包与 WASM 会话将在这里汇合。" />} />
        <Route path="/settings" element={<FeaturePlaceholderPage title="个人设置" description="个人资料、学习目标、难度和减少动态效果的入口已经预留。" />} />
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
