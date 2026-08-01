import { Link } from 'react-router'

interface HomeFeatureCardProps {
  title: string
  to: string
  icon: 'continue' | 'points' | 'upload' | 'graph'
  wide?: boolean
}

export default function HomeFeatureCard({ title, to, icon, wide }: HomeFeatureCardProps) {
  return (
    <Link className={`feature-card${wide ? ' feature-card--wide' : ''}`} to={to} aria-label={`进入${title}`}>
      <img src={`/icons/${icon}.svg`} alt="" />
      <strong>{title}</strong>
    </Link>
  )
}
