import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import FeaturePlaceholderPage from './pages/FeaturePlaceholderPage'
import ForgotPasswordPage from './pages/ForgotPasswordPage'
import HomePage from './pages/HomePage'
import LoginPage from './pages/LoginPage'
import NotFoundPage from './pages/NotFoundPage'
import RegisterPage from './pages/RegisterPage'
import { readSession } from './lib/session'

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
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
    </BrowserRouter>
  )
}
