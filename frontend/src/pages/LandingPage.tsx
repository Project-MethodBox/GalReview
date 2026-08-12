import { useEffect, useRef, useState, type CSSProperties } from 'react'
import { Link, useNavigate } from 'react-router'
import BrandMark from '../components/BrandMark'
import { GraphIcon, KnowledgeIcon, MaterialsIcon, ReviewIcon } from '../components/icons'
import { readSession } from '../lib/session'

const features = [
  {
    title: '从资料中提取可复习内容',
    description: '上传讲义、笔记或题库后，系统先解析原文，再由 AI 辅助识别章节、概念与可出题内容。生成结果保留资料来源，便于核对。',
    icon: MaterialsIcon,
  },
  {
    title: '把资料整理成自己的题库',
    description: '围绕同一研习册管理单选、填空、判断、名词解释与简答题。既可生成题目，也可导入旧题库，并在确认后进入复习。',
    icon: KnowledgeIcon,
  },
  {
    title: '让知识图谱参与复习安排',
    description: '知识关系、练习结果与 SM-2 复习状态共同决定下一轮内容。系统优先安排薄弱、到期且与当前目标相关的知识。',
    icon: GraphIcon,
  },
  {
    title: '在需要时进入故事复习',
    description: '视觉小说不是独立项目，而是研习册中的一种复习方式。题目与剧情仍基于同一份资料、同一张识网和同一套掌握记录。',
    icon: ReviewIcon,
  },
]

const characters = [
  {
    name: '林学姐 · 林晚棠',
    role: '神秘学研究社社长',
    desc: '沉静、温柔，似乎总比别人更早察觉藏在日常里的异样。她递来的糖果是鼓励，也可能是一场新调查的邀请。面对混乱的知识，她擅长抓住关键线索，陪你把谜团一点点解开。',
    color: '#d95a67',
    image: '/chr_lin_wantang_uniform_lollipop-rest_neutral_v01.png',
    alt: '林学姐林晚棠角色立绘',
  },
  {
    name: '苏学妹 · 苏晚晴',
    role: '新闻社副社长',
    desc: '好奇心旺盛，行动力十足，相机和记事本从不离身。她会把每个新知识都当作值得追踪的独家线索，用接连不断的问题带你重新观察那些容易忽略的细节。',
    color: '#55a77b',
    image: '/chr_su_wanqing_uniform_reporter-ready_curious_v01.png',
    alt: '苏学妹苏晚晴角色立绘',
    portraitClassName: 'landing-character-card__portrait-img--su',
  },
  {
    name: '陆学长 · 陆沉',
    role: '学生会副会长 · 物理社社长',
    desc: '冷静克制，习惯用记录、测量与推理面对未知。无论问题多复杂，他都会先拆开现象、核对证据，再带你找到最可靠的答案。',
    color: '#6d9fc7',
    image: '/chr_lu_chen_uniform_dark-alert_uneasy_v01.png',
    alt: '陆学长陆沉角色立绘',
  },
]

const steps = [
  { num: '01', title: '上传并解析资料', desc: '文件解析与文字识别先还原原文，再整理章节、概念与知识脉络。关键结果都能回到资料来源核对。' },
  { num: '02', title: '立册并自动成题', desc: '建立研习册后立即生成单选、填空、名词解释与简答题；判断题和既有题库可通过整卷或项目包导入。' },
  { num: '03', title: '开始智能复习', desc: '选择日常练习、智能复习或模拟考试。知识图谱与 SM-2 结合当前掌握度，安排更需要复习的内容。' },
  { num: '04', title: '用结果驱动下一轮', desc: '作答结果回写掌握记录与复习间隔；需要换一种方式巩固时，还可以在同一项目中进入视觉小说复习。' },
]

const faqs = [
  {
    q: '千知万理适合什么学科？',
    a: '千知万理支持上传不同学科的讲义、笔记或题库。目前更适合结构清楚、可以从原文核对答案的学习资料。',
  },
  {
    q: 'AI 在解析和复习中做什么？',
    a: 'AI 用于故事表达和有出处的解释辅助；文件解析、题目生成、答案判定与复习调度都有明确规则和降级路径。自动题只有在答案、知识点和原文出处均可核对时才会入库。',
  },
  {
    q: '故事复习和普通练习是什么关系？',
    a: '故事复习是研习册中的可选方式。它与章节练习、智能复习和模拟试卷共用资料、题笺、识网与掌握记录，不会另建一套孤立数据。',
  },
  {
    q: '需要安装软件吗？',
    a: '不需要。打开浏览器即可使用，支持上传文件、查看知识图谱和进行互动复习。所有数据都会同步到你的账户中。',
  },
  {
    q: '我的学习数据安全吗？',
    a: '你的学习数据、复习记录和知识图谱都会安全存储在你的账户中。我们不会将你的个人学习数据用于其他用途。',
  },
]

const heroMessages = [
  { text: '让资料真正成为主角', accentStart: 7, accentLength: 2, tone: 'blue' },
  { text: '让练习成为日常主线', accentStart: 5, accentLength: 4, tone: 'violet' },
  { text: '让知识彼此连接', accentStart: 3, accentLength: 4, tone: 'teal' },
  { text: '让复习拥有故事感', accentStart: 5, accentLength: 3, tone: 'rose' },
  { text: '让进步有迹可循', accentStart: 3, accentLength: 4, tone: 'amber' },
  {
    text: '千知万理，\n让你真正学会',
    accentStart: 8,
    accentLength: 4,
    brandStart: 0,
    brandLength: 4,
    tone: 'final',
  },
] as const

const finalHeroMessageIndex = heroMessages.length - 1

function useSmoothScroll() {
  const navigate = useNavigate()
  return (href: string) => {
    if (href.startsWith('#')) {
      const id = href.slice(1)
      const el = document.getElementById(id)
      if (el) {
        el.scrollIntoView({ behavior: 'smooth', block: 'start' })
        return
      }
    }
    navigate(href)
  }
}

export default function LandingPage() {
  const scroll = useSmoothScroll()
  const [typewriterState, setTypewriterState] = useState({
    messageIndex: 0,
    visibleCharacters: 0,
    deleting: false,
    finished: false,
  })
  const scrollProgressRef = useRef<HTMLSpanElement>(null)
  const workspacePath = readSession() ? '/home' : '/login'

  useEffect(() => {
    const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches
      || document.documentElement.dataset.reducedMotion === 'true'

    if (prefersReducedMotion) {
      const finalMessage = heroMessages[finalHeroMessageIndex]
      const alreadyShowingFinalMessage = typewriterState.messageIndex === finalHeroMessageIndex
        && typewriterState.visibleCharacters === finalMessage.text.length
        && typewriterState.finished

      if (!alreadyShowingFinalMessage) {
        setTypewriterState({
          messageIndex: finalHeroMessageIndex,
          visibleCharacters: finalMessage.text.length,
          deleting: false,
          finished: true,
        })
      }
      return
    }

    if (typewriterState.finished) return

    const message = heroMessages[typewriterState.messageIndex]
    let delay = 0

    if (!typewriterState.deleting && typewriterState.visibleCharacters < message.text.length) {
      delay = 78
    } else if (!typewriterState.deleting && typewriterState.messageIndex < finalHeroMessageIndex) {
      delay = 920
    } else if (typewriterState.deleting && typewriterState.visibleCharacters > 0) {
      delay = 38
    } else if (typewriterState.deleting) {
      delay = 140
    } else {
      return
    }

    const timer = window.setTimeout(() => {
      setTypewriterState((current) => {
        const currentMessage = heroMessages[current.messageIndex]

        if (!current.deleting && current.visibleCharacters < currentMessage.text.length) {
          const visibleCharacters = current.visibleCharacters + 1
          return {
            ...current,
            visibleCharacters,
            finished: current.messageIndex === finalHeroMessageIndex
              && visibleCharacters === currentMessage.text.length,
          }
        }

        if (!current.deleting && current.messageIndex < finalHeroMessageIndex) {
          return { ...current, deleting: true }
        }

        if (current.deleting && current.visibleCharacters > 0) {
          return { ...current, visibleCharacters: current.visibleCharacters - 1 }
        }

        return {
          messageIndex: Math.min(current.messageIndex + 1, finalHeroMessageIndex),
          visibleCharacters: 0,
          deleting: false,
          finished: false,
        }
      })
    }, delay)

    return () => window.clearTimeout(timer)
  }, [typewriterState])

  useEffect(() => {
    let animationFrame = 0

    const updateScrollProgress = () => {
      animationFrame = 0
      const progressBar = scrollProgressRef.current
      if (!progressBar) return

      const scrollableHeight = document.documentElement.scrollHeight - window.innerHeight
      const progress = scrollableHeight > 0
        ? Math.min(1, Math.max(0, window.scrollY / scrollableHeight))
        : 0

      progressBar.style.transform = `scaleX(${progress})`
    }

    const scheduleScrollProgressUpdate = () => {
      if (animationFrame === 0) {
        animationFrame = window.requestAnimationFrame(updateScrollProgress)
      }
    }

    updateScrollProgress()
    window.addEventListener('scroll', scheduleScrollProgressUpdate, { passive: true })
    window.addEventListener('resize', scheduleScrollProgressUpdate)

    return () => {
      window.removeEventListener('scroll', scheduleScrollProgressUpdate)
      window.removeEventListener('resize', scheduleScrollProgressUpdate)
      if (animationFrame !== 0) window.cancelAnimationFrame(animationFrame)
    }
  }, [])

  const activeHeroMessage = heroMessages[typewriterState.messageIndex]
  const visibleHeroText = activeHeroMessage.text.slice(0, typewriterState.visibleCharacters)
  const finalHeroLabel = heroMessages[finalHeroMessageIndex].text.replace('\n', '')

  return (
    <div className="landing">
      <header className="landing-nav">
        <div className="landing-nav__inner">
          <Link className="landing-brand" to="/">
            <BrandMark compact />
            <span>
              <strong>千知万理</strong>
            </span>
          </Link>
          <nav className="landing-nav__links">
            <Link to="#features" onClick={(e) => { e.preventDefault(); scroll('#features') }}>核心特色</Link>
            <Link to="#characters" onClick={(e) => { e.preventDefault(); scroll('#characters') }}>故事回响</Link>
            <Link to="#workflow" onClick={(e) => { e.preventDefault(); scroll('#workflow') }}>使用流程</Link>
            <Link to="#faq" onClick={(e) => { e.preventDefault(); scroll('#faq') }}>常见问题</Link>
            <a href="/wiki/">使用 Wiki</a>
          </nav>
          <div className="landing-nav__actions">
            <Link className="landing-workspace-link" to={workspacePath}>
              <span>进入工作台</span>
              <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M4.5 10h10M10.5 6l4 4-4 4" /></svg>
            </Link>
          </div>
        </div>
        <span ref={scrollProgressRef} className="landing-nav__progress" aria-hidden="true" />
      </header>

      <main>
        <section className="landing-hero">
          <div className="landing-hero__inner">
            <p className="landing-hero__eyebrow">
              <span className="landing-hero__eyebrow-dot" /> 知识图谱驱动的互动复习
            </p>
            <h1
              className="landing-hero__title"
              aria-label={finalHeroLabel}
            >
              <span
                className={`landing-hero__typed landing-hero__typed--${activeHeroMessage.tone}`}
                aria-hidden="true"
              >
                {Array.from(visibleHeroText).map((character, characterIndex) => {
                  if (character === '\n') {
                    return <br className="landing-hero__typewriter-break" key={`break-${characterIndex}`} />
                  }

                  const characterClasses = ['landing-hero__typewriter-char']
                  const accentEnd = activeHeroMessage.accentStart + activeHeroMessage.accentLength
                  if (characterIndex >= activeHeroMessage.accentStart && characterIndex < accentEnd) {
                    characterClasses.push('landing-hero__typewriter-char--accent')
                  }

                  if ('brandStart' in activeHeroMessage) {
                    const brandEnd = activeHeroMessage.brandStart + activeHeroMessage.brandLength
                    if (characterIndex >= activeHeroMessage.brandStart && characterIndex < brandEnd) {
                      characterClasses.push('landing-hero__typewriter-char--brand')
                    }
                  }

                  return (
                    <span
                      className={characterClasses.join(' ')}
                      key={`${typewriterState.messageIndex}-${characterIndex}`}
                      style={{
                        '--typewriter-char-index': Math.max(0, characterIndex - activeHeroMessage.accentStart),
                      } as CSSProperties}
                    >
                      {character}
                    </span>
                  )
                })}
                {!typewriterState.finished && <span className="landing-hero__typewriter-caret" />}
              </span>
            </h1>
            <p className="landing-hero__subtitle">
              从一份资料，到一套持续生长的知识体系。千知万理贯通原文解析、题库构建与智能复习，
              以知识图谱和 SM-2 编排学习节奏；视觉小说则让每一次重温更具沉浸感。
            </p>
            <div className="landing-hero__actions">
              <Link className="button button--primary landing-hero__cta landing-glass-button" to="/register">建立第一册研习</Link>
              <button className="button button--light landing-glass-button" onClick={() => scroll('#workflow')}>了解解析与复习流程</button>
            </div>
          </div>
          <div className="landing-hero__preview" aria-hidden="true">
            <div className="landing-hero__preview-inner">
              <div className="landing-app-mock">
                <div className="landing-app-mock__chrome">
                  <div className="landing-app-mock__dots">
                    <span className="landing-app-mock__dot landing-app-mock__dot--red" />
                    <span className="landing-app-mock__dot landing-app-mock__dot--yellow" />
                    <span className="landing-app-mock__dot landing-app-mock__dot--green" />
                  </div>
                  <div className="landing-app-mock__url">galreview.app</div>
                </div>
                <div className="landing-app-mock__stage landing-app-mock__stage--review">
                  <div className="landing-review-mock">
                    <header><span>研习册</span><strong>数据结构期末复习</strong><small>6 章 · 42 个知识点 · 96 道题</small></header>
                    <div className="landing-review-mock__stats"><span><small>今日待习</small><strong>12</strong></span><span><small>已掌握</small><strong>68%</strong></span><span><small>连续温习</small><strong>7 天</strong></span></div>
                    <div className="landing-review-mock__list"><span><i>01</i><b>树与二叉树</b><small>4 个知识点待回看</small></span><span><i>02</i><b>图的遍历</b><small>下一次复习：今天</small></span><span><i>03</i><b>排序算法</b><small>掌握度稳定</small></span></div>
                    <div className="landing-review-mock__actions"><span>开始章节温习</span><span>模拟试卷</span><span>故事回响</span></div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section id="features" className="landing-features">
          <div className="landing-features__inner">
            <div className="landing-feature-split">
              <div className="landing-feature-split__copy">
                <h2>让每份资料，<br />进入可持续的复习循环。</h2>
                <p className="landing-features__intro">
              资料、题库、知识图谱和复习记录属于同一册经典复习项目。
                  AI 负责辅助理解与生成，明确规则负责判定与调度，你始终可以核对来源并确认内容。
                </p>
                <ul className="landing-feature-list">
                  {features.map((feature) => (
                    <li key={feature.title}>
                      <span className="landing-feature-list__icon"><feature.icon /></span>
                      <div>
                        <strong>{feature.title}</strong>
                        <p>{feature.description}</p>
                      </div>
                    </li>
                  ))}
                </ul>
              </div>
              <div className="landing-feature-split__visual" aria-hidden="true">
                <div className="landing-app-mock landing-app-mock--tilted">
                  <div className="landing-app-mock__chrome">
                    <div className="landing-app-mock__dots">
                      <span className="landing-app-mock__dot landing-app-mock__dot--red" />
                      <span className="landing-app-mock__dot landing-app-mock__dot--yellow" />
                      <span className="landing-app-mock__dot landing-app-mock__dot--green" />
                    </div>
                    <div className="landing-app-mock__url">galreview.app</div>
                  </div>
                  <div className="landing-app-mock__stage">
                    <img className="landing-app-mock__scene-img" src="/tupu.png" alt="知识图谱" />
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section id="characters" className="landing-characters">
          <div className="landing-characters__inner">
            <h2>三位性格迥异的校园伙伴</h2>
            <p className="landing-characters__intro">
              有人善于看穿迷雾，有人总能追到第一手线索，也有人相信一切异常都可以被测量和验证。<br />
              只有当你从研习册主动选择故事回响时，他们才会把同一份题库与知识关系带入互动剧情。
            </p>
            <div className="landing-characters__grid">
              {characters.map((char) => (
                <article key={char.name} className="landing-character-card">
                  <div
                    className="landing-character-card__portrait"
                    style={{ color: char.color, backgroundColor: `${char.color}0d` }}
                  >
                    <img
                      className={char.portraitClassName}
                      src={char.image}
                      alt={char.alt}
                      loading="lazy"
                      decoding="async"
                    />
                  </div>
                  <div className="landing-character-card__copy">
                    <h3>{char.name}</h3>
                    <p className="landing-character-card__role">{char.role}</p>
                    <p>{char.desc}</p>
                  </div>
                </article>
              ))}
            </div>
          </div>
        </section>

        <section id="workflow" className="landing-workflow">
          <div className="landing-workflow__inner">
            <h2>从一份资料，进入智能复习循环</h2>
            <p className="landing-workflow__intro">
              解析、确认、复习与反馈按顺序衔接；每一步都归于同一册研习，不拆散你的资料与进度。
            </p>
            <div className="landing-workflow__timeline">
              {steps.map((step) => (
                <div key={step.num} className="landing-workflow-step">
                  <div className="landing-workflow-step__marker">
                    <span className="landing-workflow-step__num">{step.num}</span>
                  </div>
                  <div className="landing-workflow-step__copy">
                    <h3>{step.title}</h3>
                    <p>{step.desc}</p>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </section>

        <section id="faq" className="landing-faq">
          <div className="landing-faq__inner">
            <h2>你可能想知道的</h2>
            <div className="landing-faq__list">
              {faqs.map((item) => (
                <details key={item.q} className="landing-faq-item">
                  <summary>{item.q}</summary>
                  <p>{item.a}</p>
                </details>
              ))}
            </div>
          </div>
        </section>

        <section className="landing-cta">
          <div className="landing-cta__inner">
            <h2>从第一份资料开始建立复习系统</h2>
            <p>让千知万理协助解析、出题和安排复习，同时保留你对资料与答案的最终确认。</p>
            <div className="landing-cta__actions">
              <Link className="button button--primary landing-glass-button" to="/register">开始复习</Link>
              <button className="button button--light landing-glass-button" onClick={() => window.scrollTo({ top: 0, behavior: 'smooth' })}>重新阅读</button>
            </div>
          </div>
        </section>
      </main>

      <footer className="landing-footer">
        <div className="landing-footer__inner">
          <div className="landing-footer__brand">
            <BrandMark compact />
            <div>
              <strong>千知万理</strong>
              <p>知识有图谱，复习有剧情。<br />让每一次复习都有依据。</p>
            </div>
          </div>
          <div className="landing-footer__columns">
            <div>
              <h4>产品</h4>
              <nav>
                <Link to="#features" onClick={(e) => { e.preventDefault(); scroll('#features') }}>核心特色</Link>
                <Link to="#characters" onClick={(e) => { e.preventDefault(); scroll('#characters') }}>故事回响</Link>
                <Link to="#workflow" onClick={(e) => { e.preventDefault(); scroll('#workflow') }}>使用流程</Link>
                <Link to="/register">注册</Link>
              </nav>
            </div>
            <div>
              <h4>说明</h4>
              <nav>
                <Link to="#faq" onClick={(e) => { e.preventDefault(); scroll('#faq') }}>常见问题</Link>
                <a href="/wiki/">使用说明</a>
                <Link to="/login">登录</Link>
              </nav>
            </div>
            <div>
              <h4>更多</h4>
              <nav>
                <a href="https://github.com" target="_blank" rel="noopener noreferrer">GitHub</a>
              </nav>
            </div>
          </div>
          <span className="landing-footer__copy">© 2026 千知万理</span>
        </div>
      </footer>
    </div>
  )
}
