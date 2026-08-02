import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router'
import ActionButton from '../components/ActionButton'
import AuthLayout, { AuthHeading } from '../components/AuthLayout'
import FormField from '../components/FormField'
import { api } from '../lib/api'
import { clearAdminSession, saveAdminSession } from '../lib/adminSession'

export default function AdminLoginPage() {
  const navigate = useNavigate()
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!username.trim() || !password) {
      setMessage('请输入管理员账号和密码。')
      return
    }
    setBusy(true)
    setMessage('')
    try {
      const session = await api.adminLogin(username.trim(), password)
      clearAdminSession()
      saveAdminSession(session)
      navigate('/admin', { replace: true })
    } catch (reason) {
      setMessage(reason instanceof Error ? reason.message : '管理员登录失败。')
    } finally {
      setBusy(false)
    }
  }

  return (
    <AuthLayout page="admin">
      <form className="auth-form" onSubmit={submit}>
        <AuthHeading title="管理后台" subtitle="管理用户账户和注册邀请码。" />
        <FormField label="管理员账号" name="admin-username" autoComplete="username" placeholder="输入管理员账号" value={username} onChange={(event) => setUsername(event.target.value)} onClear={() => setUsername('')} />
        <FormField label="管理员密码" name="admin-password" autoComplete="current-password" placeholder="输入管理员密码" value={password} onChange={(event) => setPassword(event.target.value)} passwordToggle />
        <div className="auth-form__actions"><ActionButton type="submit" disabled={busy}>{busy ? '验证中' : '进入后台'}</ActionButton></div>
        <button className="auth-form__back-link" type="button" onClick={() => navigate('/login')}>返回用户登录</button>
        {message ? <p className="form-message" role="status">{message}</p> : null}
      </form>
    </AuthLayout>
  )
}
