import { useEffect, useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router'
import BrandMark from '../components/BrandMark'
import LoadingIndicator from '../components/LoadingIndicator'
import { api, ApiClientError } from '../lib/api'
import { clearAdminSession, readAdminSession } from '../lib/adminSession'
import type { AdminInvitation, AdminUser, InvitationType } from '../types/api'

const invitationNames: Record<InvitationType, string> = {
  'single-use': '单次使用',
  'multi-use': '多次使用',
  'time-window': '限时使用',
}

function invitationUsageText(invitation: AdminInvitation): string {
  if (invitation.type === 'time-window') return `不限次数 · 已使用 ${invitation.usedCount} 次`
  return `已用 ${invitation.usedCount}/${invitation.maxUses}`
}

export default function AdminPage() {
  const navigate = useNavigate()
  const [users, setUsers] = useState<AdminUser[]>([])
  const [invitations, setInvitations] = useState<AdminInvitation[]>([])
  const [type, setType] = useState<InvitationType>('single-use')
  const [maxUses, setMaxUses] = useState(10)
  const [validFrom, setValidFrom] = useState('')
  const [validTo, setValidTo] = useState('')
  const [busy, setBusy] = useState(false)
  const [initialLoading, setInitialLoading] = useState(true)
  const [message, setMessage] = useState('正在读取管理数据。')
  const [error, setError] = useState('')

  async function load() {
    setError('')
    const [nextUsers, nextInvitations] = await Promise.all([api.listAdminUsers(), api.listAdminInvitations()])
    setUsers(nextUsers)
    setInvitations(nextInvitations)
    setMessage(`已读取 ${nextUsers.length} 个用户和 ${nextInvitations.length} 个邀请码。`)
  }

  function reportError(reason: unknown, fallback: string) {
    if (reason instanceof ApiClientError && (reason.status === 401 || reason.status === 403)) {
      clearAdminSession()
      navigate('/admin/login', { replace: true })
      return
    }
    setError(reason instanceof Error ? reason.message : fallback)
  }

  async function refresh() {
    setBusy(true)
    try {
      await load()
    } catch (reason) {
      reportError(reason, '管理数据读取失败。')
    } finally {
      setBusy(false)
    }
  }

  useEffect(() => {
    setBusy(true)
    void load().catch((reason: unknown) => {
      reportError(reason, '管理数据读取失败。')
    }).finally(() => {
      setInitialLoading(false)
      setBusy(false)
    })
  }, [navigate])

  async function logout() {
    const session = readAdminSession()
    try {
      if (session) await api.adminLogout(session.session.sessionId)
    } finally {
      clearAdminSession()
      navigate('/admin/login', { replace: true })
    }
  }

  async function createInvitation(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (type === 'time-window' && (!validFrom || !validTo || validTo <= validFrom)) {
      setError('限时邀请码需要填写有效的开始和结束时间。')
      return
    }
    if (type === 'multi-use' && (maxUses < 1 || maxUses > 10000)) {
      setError('最大使用次数需要在 1 到 10000 之间。')
      return
    }
    setBusy(true)
    setError('')
    try {
      const invitation = await api.createAdminInvitation({
        type,
        maxUses: type === 'multi-use' ? maxUses : undefined,
        validFrom: type === 'time-window' ? new Date(validFrom).toISOString() : undefined,
        validTo: type === 'time-window' ? new Date(validTo).toISOString() : undefined,
      })
      setInvitations((current) => [invitation, ...current])
      setMessage(`邀请码 ${invitation.code} 已创建。`)
    } catch (reason) {
      reportError(reason, '邀请码创建失败。')
    } finally {
      setBusy(false)
    }
  }

  async function deleteInvitation(invitation: AdminInvitation) {
    if (!window.confirm(`删除邀请码 ${invitation.code}？`)) return
    setBusy(true)
    setError('')
    try {
      await api.deleteAdminInvitation(invitation.code)
      setInvitations((current) => current.filter((item) => item.code !== invitation.code))
      setMessage('邀请码已删除。')
    } catch (reason) {
      reportError(reason, '邀请码删除失败。')
    } finally {
      setBusy(false)
    }
  }

  async function resetPassword(user: AdminUser) {
    const nextPassword = window.prompt(`为 ${user.displayName} 设置新密码（至少 8 个字符）`)
    if (nextPassword === null) return
    if (nextPassword.length < 8) {
      setError('新密码至少需要 8 个字符。')
      return
    }
    setBusy(true)
    setError('')
    try {
      await api.resetAdminUserPassword(user.id, nextPassword)
      setMessage(`${user.displayName} 的密码已重置，原有会话已失效。`)
    } catch (reason) {
      reportError(reason, '密码重置失败。')
    } finally {
      setBusy(false)
    }
  }

  async function deleteUser(user: AdminUser) {
    if (!window.confirm(`永久删除用户“${user.displayName}”（${user.email}）？`)) return
    setBusy(true)
    setError('')
    try {
      await api.deleteAdminUser(user.id)
      setUsers((current) => current.filter((item) => item.id !== user.id))
      setMessage('用户已删除。')
    } catch (reason) {
      reportError(reason, '用户删除失败。')
    } finally {
      setBusy(false)
    }
  }

  const activeUserCount = users.filter((user) => user.isActive).length
  const now = Date.now()
  const availableInvitationCount = invitations.filter((invitation) => {
    if (invitation.type !== 'time-window') return invitation.usedCount < invitation.maxUses
    const validFrom = invitation.validFrom ? new Date(invitation.validFrom).getTime() : Number.NaN
    const validTo = invitation.validTo ? new Date(invitation.validTo).getTime() : Number.NaN
    return validFrom <= now && now <= validTo
  }).length
  const unlimitedInvitationCount = invitations.filter((invitation) => invitation.type === 'time-window').length

  return (
    <main className="admin-page">
      <header className="admin-header">
        <div className="admin-brand">
          <span className="admin-brand__mark"><BrandMark compact /></span>
          <span><strong>千知万理</strong><small>管理控制台</small></span>
        </div>
        <div className="admin-header__actions">
          <button className="button admin-refresh" type="button" disabled={busy} onClick={() => void refresh()}>
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 11a8 8 0 1 0-2.34 5.66M20 5v6h-6" /></svg>
            刷新数据
          </button>
          <button className="button admin-logout" type="button" onClick={() => void logout()}>安全退出</button>
        </div>
      </header>
      <div className="admin-content">
        <section className="admin-hero">
          <div className="admin-hero__copy">
            <span className="admin-eyebrow">ADMIN CONSOLE</span>
            <h1>系统管理</h1>
            <p>集中管理用户账户、访问凭证与注册邀请权限。</p>
          </div>
          <div className="admin-stats" aria-label="管理数据概览">
            <article>
              <span className="admin-stat__icon admin-stat__icon--users" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8ZM22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75" /></svg></span>
              <span><small>有效用户</small><strong>{activeUserCount}</strong><em>共 {users.length} 个账户</em></span>
            </article>
            <article>
              <span className="admin-stat__icon admin-stat__icon--invites" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M20 12v7a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-7M2 7h20v5H2zM12 21V7M12 7H7.5A2.5 2.5 0 1 1 12 4.5V7Zm0 0h4.5A2.5 2.5 0 1 0 12 4.5V7Z" /></svg></span>
              <span><small>当前可用邀请码</small><strong>{availableInvitationCount}</strong><em>{unlimitedInvitationCount} 个限时无限次</em></span>
            </article>
          </div>
        </section>
        {initialLoading ? <LoadingIndicator label="正在读取管理数据…" /> : <section className="admin-grid">
          <article className="workspace-card admin-users">
            <header className="admin-card__header"><div><span className="admin-card__icon" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8ZM19 8v6M16 11h6" /></svg></span><span><h2>用户账户</h2><p>维护普通用户的登录与访问权限</p></span></div><span className="admin-count">{users.length}</span></header>
            <div className="admin-table">
              {users.map((user) => <div key={user.id}>
                <span className="admin-user"><b aria-hidden="true">{user.displayName.trim().slice(0, 1).toUpperCase() || 'U'}</b><span><strong>{user.displayName}</strong><small>{user.email}</small></span></span>
                <em className={`admin-status${user.isActive ? ' is-active' : ''}`}><i />{user.isActive ? '正常' : '停用'}</em>
                <span className="admin-row-actions"><button type="button" disabled={busy} onClick={() => void resetPassword(user)}>重置密码</button><button className="danger" type="button" disabled={busy} onClick={() => void deleteUser(user)}>删除</button></span>
              </div>)}
              {!users.length ? <p className="admin-empty"><span aria-hidden="true">•••</span>暂无普通用户</p> : null}
            </div>
          </article>
          <article className="workspace-card admin-invitations">
            <header className="admin-card__header"><div><span className="admin-card__icon" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M20 12v7a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-7M2 7h20v5H2zM12 21V7M12 7H7.5A2.5 2.5 0 1 1 12 4.5V7Zm0 0h4.5A2.5 2.5 0 1 0 12 4.5V7Z" /></svg></span><span><h2>注册邀请码</h2><p>创建并管理新用户注册凭证</p></span></div><span className="admin-count">{invitations.length}</span></header>
            <form className="admin-invitation-form" onSubmit={createInvitation}>
              <label><span>邀请类型</span><select value={type} onChange={(event) => setType(event.target.value as InvitationType)}>{Object.entries(invitationNames).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
              {type === 'multi-use' ? <label><span>最大使用次数</span><input type="number" min={1} max={10000} value={maxUses} onChange={(event) => setMaxUses(Number(event.target.value))} /></label> : null}
              {type === 'time-window' ? <><label><span>开始时间</span><input type="datetime-local" value={validFrom} onChange={(event) => setValidFrom(event.target.value)} /></label><label><span>结束时间</span><input type="datetime-local" value={validTo} onChange={(event) => setValidTo(event.target.value)} /></label></> : null}
              <button className="button button--primary" disabled={busy} type="submit"><span aria-hidden="true">＋</span>创建邀请码</button>
            </form>
            <div className="invitation-list">
              {invitations.map((invitation) => <div key={invitation.code}><span><strong>{invitation.code}</strong><small>{invitationNames[invitation.type]} · {invitationUsageText(invitation)}</small></span><button type="button" disabled={busy} onClick={() => void deleteInvitation(invitation)}>删除</button></div>)}
              {!invitations.length ? <p className="admin-empty"><span aria-hidden="true">•••</span>暂无邀请码</p> : null}
            </div>
          </article>
        </section>}
        <p className={error ? 'status-line status-line--error' : 'status-line'} role="status">{error || message}</p>
      </div>
    </main>
  )
}
