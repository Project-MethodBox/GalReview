import { useState, type FormEvent } from 'react'
import { useLocation, useNavigate } from 'react-router'
import ActionButton from '../components/ActionButton'
import AuthLayout, { AuthEntryHeading } from '../components/AuthLayout'
import FormField from '../components/FormField'
import { api } from '../lib/api'
import { clearSession, saveProfile, saveSession } from '../lib/session'
import { resetWorkflow } from '../lib/workflow'

export default function LoginPage() {
  const navigate = useNavigate()
  const location = useLocation()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState<string>((location.state as { message?: string } | null)?.message || '')
  const [errors, setErrors] = useState<Record<string, string>>({})

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const nextErrors: Record<string, string> = {}
    if (!/^\S+@\S+\.\S+$/.test(email)) nextErrors.email = '请输入有效邮箱'
    if (!password) nextErrors.password = '请输入密码'
    setErrors(nextErrors)
    if (Object.keys(nextErrors).length) return

    setBusy(true)
    setMessage('')
    try {
      const session = await api.login(email.trim(), password)
      clearSession()
      resetWorkflow()
      saveSession(session)
      saveProfile(await api.getCurrentUser())
      navigate('/home')
    } catch (error) {
      setMessage(error instanceof Error ? error.message : '登录失败，请重试。')
    } finally {
      setBusy(false)
    }
  }

  return (
    <AuthLayout page="login">
      <form className="auth-form" onSubmit={submit} noValidate>
        <AuthEntryHeading kicker="欢迎回来" title="登录 千知万理" subtitle="继续你的互动复习。" />
        <FormField label="邮箱" name="email" type="email" autoComplete="username" value={email} onChange={(event) => setEmail(event.target.value)} onClear={() => setEmail('')} error={errors.email} />
        <FormField label="密码" name="password" autoComplete="current-password" value={password} onChange={(event) => setPassword(event.target.value)} error={errors.password} passwordToggle />
        <div className="auth-form__actions"><ActionButton type="submit" disabled={busy}><span>{busy ? '登录中' : '登录并继续'}</span><b aria-hidden="true">→</b></ActionButton></div>
        <div className="auth-secondary-actions"><button type="button" onClick={() => navigate('/forgot-password')}>忘记密码？</button></div>
        <p className="auth-entry-switch">还没有账户？<button type="button" onClick={() => navigate('/register')}>去注册</button></p>
        {message ? <p className="form-message" role="status">{message}</p> : null}
      </form>
    </AuthLayout>
  )
}
