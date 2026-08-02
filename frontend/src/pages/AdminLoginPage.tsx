import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router'
import ActionButton from '../components/ActionButton'
import AuthLayout, { AuthEntryHeading } from '../components/AuthLayout'
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
    <AuthLayout page="admin" storyCardVariant="blue">
      <form className="auth-form" onSubmit={submit}>
        <AuthEntryHeading kicker="受限访问" title="管理员登录" subtitle="使用管理员账号进入后台。" />
        <FormField label="管理员账号" name="admin-username" autoComplete="username" value={username} onChange={(event) => setUsername(event.target.value)} onClear={() => setUsername('')} />
        <FormField label="密码" name="admin-password" autoComplete="current-password" value={password} onChange={(event) => setPassword(event.target.value)} passwordToggle />
        <div className="auth-form__actions"><ActionButton type="submit" disabled={busy}><span>{busy ? '验证中' : '进入管理后台'}</span><b aria-hidden="true">→</b></ActionButton></div>
        <button className="auth-form__back-link" type="button" onClick={() => navigate('/login')}>返回用户登录</button>
        {message ? <p className="form-message" role="status">{message}</p> : null}
      </form>
    </AuthLayout>
  )
}
