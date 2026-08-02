import { useNavigate } from 'react-router'
import BrandMark from '../components/BrandMark'
import { BackIcon } from '../components/icons'

export default function FeaturePlaceholderPage({ title, description }: { title: string; description: string }) {
  const navigate = useNavigate()
  return (
    <main className="placeholder-page">
      <button className="placeholder-page__back" type="button" onClick={() => navigate('/home')}><BackIcon />返回主页</button>
      <section>
        <BrandMark compact />
        <p>功能准备中</p>
        <h1>{title}</h1>
        <p>{description}</p>
        <button type="button" onClick={() => navigate('/home')}>返回主页</button>
      </section>
    </main>
  )
}
