import { useEffect, type ReactNode } from 'react'
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
        title: <>管理学习账户，<br />维护项目准入。</>,
        description: '管理员可管理已注册用户、重置用户密码，并创建、复制或删除注册邀请码。',
      }
    : isPasswordRecovery
    ? {
        eyebrow: '找回你的账户',
        title: <>继续你的学习，<br />不丢失每一步。</>,
        description: '提交登录邮箱后，系统会发送验证码。重设密码后，旧登录会话将自动失效。',
      }
    : {
        eyebrow: '知识图谱驱动的互动复习',
        title: <>知识有图谱，<br />复习有剧情。</>,
        description: '上传资料、梳理知识、进入剧情，在每一次选择中完成更有记忆点的复习。',
      }
  const cardVariant = storyCardVariant ?? (page === 'login' || isAdmin ? 'blue' : 'black')

  if (isAccountEntry) {
    return (
      <main className={`auth-page auth-page--entry auth-page--${page}`}>
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
              <small>{isAdmin ? '项目准入管理' : cardVariant === 'blue' ? '下一段复习剧情' : '一次真实复习闭环'}</small>
              <strong>{isAdmin ? '邀请码按规则生成' : cardVariant === 'blue' ? '发现薄弱点，再做出选择' : '资料 → 图谱 → 剧情 → 掌握度'}</strong>
              <span>{isAdmin ? '支持一次性、多次与限时邀请码。' : cardVariant === 'blue' ? '让每一次复习都有继续探索的理由。' : '在每一个选择中巩固知识点。'}</span>
            </div>
            <div className={`auth-entry-card auth-entry-card--${cardVariant === 'blue' ? 'black' : 'blue'} auth-entry-card--two`}>
              <small>{cardVariant === 'blue' ? '一次真实复习闭环' : '下一段复习剧情'}</small>
              <strong>{cardVariant === 'blue' ? '资料 → 图谱 → 剧情 → 掌握度' : '发现薄弱点，再做出选择'}</strong>
              <span>{cardVariant === 'blue' ? '在每一个选择中巩固知识点。' : '让每一次复习都有继续探索的理由。'}</span>
            </div>
            <div className="auth-entry-card auth-entry-card--three">
              <small>今天的复习目标</small>
              <strong>从一个知识点，走进一段剧情</strong>
              <span>把理解、选择与记忆串成属于你的学习路径。</span>
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
