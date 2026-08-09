import { useEffect, type ReactNode } from 'react'
import { Link } from 'react-router'
import BrandMark from './BrandMark'

interface AuthLayoutProps {
  children: ReactNode
  page: 'login' | 'register' | 'forgot' | 'admin'
  storyCardVariant?: 'black' | 'blue'
}

export default function AuthLayout({ children, page, storyCardVariant }: AuthLayoutProps) {
  useEffect(() => {
    const pageTitles: Record<AuthLayoutProps['page'], string> = {
      login: '登录',
      register: '注册',
      forgot: '找回密码',
      admin: '管理员登录',
    }
    document.title = `${pageTitles[page]} · 千知万理`
  }, [page])

  const isAdmin = page === 'admin'
  const isAccountEntry = page === 'login' || page === 'register' || page === 'forgot' || isAdmin
  const isPasswordRecovery = page === 'forgot'
  const story = isAdmin
    ? {
        eyebrow: 'MOONSTONE ADMIN',
        title: <>管理学习账户，<br />维护研习用量。</>,
        description: '管理员可管理已注册用户、重置用户密码，并生成、批量管理 credits 兑换码。',
      }
    : isPasswordRecovery
    ? {
        eyebrow: '找回你的账户',
        title: <>继续你的学习，<br />不丢失每一步。</>,
        description: '提交登录邮箱后，系统会发送验证码。重设密码后，旧登录会话将自动失效。',
      }
    : {
        eyebrow: '智能解析与循序复习',
        title: <>一卷成册，<br />循知而习。</>,
        description: '收录资料、梳理识网、生成题笺，再由 SM-2 安排每一次恰到其时的温习。',
      }
  const cardVariant = storyCardVariant ?? (page === 'login' || isAdmin ? 'blue' : 'black')

  if (isAccountEntry) {
    return (
      <main className={`auth-page auth-page--entry auth-page--${page}`}>
        {page === 'login' || page === 'register' ? (
          <Link className="auth-entry-home-link" to="/">返回官网</Link>
        ) : null}
        <aside className="auth-entry-story" aria-label="千知万理产品介绍">
          <div className="auth-entry-brand">
            <BrandMark compact />
            <span>千知万理</span>
          </div>

          <div className="auth-entry-copy">
            <p>{story.eyebrow}</p>
            <h1>{story.title}</h1>
            <span>{story.description}</span>
          </div>

          <div className="auth-entry-card-stack" aria-hidden="true">
            <div className={`auth-entry-card auth-entry-card--${cardVariant} auth-entry-card--one`}>
              <small>{isAdmin ? '研习用量管理' : cardVariant === 'blue' ? '今天应当温习' : '一次完整复习闭环'}</small>
              <strong>{isAdmin ? '兑换码按批次生成' : cardVariant === 'blue' ? '循着遗忘风险，重访薄弱处' : '资料 → 立册 → 识网 → 题笺'}</strong>
              <span>{isAdmin ? '支持批量生成、查询与状态管理。' : cardVariant === 'blue' ? '由知识关系补足前置与相邻概念。' : '普通答题与故事回响共用同一份记录。'}</span>
            </div>
            <div className={`auth-entry-card auth-entry-card--${cardVariant === 'blue' ? 'black' : 'blue'} auth-entry-card--two`}>
              <small>{cardVariant === 'blue' ? '一次完整复习闭环' : '今天应当温习'}</small>
              <strong>{cardVariant === 'blue' ? '资料 → 立册 → 识网 → 题笺' : '循着遗忘风险，重访薄弱处'}</strong>
              <span>{cardVariant === 'blue' ? '普通答题与故事回响共用同一份记录。' : '由知识关系补足前置与相邻概念。'}</span>
            </div>
            <div className="auth-entry-card auth-entry-card--three">
              <small>今天的复习目标</small>
              <strong>从一册题笺，重访今日所学</strong>
              <span>故事回响始终是研习册内可选择的复习方式。</span>
            </div>
          </div>
        </aside>

        <section className="auth-page__content">{children}</section>
      </main>
    )
  }

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

export function AuthEntryHeading({ kicker, title, subtitle }: { kicker: string; title: string; subtitle: string }) {
  return (
    <header className="auth-entry-heading">
      <p>{kicker}</p>
      <h1>{title}</h1>
      <span>{subtitle}</span>
    </header>
  )
}
