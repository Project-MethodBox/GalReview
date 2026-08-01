import { Link } from 'react-router'

export default function NotFoundPage() {
  return <main className="not-found"><span>404</span><h1>这一页暂时没有知识点</h1><Link to="/home">返回主页</Link></main>
}
