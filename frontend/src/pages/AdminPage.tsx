import { useEffect, useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router'
import BrandMark from '../components/BrandMark'
import LoadingIndicator from '../components/LoadingIndicator'
import { api, ApiClientError } from '../lib/api'
import { clearAdminSession, readAdminSession } from '../lib/adminSession'
import type { AdminCreditCode, AdminUser } from '../types/api'

const statusNames: Record<AdminCreditCode['status'], string> = { ACTIVE: '可兑换', REDEEMED: '已兑换', REVOKED: '已撤销', EXPIRED: '已过期' }

export default function AdminPage() {
  const navigate = useNavigate()
  const [users, setUsers] = useState<AdminUser[]>([])
  const [codes, setCodes] = useState<AdminCreditCode[]>([])
  const [count, setCount] = useState(10)
  const [creditsPerCode, setCreditsPerCode] = useState(1)
  const [expiresAt, setExpiresAt] = useState('')
  const [generatedCodes, setGeneratedCodes] = useState('')
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
    if (!Number.isInteger(count) || count < 1 || count > 1000) return setError('批量数量必须在 1 到 1000 之间。')
    if (!Number.isFinite(creditsPerCode) || creditsPerCode <= 0 || creditsPerCode > 10000) return setError('每个兑换码的 credits 必须大于 0。')
    setBusy(true); setError(''); setGeneratedCodes('')
    try {
      const result = await api.createAdminCreditCodeBatch({ count, creditsPerCode, expiresAt: expiresAt ? new Date(expiresAt).toISOString() : undefined })
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
  async function resetPassword(user: AdminUser) { const value = window.prompt(`为 ${user.displayName} 设置新密码（至少 8 个字符）`); if (value === null) return; if (value.length < 8) return setError('新密码至少需要 8 个字符。'); setBusy(true); try { await api.resetAdminUserPassword(user.id, value); setMessage(`${user.displayName} 的密码已重置。`) } catch (reason) { reportError(reason, '密码重置失败。') } finally { setBusy(false) } }
  async function deleteUser(user: AdminUser) { if (!window.confirm(`永久删除用户“${user.displayName}”（${user.email}）？`)) return; setBusy(true); try { await api.deleteAdminUser(user.id); setUsers((current) => current.filter((item) => item.id !== user.id)); setMessage('用户已删除。') } catch (reason) { reportError(reason, '用户删除失败。') } finally { setBusy(false) } }

  const activeCodes = codes.filter((code) => code.status === 'ACTIVE').length
  return <main className="admin-page">
    <header className="admin-header"><div className="admin-brand"><span className="admin-brand__mark"><BrandMark compact /></span><span><strong>千知万理</strong><small>管理控制台</small></span></div><div className="admin-header__actions"><button className="button admin-refresh" type="button" disabled={busy} onClick={() => void refresh()}>刷新数据</button><button className="button admin-logout" type="button" onClick={() => void logout()}>安全退出</button></div></header>
    <div className="admin-content">
      <section className="admin-hero"><div className="admin-hero__copy"><span className="admin-eyebrow">ADMIN CONSOLE</span><h1>系统管理</h1><p>集中管理用户账户和 credits 兑换码。</p></div><div className="admin-stats" aria-label="管理数据概览"><article><span><small>有效用户</small><strong>{users.filter((user) => user.isActive).length}</strong><em>共 {users.length} 个账户</em></span></article><article><span><small>可用兑换码</small><strong>{activeCodes}</strong><em>共 {codes.length} 个兑换码</em></span></article></div></section>
      {initialLoading ? <LoadingIndicator label="正在读取管理数据" /> : <section className="admin-grid">
        <article className="workspace-card admin-users"><header className="admin-card__header"><div><span><h2>用户账户</h2><p>维护普通用户的登录与访问权限</p></span></div><span className="admin-count">{users.length}</span></header><div className="admin-table">{users.map((user) => <div key={user.id}><span className="admin-user"><b aria-hidden="true">{user.displayName.trim().slice(0, 1).toUpperCase() || 'U'}</b><span><strong>{user.displayName}</strong><small>{user.email}</small></span></span><em className={`admin-status${user.isActive ? ' is-active' : ''}`}><i />{user.isActive ? '正常' : '停用'}</em><span className="admin-row-actions"><button type="button" disabled={busy} onClick={() => void resetPassword(user)}>重置密码</button><button className="danger" type="button" disabled={busy} onClick={() => void deleteUser(user)}>删除</button></span></div>)}</div></article>
        <article className="workspace-card admin-invitations"><header className="admin-card__header"><div><span><h2>credits 兑换码</h2><p>批量生成、查看状态并撤销兑换码</p></span></div><span className="admin-count">{codes.length}</span></header>
          <form className="admin-invitation-form" onSubmit={createBatch}><label><span>生成数量</span><input type="number" min={1} max={1000} value={count} onChange={(event) => setCount(Number(event.target.value))} /></label><label><span>每码 credits</span><input type="number" min="0.00001" max="10000" step="0.00001" value={creditsPerCode} onChange={(event) => setCreditsPerCode(Number(event.target.value))} /></label><label><span>过期时间（可选）</span><input type="datetime-local" value={expiresAt} onChange={(event) => setExpiresAt(event.target.value)} /></label><button className="button button--primary" disabled={busy} type="submit">批量生成</button></form>
          {generatedCodes ? <label className="admin-generated-codes"><span>本次完整兑换码</span><textarea readOnly rows={Math.min(12, count)} value={generatedCodes} /></label> : null}
          <div className="invitation-list">{codes.map((code) => <div key={code.codeId}><span><strong>{code.code}</strong><small>{code.credits} credits · {statusNames[code.status]}{code.expiresAt ? ` · ${new Date(code.expiresAt).toLocaleString()}` : ''}</small></span>{code.status === 'ACTIVE' ? <button type="button" disabled={busy} onClick={() => void revoke(code)}>撤销</button> : null}</div>)}</div>
        </article>
      </section>}
      <p className={error ? 'status-line status-line--error' : 'status-line'} role="status">{error || message}</p>
    </div>
  </main>
}
