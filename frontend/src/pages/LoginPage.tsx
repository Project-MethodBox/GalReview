import { useState, type FormEvent } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'
import ActionButton from '../components/ActionButton'
import AuthLayout, { AuthHeading } from '../components/AuthLayout'
import FormField from '../components/FormField'
import { api, demoFallbackEnabled, isNetworkError } from '../lib/api'
import { createDemoProfile, createDemoSession, saveProfile, saveSession } from '../lib/session'

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
    if (!email.trim()) nextErrors.email = '请输入用户名或邮箱'
    if (!password) nextErrors.password = '请输入密码'
    setErrors(nextErrors)
    if (Object.keys(nextErrors).length) return

    setBusy(true)
    setMessage('')
    try {
      const session = await api.login(email.trim(), password)
      saveSession(session)
      try {
        saveProfile(await api.getCurrentUser())
      } catch {
        saveProfile(createDemoProfile(email.split('@')[0], session.session.userId))
      }
      navigate('/home')
    } catch (error) {
      if (demoFallbackEnabled && isNetworkError(error)) {
        const session = createDemoSession(email.trim())
        saveSession(session)
        saveProfile(createDemoProfile(email.split('@')[0], session.session.userId))
        navigate('/home', { state: { message: 'Gateway 未启动，当前使用本地测试会话。' } })
      } else {
        setMessage(error instanceof Error ? error.message : '登录失败，请重试。')
      }
    } finally {
      setBusy(false)
    }
  }

  return (
    <AuthLayout page="login">
      <form className="auth-form" onSubmit={submit} noValidate>
        <AuthHeading title="登录" subtitle="没有账户？点击注册按钮，开启您的复习之旅！" />
        <FormField label="用户名" name="email" autoComplete="username" placeholder="在此处输入您的用户名" value={email} onChange={(event) => setEmail(event.target.value)} onClear={() => setEmail('')} error={errors.email} />
        <FormField label="密码" name="password" autoComplete="current-password" placeholder="在此处输入您的密码" value={password} onChange={(event) => setPassword(event.target.value)} error={errors.password} passwordToggle />
        <div className="auth-form__actions auth-form__actions--login">
          <ActionButton type="button" variant="secondary" onClick={() => navigate('/forgot-password')}>忘记密码</ActionButton>
          <ActionButton type="button" variant="secondary" onClick={() => navigate('/register')}>注册</ActionButton>
          <ActionButton type="submit" disabled={busy}>{busy ? '登录中' : '登录'}</ActionButton>
        </div>
        {message ? <p className="form-message" role="status">{message}</p> : null}
      </form>
    </AuthLayout>
  )
}
