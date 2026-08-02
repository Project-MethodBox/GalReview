import type { ReactNode } from 'react'
import BrandMark from './BrandMark'

interface AuthLayoutProps {
  children: ReactNode
  page: 'login' | 'register' | 'forgot' | 'admin'
}

export default function AuthLayout({ children, page }: AuthLayoutProps) {
  return (
    <main className={`auth-page auth-page--${page}`}>
      <section className="auth-page__content">{children}</section>
      <aside className="auth-page__mark" aria-hidden="true"><BrandMark /></aside>
      <footer className="auth-page__footer">
        <span>让每一次复习都有迹可循</span>
        <span>© 2026 千知万理 · GalReview</span>
      </footer>
    </main>
  )
}

export function AuthHeading({ title, subtitle }: { title: string; subtitle: string }) {
  return (
    <header className="auth-heading">
      <h1>千知万理</h1>
      <h2>{title}</h2>
      <p>{subtitle}</p>
    </header>
  )
}
