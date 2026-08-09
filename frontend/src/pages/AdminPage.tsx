import { useEffect, useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router'
import BrandMark from '../components/BrandMark'
import LoadingIndicator from '../components/LoadingIndicator'
import { LogoutIcon } from '../components/icons'
import { api, ApiClientError } from '../lib/api'
import { clearAdminSession, readAdminSession } from '../lib/adminSession'
import type { AdminCreditCode, AdminUser } from '../types/api'

const statusNames: Record<AdminCreditCode['status'], string> = { ACTIVE: '可兑换', REDEEMED: '已兑换', REVOKED: '已撤销', EXPIRED: '已过期' }
const creditFormatter = new Intl.NumberFormat('zh-CN', { maximumFractionDigits: 5 })
const formatCredits = (value: unknown) => typeof value === 'number' && Number.isFinite(value) ? creditFormatter.format(value) : '—'

export default function AdminPage() {
  const navigate = useNavigate()
  const [users, setUsers] = useState<AdminUser[]>([])
  const [codes, setCodes] = useState<AdminCreditCode[]>([])
  const [count, setCount] = useState('10')
  const [creditsPerCode, setCreditsPerCode] = useState('1')
  const [expiresAt, setExpiresAt] = useState('')
  const [generatedCodes, setGeneratedCodes] = useState('')
  const [userPendingPasswordReset, setUserPendingPasswordReset] = useState<AdminUser | null>(null)
  const [newUserPassword, setNewUserPassword] = useState('')
  const [userPendingDeletion, setUserPendingDeletion] = useState<AdminUser | null>(null)
  const [busy, setBusy] = useState(false)
  const [initialLoading, setInitialLoading] = useState(true)
  const [message, setMessage] = useState('正在读取管理数据。')
  const [error, setError] = useState('')

  function reportError(reason: unknown, fallback: string) {
    if (reason instanceof ApiClientError && (reason.status === 401 || reason.status === 403)) { clearAdminSession(); navigate('/admin/login', { replace: true }); return }
    setError(reason instanceof Error ? reason.message : fallback)
  }
  async function load() {
    setError('')
    const [nextUsers, codePage] = await Promise.all([api.listAdminUsers(), api.listAdminCreditCodes()])
    setUsers(nextUsers); setCodes(codePage.items); setMessage(`已读取 ${nextUsers.length} 个用户和 ${codePage.items.length} 个兑换码。`)
  }
  useEffect(() => { setBusy(true); void load().catch((reason: unknown) => reportError(reason, '管理数据读取失败。')).finally(() => { setInitialLoading(false); setBusy(false) }) }, [navigate])
  async function refresh() { setBusy(true); try { await load() } catch (reason) { reportError(reason, '管理数据读取失败。') } finally { setBusy(false) } }
  async function logout() { const session = readAdminSession(); try { if (session) await api.adminLogout(session.session.sessionId) } finally { clearAdminSession(); navigate('/admin/login', { replace: true }) } }
  async function createBatch(event: FormEvent) {
    event.preventDefault()
    const parsedCount = Number(count)
    const parsedCreditsPerCode = Number(creditsPerCode)
    if (!count.trim() || !Number.isInteger(parsedCount) || parsedCount < 1 || parsedCount > 1000) return setError('批量数量必须在 1 到 1000 之间。')
    if (!creditsPerCode.trim() || !Number.isFinite(parsedCreditsPerCode) || parsedCreditsPerCode <= 0 || parsedCreditsPerCode > 10000) return setError('每个兑换码的 credits 必须大于 0。')
    setBusy(true); setError(''); setGeneratedCodes('')
    try {
      const result = await api.createAdminCreditCodeBatch({ count: parsedCount, creditsPerCode: parsedCreditsPerCode, expiresAt: expiresAt ? new Date(expiresAt).toISOString() : undefined })
      setGeneratedCodes(result.items.map((item) => item.code).join('\n'))
      setCodes((current) => [...result.items, ...current])
      setMessage(`已批量生成 ${result.items.length} 个兑换码。完整兑换码仅在本次生成结果中显示，请立即保存。`)
    } catch (reason) { reportError(reason, '兑换码生成失败。') } finally { setBusy(false) }
  }
  async function revoke(code: AdminCreditCode) {
    if (!window.confirm(`撤销兑换码 ${code.code}？撤销后不可兑换。`)) return
    setBusy(true); setError('')
    try { await api.revokeAdminCreditCode(code.codeId); setCodes((current) => current.map((item) => item.codeId === code.codeId ? { ...item, status: 'REVOKED' } : item)); setMessage('兑换码已撤销。') }
    catch (reason) { reportError(reason, '兑换码撤销失败。') } finally { setBusy(false) }
  }
  async function copyCodes(value: string, label: string) {
    setError('')
    try {
      await navigator.clipboard.writeText(value)
      setMessage(`${label}已复制。`)
    } catch {
      setError('复制失败，请手动选择兑换码复制。')
    }
  }
  function requestPasswordReset(user: AdminUser) {
    setError('')
    setNewUserPassword('')
    setUserPendingPasswordReset(user)
  }
  function closePasswordReset() {
    if (busy) return
    setError('')
    setNewUserPassword('')
    setUserPendingPasswordReset(null)
  }
  async function resetPassword(event: FormEvent, user: AdminUser) {
    event.preventDefault()
    setError('')
    if (newUserPassword.length < 8) return setError('新密码至少需要 8 个字符。')
    setBusy(true)
    try {
      await api.resetAdminUserPassword(user.id, newUserPassword)
      setMessage(`${user.displayName} 的密码已重置，该用户原有登录会话已失效。`)
      setNewUserPassword('')
      setUserPendingPasswordReset(null)
    } catch (reason) { reportError(reason, '密码重置失败。') } finally { setBusy(false) }
  }
  function requestUserDeletion(user: AdminUser) { setError(''); setUserPendingDeletion(user) }
  async function deleteUser(user: AdminUser) {
    setBusy(true); setError('')
    try {
      await api.deleteAdminUser(user.id)
      setUsers((current) => current.filter((item) => item.id !== user.id))
      setUserPendingDeletion(null)
      setMessage('用户已删除。')
    } catch (reason) { reportError(reason, '用户删除失败。') } finally { setBusy(false) }
  }

  return (
    <main className="admin-page">
      <header className="admin-header">
        <Link className="admin-brand" to="/" aria-label="千知万理首页">
          <BrandMark compact />
          <span><strong>千知万理</strong></span>
        </Link>
        <div className="admin-header__actions">
          <button className="button admin-refresh" type="button" disabled={busy} onClick={() => void refresh()}>
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M19 8a8 8 0 1 0 1 6M19 4v4h-4" /></svg>
            <span>刷新</span>
          </button>
          <button className="button admin-logout" type="button" onClick={() => void logout()}>
            <LogoutIcon />
            <span>退出</span>
          </button>
        </div>
      </header>

      <div className="admin-content">
        <section className="admin-hero">
          <div className="admin-hero__copy">
            <h1>系统管理</h1>
          </div>
        </section>

        {initialLoading ? <LoadingIndicator label="正在读取管理数据" /> : (
          <section className="admin-grid">
            <article className="workspace-card admin-users">
              <header className="admin-card__header">
                <div><span><h2>用户账户</h2></span></div>
              </header>
              <div className="admin-table">
                {users.length === 0 ? <p className="admin-empty">暂无用户账户</p> : users.map((user) => (
                  <div key={user.id}>
                    <span className="admin-user">
                      <b aria-hidden="true">{user.displayName.trim().slice(0, 1).toUpperCase() || 'U'}</b>
                      <span>
                        <strong>{user.displayName}</strong>
                        <small>{user.email}</small>
                        <small className="admin-user__credits">可用 credits · <b>{formatCredits(user.credits)}</b></small>
                      </span>
                    </span>
                    <em className={`admin-status${user.isActive ? ' is-active' : ''}`}><i />{user.isActive ? '正常' : '停用'}</em>
                    <span className="admin-row-actions">
                      <button type="button" disabled={busy} onClick={() => requestPasswordReset(user)}>重置密码</button>
                      <button className="danger" type="button" disabled={busy} onClick={() => requestUserDeletion(user)}>删除</button>
                    </span>
                  </div>
                ))}
              </div>
            </article>

            <article className="workspace-card admin-invitations">
              <header className="admin-card__header">
                <div><span><h2>credits 兑换码</h2></span></div>
              </header>
              <form className="admin-invitation-form" onSubmit={createBatch}>
                <label><span>生成数量</span><input type="number" min={1} max={1000} value={count} onChange={(event) => setCount(event.target.value)} /></label>
                <label><span>每码 credits</span><input type="number" min="0.00001" max="10000" step="0.00001" value={creditsPerCode} onChange={(event) => setCreditsPerCode(event.target.value)} /></label>
                <label><span>过期时间（可选）</span><input type="datetime-local" value={expiresAt} onChange={(event) => setExpiresAt(event.target.value)} /></label>
                <button className="button button--primary" disabled={busy} type="submit">批量生成</button>
              </form>
              {generatedCodes ? (
                <div className="admin-generated-codes">
                  <div className="admin-generated-codes__header">
                    <span>本次完整兑换码</span>
                    <button className="admin-copy-code" type="button" onClick={() => void copyCodes(generatedCodes, '本批兑换码')}>复制全部</button>
                  </div>
                  <textarea aria-label="本次完整兑换码" readOnly rows={Math.min(12, Number(count) || 1)} value={generatedCodes} />
                </div>
              ) : null}
              <div className="invitation-list">
                {codes.length === 0 ? <p className="admin-empty">暂无兑换码</p> : codes.map((code) => (
                  <div key={code.codeId}>
                    <span>
                      <span className="admin-code-line">
                        <strong>{code.code}</strong>
                        <button className="admin-copy-code" type="button" onClick={() => void copyCodes(code.code, '兑换码')}>复制</button>
                      </span>
                      <small>{code.credits} credits · {statusNames[code.status]}{code.expiresAt ? ` · ${new Date(code.expiresAt).toLocaleString()}` : ''}</small>
                    </span>
                    {code.status === 'ACTIVE' ? <button className="admin-revoke-code" type="button" disabled={busy} onClick={() => void revoke(code)}>撤销</button> : null}
                  </div>
                ))}
              </div>
            </article>
          </section>
        )}
        <p className={error ? 'status-line status-line--error' : 'status-line'} role="status">{error || message}</p>
      </div>
      {userPendingPasswordReset ? (
        <div className="admin-confirm-backdrop">
          <form className="admin-confirm admin-password-reset" role="dialog" aria-modal="true" aria-labelledby="admin-password-title" onSubmit={(event) => void resetPassword(event, userPendingPasswordReset)}>
            <span className="admin-confirm__eyebrow">重置密码</span>
            <h2 id="admin-password-title">为 {userPendingPasswordReset.displayName} 设置新密码</h2>
            <p>{userPendingPasswordReset.email}；提交后，该用户当前的登录会话会立即失效。</p>
            <label>
              <span>新密码</span>
              <input autoFocus type="password" autoComplete="new-password" minLength={8} value={newUserPassword} onChange={(event) => setNewUserPassword(event.target.value)} />
            </label>
            {error ? <p className="admin-confirm__error" role="status">{error}</p> : null}
            <div className="admin-confirm__actions">
              <button className="button button--primary" type="submit" disabled={busy}>{busy ? '正在重置' : '确认重置密码'}</button>
              <button className="button" type="button" disabled={busy} onClick={closePasswordReset}>取消</button>
            </div>
          </form>
        </div>
      ) : null}
      {userPendingDeletion ? (
        <div className="admin-confirm-backdrop">
          <section className="admin-confirm" role="alertdialog" aria-modal="true" aria-labelledby="admin-delete-title" aria-describedby="admin-delete-description">
            <span className="admin-confirm__eyebrow">删除用户</span>
            <h2 id="admin-delete-title">确认永久删除？</h2>
            <p id="admin-delete-description">将删除用户 <strong>{userPendingDeletion.displayName}</strong>（{userPendingDeletion.email}）的账户，此操作不可撤销。</p>
            {error ? <p className="admin-confirm__error" role="status">{error}</p> : null}
            <div className="admin-confirm__actions">
              <button className="button button--danger" type="button" disabled={busy} onClick={() => void deleteUser(userPendingDeletion)}>{busy ? '正在删除' : '确认删除'}</button>
              <button className="button" type="button" disabled={busy} onClick={() => setUserPendingDeletion(null)}>取消</button>
            </div>
          </section>
        </div>
      ) : null}
    </main>
  )
}
