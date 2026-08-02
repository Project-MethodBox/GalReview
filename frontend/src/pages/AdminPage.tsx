import { useEffect, useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router'
import BrandMark from '../components/BrandMark'
import { api, ApiClientError } from '../lib/api'
import { clearAdminSession, readAdminSession } from '../lib/adminSession'
import type { AdminInvitation, AdminUser, InvitationType } from '../types/api'

const invitationNames: Record<InvitationType, string> = {
  'single-use': '单次使用',
  'multi-use': '多次使用',
  'time-window': '限时使用',
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
  const [message, setMessage] = useState('正在读取管理数据。')
  const [error, setError] = useState('')

  async function load() {
    setError('')
    const [nextUsers, nextInvitations] = await Promise.all([api.listAdminUsers(), api.listAdminInvitations()])
    setUsers(nextUsers)
    setInvitations(nextInvitations)
    setMessage(`已读取 ${nextUsers.length} 个用户和 ${nextInvitations.length} 个邀请码。`)
  }

  useEffect(() => {
    void load().catch((reason: unknown) => {
      if (reason instanceof ApiClientError && reason.status === 401) {
        clearAdminSession()
        navigate('/admin/login', { replace: true })
        return
      }
      setError(reason instanceof Error ? reason.message : '管理数据读取失败。')
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
    setBusy(true)
    setError('')
    try {
      const invitation = await api.createAdminInvitation({
        type,
        maxUses: type === 'single-use' ? 1 : maxUses,
        validFrom: type === 'time-window' ? new Date(validFrom).toISOString() : undefined,
        validTo: type === 'time-window' ? new Date(validTo).toISOString() : undefined,
      })
      setInvitations((current) => [invitation, ...current])
      setMessage(`邀请码 ${invitation.code} 已创建。`)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '邀请码创建失败。')
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
      setError(reason instanceof Error ? reason.message : '邀请码删除失败。')
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
      setError(reason instanceof Error ? reason.message : '密码重置失败。')
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
      setError(reason instanceof Error ? reason.message : '用户删除失败。')
    } finally {
      setBusy(false)
    }
  }

  return (
    <main className="admin-page">
      <header className="admin-header"><div><BrandMark compact /><span><strong>千知万理</strong><small>管理后台</small></span></div><div><button className="button" type="button" disabled={busy} onClick={() => void load()}>刷新</button><button className="button" type="button" onClick={() => void logout()}>退出</button></div></header>
      <div className="admin-content">
        <header className="page-header"><div><h1>系统管理</h1><p>管理用户账户和用于注册的邀请权限。</p></div></header>
        <section className="admin-grid">
          <article className="workspace-card admin-users"><header><h2>用户账户</h2><span>{users.length} 个</span></header><div className="admin-table">{users.map((user) => <div key={user.id}><span><strong>{user.displayName}</strong><small>{user.email}</small></span><em>{user.isActive ? '正常' : '停用'}</em><span className="admin-row-actions"><button type="button" disabled={busy} onClick={() => void resetPassword(user)}>重置密码</button><button className="danger" type="button" disabled={busy} onClick={() => void deleteUser(user)}>删除</button></span></div>)}{!users.length ? <p className="empty-row">暂无普通用户。</p> : null}</div></article>
          <article className="workspace-card admin-invitations"><header><h2>注册邀请码</h2><span>{invitations.length} 个</span></header><form className="admin-invitation-form" onSubmit={createInvitation}><label>类型<select value={type} onChange={(event) => setType(event.target.value as InvitationType)}>{Object.entries(invitationNames).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>{type !== 'single-use' ? <label>最大使用次数<input type="number" min={1} max={10000} value={maxUses} onChange={(event) => setMaxUses(Number(event.target.value))} /></label> : null}{type === 'time-window' ? <><label>开始时间<input type="datetime-local" value={validFrom} onChange={(event) => setValidFrom(event.target.value)} /></label><label>结束时间<input type="datetime-local" value={validTo} onChange={(event) => setValidTo(event.target.value)} /></label></> : null}<button className="button button--primary" disabled={busy} type="submit">创建邀请码</button></form><div className="invitation-list">{invitations.map((invitation) => <div key={invitation.code}><span><strong>{invitation.code}</strong><small>{invitationNames[invitation.type]} · 已用 {invitation.usedCount}/{invitation.maxUses}</small></span><button type="button" disabled={busy} onClick={() => void deleteInvitation(invitation)}>删除</button></div>)}{!invitations.length ? <p className="empty-row">暂无邀请码。</p> : null}</div></article>
        </section>
        <p className={error ? 'status-line status-line--error' : 'status-line'} role="status">{error || message}</p>
      </div>
    </main>
  )
}
