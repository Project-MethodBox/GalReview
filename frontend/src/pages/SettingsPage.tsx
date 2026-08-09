import { useEffect, useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router'
import AppShell, { PageHeader } from '../components/AppShell'
import { api } from '../lib/api'
import { clearSession, readProfile, saveProfile } from '../lib/session'
import { readReducedMotion, saveReducedMotion } from '../lib/theme'
import { resetWorkflow } from '../lib/workflow'
import type { ContentDifficulty, CreditBalance, UserPreferencesInput, UserProfile } from '../types/api'

const defaults: UserPreferencesInput = { dailyGoalMinutes: 30, contentDifficulty: 'STANDARD', reducedMotion: readReducedMotion() }

type SettingsSection = 'profile' | 'credits' | 'learning' | 'security' | 'danger'
type SupportedLocale = 'zh-CN' | 'en-US'

const settingsSections: { id: SettingsSection; label: string }[] = [
  { id: 'profile', label: '个人资料' },
  { id: 'credits', label: 'credits' },
  { id: 'learning', label: '学习偏好' },
  { id: 'security', label: '账户安全' },
  { id: 'danger', label: '账户注销' },
]

function parseSubjects(value: string) {
  return [...new Set(value.split(/[,，\s]+/).map((item) => item.trim().toUpperCase()).filter(Boolean))]
}

export default function SettingsPage() {
  const navigate = useNavigate()
  const stored = readProfile()
  const [profile, setProfile] = useState<UserProfile | null>(stored)
  const [displayName, setDisplayName] = useState(stored?.displayName || '')
  const [locale, setLocale] = useState<SupportedLocale>(stored?.locale === 'en-US' ? 'en-US' : 'zh-CN')
  const [subjectText, setSubjectText] = useState(stored?.preferredSubjectCodes.join(', ') || '')
  const [preferences, setPreferences] = useState<UserPreferencesInput>(defaults)
  const [creditBalance, setCreditBalance] = useState<CreditBalance | null>(null)
  const [redemptionCode, setRedemptionCode] = useState('')
  const [passwords, setPasswords] = useState({ current: '', next: '', confirm: '' })
  const [deletion, setDeletion] = useState({ password: '', confirmation: '' })
  const [activeSection, setActiveSection] = useState<SettingsSection>('profile')
  const [busy, setBusy] = useState<string | null>('load')
  const [message, setMessage] = useState('')
  const [error, setError] = useState('')

  useEffect(() => {
    let active = true
    void Promise.all([api.getCurrentUser(), api.getUserPreferences(), api.getCreditBalance()]).then(([nextProfile, nextPreferences, nextCredits]) => {
      if (!active) return
      saveProfile(nextProfile)
      saveReducedMotion(nextPreferences.reducedMotion)
      setProfile(nextProfile)
      setDisplayName(nextProfile.displayName)
      setLocale(nextProfile.locale === 'en-US' ? 'en-US' : 'zh-CN')
      setSubjectText(nextProfile.preferredSubjectCodes.join(', '))
      setPreferences(nextPreferences)
      setCreditBalance(nextCredits)
    }).catch((reason: unknown) => {
      if (active) setError(reason instanceof Error ? reason.message : '设置读取失败。')
    }).finally(() => { if (active) setBusy(null) })
    return () => { active = false }
  }, [])

  function start(section: string) { setBusy(section); setError(''); setMessage('') }

  async function redeemCredits(event: FormEvent) {
    event.preventDefault()
    if (!redemptionCode.trim()) return setError('请输入兑换码。')
    start('credits')
    try { const next = await api.redeemCredits(redemptionCode.trim()); setCreditBalance(next); setRedemptionCode(''); setMessage('credits 已兑换。') }
    catch (reason) { setError(reason instanceof Error ? reason.message : '兑换失败。') } finally { setBusy(null) }
  }

  function openPurchase() {
    if (window.confirm('将前往购买页面。购买后请返回此处输入兑换码，是否继续？')) window.location.assign('https://pay.ldxp.cn/shop/7CX09W5E')
  }

  async function submitProfile(event: FormEvent) {
    event.preventDefault()
    const subjects = parseSubjects(subjectText)
    if (!displayName.trim()) return setError('显示名称不能为空。')
    if (subjects.length > 10 || subjects.some((item) => !/^[A-Z][A-Z0-9_]{0,31}$/.test(item))) return setError('学科代码最多 10 项，只能使用大写字母、数字和下划线。')
    start('profile')
    try {
      const next = await api.updateCurrentUser({ displayName: displayName.trim(), locale, preferredSubjectCodes: subjects })
      saveProfile(next); setProfile(next); setLocale(next.locale === 'en-US' ? 'en-US' : 'zh-CN'); setSubjectText(next.preferredSubjectCodes.join(', ')); setMessage('个人资料已保存。')
    } catch (reason) { setError(reason instanceof Error ? reason.message : '个人资料保存失败。') } finally { setBusy(null) }
  }

  async function submitPreferences(event: FormEvent) {
    event.preventDefault()
    if (!Number.isInteger(preferences.dailyGoalMinutes) || preferences.dailyGoalMinutes < 5 || preferences.dailyGoalMinutes > 180) return setError('每日目标需要是 5 到 180 分钟之间的整数。')
    start('preferences')
    try {
      const next = await api.updateUserPreferences(preferences)
      setPreferences(next); saveReducedMotion(next.reducedMotion); setMessage('学习偏好已保存。')
    } catch (reason) { setError(reason instanceof Error ? reason.message : '学习偏好保存失败。') } finally { setBusy(null) }
  }

  async function submitPassword(event: FormEvent) {
    event.preventDefault()
    if (passwords.next.length < 8) return setError('新密码至少需要 8 个字符。')
    if (passwords.next !== passwords.confirm) return setError('两次输入的新密码不一致。')
    start('password')
    try {
      await api.changePassword(passwords.current, passwords.next)
      setPasswords({ current: '', next: '', confirm: '' }); setMessage('密码已修改。')
    } catch (reason) { setError(reason instanceof Error ? reason.message : '密码修改失败。') } finally { setBusy(null) }
  }

  async function deleteAccount(event: FormEvent) {
    event.preventDefault()
    if (deletion.confirmation !== '永久注销') return setError('请输入“永久注销”确认操作。')
    start('delete')
    try {
      await api.deleteAccount(deletion.password)
      clearSession(); resetWorkflow(); navigate('/login', { replace: true, state: { message: '账户已永久注销。' } })
    } catch (reason) { setError(reason instanceof Error ? reason.message : '账户注销失败。'); setBusy(null) }
  }

  return (
    <AppShell>
      <main className="page settings-page">
        <PageHeader title="我的" />
        <div className="settings-layout">
          <aside className="settings-index" aria-label="设置分类">
            <h2>设置</h2>
            <nav role="tablist" aria-orientation="vertical">
              {settingsSections.map((section) => (
                <button
                  key={section.id}
                  className={activeSection === section.id ? 'active' : ''}
                  type="button"
                  role="tab"
                  aria-selected={activeSection === section.id}
                  aria-controls={`${section.id}-settings`}
                  onClick={() => setActiveSection(section.id)}
                >
                  {section.label}
                </button>
              ))}
            </nav>
          </aside>
          <section className="settings-main" role="tabpanel" aria-live="polite">
            {activeSection === 'profile' ? (
            <form className="form-section" id="profile-settings" onSubmit={submitProfile}>
              <header><h2>个人资料</h2></header>
              <label>显示名称<input maxLength={64} required value={displayName} onChange={(event) => setDisplayName(event.target.value)} /></label>
              <label className="settings-language">界面语言<select value={locale} onChange={(event) => setLocale(event.target.value as SupportedLocale)}><option value="zh-CN">简体中文</option><option value="en-US">English</option></select></label>
              <label>偏好学科<input value={subjectText} onChange={(event) => setSubjectText(event.target.value)} placeholder="GENERAL, AGRONOMY" /><small>逗号或空格分隔，最多 10 项。</small></label>
              <button className="button button--primary" disabled={busy !== null} type="submit">{busy === 'profile' ? '正在保存' : '保存资料'}</button>
            </form>
            ) : null}

            {activeSection === 'learning' ? (
            <form className="form-section" id="learning-settings" onSubmit={submitPreferences}>
              <header><h2>学习偏好</h2></header>
              <label>每日目标（分钟）<input type="number" min={5} max={180} step={1} value={preferences.dailyGoalMinutes} onChange={(event) => setPreferences((current) => ({ ...current, dailyGoalMinutes: Number(event.target.value) }))} /></label>
              <label>内容难度<select value={preferences.contentDifficulty} onChange={(event) => setPreferences((current) => ({ ...current, contentDifficulty: event.target.value as ContentDifficulty }))}><option value="BASIC">基础</option><option value="STANDARD">标准</option><option value="ADVANCED">进阶</option></select></label>
              <label className="toggle-field"><span><strong>减少动态效果</strong><small>关闭页面位移和非必要过渡。</small></span><input type="checkbox" role="switch" aria-label="减少动态效果" checked={preferences.reducedMotion} onChange={(event) => setPreferences((current) => ({ ...current, reducedMotion: event.target.checked }))} /></label>
              <button className="button button--primary" disabled={busy !== null} type="submit">{busy === 'preferences' ? '正在保存' : '保存偏好'}</button>
            </form>
            ) : null}

            {activeSection === 'credits' ? (
            <form className="form-section" id="credits-settings" onSubmit={redeemCredits}>
              <header className="credits-settings__header">
                <div><h2>credits</h2><p>用于生成复习题库和故事内容，完成后按实际用量扣除。</p></div>
              </header>
              <div className="credit-balance">
                <span className="credit-balance__label">可用余额</span>
                <div className="credit-balance__value"><strong>{creditBalance?.available.toFixed(5) ?? '读取中'}</strong><span>credits</span></div>
                {creditBalance && creditBalance.held > 0 ? <small>{creditBalance.held.toFixed(5)} credits 正在生成任务中占用</small> : <small>当前没有任务占用余额</small>}
              </div>
              <section className="credits-redeem" aria-labelledby="credits-redeem-title">
                <div className="credits-redeem__copy"><h3 id="credits-redeem-title">兑换 credits</h3><p>输入兑换码后，额度会立即加入当前账户。</p></div>
                <div className="credits-redeem__controls">
                  <label><span>兑换码</span><input autoComplete="off" placeholder="输入兑换码" value={redemptionCode} onChange={(event) => setRedemptionCode(event.target.value.toUpperCase())} /></label>
                  <div className="credits-redeem__actions"><button className="button button--primary" disabled={busy !== null || !redemptionCode.trim()} type="submit">立即兑换</button><button className="button button--quiet" type="button" onClick={openPurchase}>购买 credits</button></div>
                </div>
              </section>
            </form>
            ) : null}

            {activeSection === 'security' ? (
            <form className="form-section" id="security-settings" onSubmit={submitPassword}>
              <header><h2>修改密码</h2><p>输入当前密码后设置至少 8 个字符的新密码。</p></header>
              <label>当前密码<input type="password" autoComplete="current-password" value={passwords.current} onChange={(event) => setPasswords((current) => ({ ...current, current: event.target.value }))} /></label>
              <label>新密码<input type="password" autoComplete="new-password" minLength={8} value={passwords.next} onChange={(event) => setPasswords((current) => ({ ...current, next: event.target.value }))} /></label>
              <label>确认新密码<input type="password" autoComplete="new-password" minLength={8} value={passwords.confirm} onChange={(event) => setPasswords((current) => ({ ...current, confirm: event.target.value }))} /></label>
              <button className="button button--primary" disabled={busy !== null} type="submit">{busy === 'password' ? '正在修改' : '修改密码'}</button>
            </form>
            ) : null}

            {activeSection === 'danger' ? (
            <form className="side-section danger-section" id="danger-settings" onSubmit={deleteAccount}><h2>永久注销账户</h2><p>操作立即生效且不可恢复。</p><label>当前密码<input type="password" autoComplete="current-password" value={deletion.password} onChange={(event) => setDeletion((current) => ({ ...current, password: event.target.value }))} /></label><label>输入“永久注销”<input value={deletion.confirmation} onChange={(event) => setDeletion((current) => ({ ...current, confirmation: event.target.value }))} /></label><button className="button button--danger" disabled={busy !== null || deletion.confirmation !== '永久注销' || !deletion.password} type="submit">{busy === 'delete' ? '正在注销' : '永久注销账户'}</button></form>
            ) : null}
          </section>
        </div>
        {error || message ? <p className={error ? 'status-line status-line--error' : 'status-line'} role="status">{error || message}</p> : null}
      </main>
    </AppShell>
  )
}
