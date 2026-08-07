import { useEffect, useRef, useState, type CSSProperties } from 'react'
import { Link, useNavigate } from 'react-router'
import BrandMark from '../components/BrandMark'
import { GraphIcon, KnowledgeIcon, MaterialsIcon, ReviewIcon } from '../components/icons'
import { readSession } from '../lib/session'

const features = [
  {
    title: '让资料真正成为主角',
    description: '从自己的课程内容出发，每一次复习都与眼前的学习目标有关。上传讲义、笔记或题库，系统自动梳理其中的章节与知识点。',
    icon: MaterialsIcon,
  },
  {
    title: '让知识彼此连接',
    description: '从章节到概念，逐步看清知识之间的来龙去脉。知识图谱帮你建立联系，不再孤立地记忆单个知识点。',
    icon: KnowledgeIcon,
  },
  {
    title: '让复习拥有故事感',
    description: '通过对白、选择与挑战推进剧情，让再看一遍变成继续下一幕。三位校园伙伴会以各自的方式参与其中。',
    icon: ReviewIcon,
  },
  {
    title: '让进步有迹可循',
    description: '保留每次作答与复习进度，方便回顾掌握情况并规划下一次学习。每一次复习都在为下一次积累线索。',
    icon: GraphIcon,
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
  { num: '01', title: '带上自己的资料', desc: '上传课程讲义、课堂笔记或复习题，选择想要巩固的章节与知识点。系统会为你梳理出清晰的知识脉络。' },
  { num: '02', title: '梳理知识脉络', desc: '从章节到概念，逐步看清知识之间的来龙去脉。知识图谱会帮你建立联系，让复习不再孤立。' },
  { num: '03', title: '进入互动剧情', desc: '选择本次故事的氛围和挑战强度，三位角色会以各自的方式参与其中。一次对话、一道问题、一个选择，都可能成为继续故事的线索。' },
  { num: '04', title: '留下复习记录', desc: '每一轮结束后，复习记录会成为下一次出发的依据。故事可以告一段落，学习仍会接着向前。' },
]

const faqs = [
  {
    q: '千知万理适合什么学科？',
    a: '千知万理支持上传任意学科的讲义、笔记或题库。系统会自动梳理其中的章节与知识点，生成知识图谱。目前更适合有明确章节结构的学习资料。',
  },
  {
    q: '复习剧情是怎么生成的？',
    a: '基于你上传的知识点，系统会生成一段校园风格的互动剧情。三位角色会以各自的方式参与其中，通过对白、选择与问题推进故事。',
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

const heroCards = [
  { id: 'story', line1: '知识有图谱，', line2Prefix: '', line2Accent: '复习有剧情', line2Suffix: '。' },
  { id: 'mastery', line1: '千知万理，', line2Prefix: '让你', line2Accent: '真正学会', line2Suffix: '' },
] as const

const heroMessages = [
  { text: '让每个知识点相连', accentFrom: 3, tone: 'blue' },
  { text: '让每份笔记变线索', accentFrom: 5, tone: 'violet' },
  { text: '让复习走进剧情里', accentFrom: 3, tone: 'rose' },
  { text: '知识有图谱，\n复习有剧情。', accentFrom: 7, tone: 'story' },
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
  const [heroCarousel, setHeroCarousel] = useState<{ activeIndex: number; outgoingIndex: number | null }>({
    activeIndex: 0,
    outgoingIndex: null,
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
      delay = 720
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
    if (!typewriterState.finished) return

    const timer = window.setInterval(() => {
      setHeroCarousel((current) => ({
        activeIndex: (current.activeIndex + 1) % heroCards.length,
        outgoingIndex: current.activeIndex,
      }))
    }, 9000)

    return () => window.clearInterval(timer)
  }, [typewriterState.finished])

  useEffect(() => {
    if (heroCarousel.outgoingIndex === null) return

    const timer = window.setTimeout(() => {
      setHeroCarousel((current) => current.outgoingIndex === null
        ? current
        : { ...current, outgoingIndex: null })
    }, 760)

    return () => window.clearTimeout(timer)
  }, [heroCarousel.outgoingIndex])

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
  const activeHeroCard = heroCards[heroCarousel.activeIndex]
  const activeHeroLabel = `${activeHeroCard.line1}${activeHeroCard.line2Prefix}${activeHeroCard.line2Accent}${activeHeroCard.line2Suffix}`

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
            <Link to="#characters" onClick={(e) => { e.preventDefault(); scroll('#characters') }}>角色介绍</Link>
            <Link to="#workflow" onClick={(e) => { e.preventDefault(); scroll('#workflow') }}>使用流程</Link>
            <Link to="#faq" onClick={(e) => { e.preventDefault(); scroll('#faq') }}>常见问题</Link>
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
              aria-label={typewriterState.finished ? activeHeroLabel : finalHeroLabel}
            >
              {typewriterState.finished ? (
                <span className="landing-hero__card-stage" aria-hidden="true">
                  {heroCards.map((card, cardIndex) => {
                    const position = cardIndex === heroCarousel.activeIndex
                      ? 'active'
                      : cardIndex === heroCarousel.outgoingIndex ? 'previous' : 'next'

                    return (
                      <span
                        className={`landing-hero__title-card landing-hero__title-card--${position}`}
                        key={card.id}
                      >
                        <span className={`landing-hero__card-copy${card.id === 'mastery' ? ' landing-hero__typed--final' : ''}`}>
                          <span className="landing-hero__card-line">
                            {card.id === 'mastery' ? (
                              <><span className="landing-hero__typewriter-char--brand">千知万理</span>，</>
                            ) : card.line1}
                          </span>
                          <span className="landing-hero__card-line">
                            {card.line2Prefix}
                            {card.id === 'mastery' ? (
                              Array.from(card.line2Accent).map((character, characterIndex) => (
                                <span
                                  className="landing-hero__typewriter-char landing-hero__typewriter-char--accent"
                                  key={character}
                                  style={{ '--typewriter-char-index': characterIndex } as CSSProperties}
                                >
                                  {character}
                                </span>
                              ))
                            ) : (
                              <>
                                {Array.from(card.line2Accent).map((character, characterIndex) => (
                                  <span
                                    className={`landing-hero__story-char${characterIndex >= 3 ? ' landing-hero__story-char--shine' : ''}`}
                                    key={character}
                                    style={{
                                      '--story-char-index': characterIndex,
                                      '--story-shine-index': Math.max(0, characterIndex - 3),
                                    } as CSSProperties}
                                  >
                                    {character}
                                  </span>
                                ))}
                                <span className="landing-hero__story-punctuation">{card.line2Suffix}</span>
                              </>
                            )}
                          </span>
                        </span>
                      </span>
                    )
                  })}
                </span>
              ) : (
                <span
                  className={`landing-hero__typed landing-hero__typed--${activeHeroMessage.tone}`}
                  aria-hidden="true"
                >
                  {Array.from(visibleHeroText).map((character, characterIndex) => {
                    if (character === '\n') {
                      return <br className="landing-hero__typewriter-break" key={`break-${characterIndex}`} />
                    }

                    const characterClasses = ['landing-hero__typewriter-char']
                    if (characterIndex >= activeHeroMessage.accentFrom) {
                      characterClasses.push('landing-hero__typewriter-char--accent')
                    }

                    return (
                      <span
                        className={characterClasses.join(' ')}
                        key={`${typewriterState.messageIndex}-${characterIndex}`}
                      >
                        {character}
                      </span>
                    )
                  })}
                  <span className="landing-hero__typewriter-caret" />
                </span>
              )}
            </h1>
            <p className="landing-hero__subtitle">
              把熟悉的讲义与笔记，变成一场属于你的校园故事。
              上传资料、梳理知识、进入剧情，在每一次选择中完成更有记忆点的复习。
            </p>
            <div className="landing-hero__actions">
              <Link className="button button--primary landing-hero__cta landing-glass-button" to="/register">开始你的复习剧情 →</Link>
              <button className="button button--light landing-glass-button" onClick={() => scroll('#workflow')}>看看复习流程</button>
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
                <div className="landing-app-mock__stage">
                  <picture className="landing-app-mock__picture">
                    <source srcSet="/landing-game-scene.avif" type="image/avif" />
                    <source srcSet="/landing-game-scene.webp" type="image/webp" />
                    <img className="landing-app-mock__scene-img" src="/landing-game-scene.png" alt="游戏画面" />
                  </picture>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section id="features" className="landing-features">
          <div className="landing-features__inner">
            <div className="landing-feature-split">
              <div className="landing-feature-split__copy">
                <h2>把复习资料，<br />变成一场校园剧情。</h2>
                <p className="landing-features__intro">
                  不是面对一张张知识清单，而是和熟悉的角色一起调查、推理、回顾。
                  上传讲义、梳理图谱、进入剧情——在每一次选择中巩固知识点。
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
              他们会陪你走进知识背后的故事。
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
            <h2>从一份资料，走进一段剧情</h2>
            <p className="landing-workflow__intro">
              没有漫无边界的目录，也没有塞满按钮的面板。一次复习只有四件事，按顺序发生。
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
            <h2>准备好开始你的复习剧情了吗？</h2>
            <p>上传第一份资料，让千知万理帮你把复习变成一场值得期待的冒险。</p>
            <div className="landing-cta__actions">
              <Link className="button button--primary landing-glass-button" to="/register">注册，开始第一课 →</Link>
              <button className="button button--light landing-glass-button" onClick={() => window.scrollTo({ top: 0, behavior: 'smooth' })}>再看看复习流程</button>
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
              <p>把复习资料，变成一场校园故事。<br />让每一步都看得见。</p>
            </div>
          </div>
          <div className="landing-footer__columns">
            <div>
              <h4>产品</h4>
              <nav>
                <Link to="#features" onClick={(e) => { e.preventDefault(); scroll('#features') }}>核心特色</Link>
                <Link to="#characters" onClick={(e) => { e.preventDefault(); scroll('#characters') }}>角色介绍</Link>
                <Link to="#workflow" onClick={(e) => { e.preventDefault(); scroll('#workflow') }}>使用流程</Link>
                <Link to="/register">注册</Link>
              </nav>
            </div>
            <div>
              <h4>说明</h4>
              <nav>
                <Link to="#faq" onClick={(e) => { e.preventDefault(); scroll('#faq') }}>常见问题</Link>
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
