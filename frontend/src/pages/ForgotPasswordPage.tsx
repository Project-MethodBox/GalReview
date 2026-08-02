import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router'
import ActionButton from '../components/ActionButton'
import AuthLayout, { AuthEntryHeading } from '../components/AuthLayout'
import FormField from '../components/FormField'
import { api } from '../lib/api'

export default function ForgotPasswordPage() {
  const navigate = useNavigate()
  const [email, setEmail] = useState('')
  const [resetToken, setResetToken] = useState('')
  const [newPassword, setNewPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [sending, setSending] = useState(false)
  const [message, setMessage] = useState('')
  const [step, setStep] = useState<'request' | 'reset'>('request')

  async function sendCode() {
    if (!/^\S+@\S+\.\S+$/.test(email)) {
      setMessage('请先输入有效邮箱。')
      return
    }
    setSending(true)
    setMessage('')
    try {
      await api.requestPasswordReset(email)
      setStep('reset')
    } catch (error) {
      setMessage(error instanceof Error ? error.message : '验证码发送失败。')
    } finally {
      setSending(false)
    }
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!/^\d{6}$/.test(resetToken)) {
      setMessage('请输入 6 位数字验证码。')
      return
    }
    if (newPassword.length < 8) {
      setMessage('新密码至少需要 8 个字符。')
      return
    }
    setBusy(true)
    setMessage('')
    try {
      await api.resetPassword(resetToken, newPassword)
      navigate('/login', { state: { message: '密码已更新，请使用新密码登录。' } })
    } catch (error) {
      setMessage(error instanceof Error ? error.message : '密码修改失败。')
    } finally {
      setBusy(false)
    }
  }

  return (
    <AuthLayout page="forgot" storyCardVariant={step === 'reset' ? 'blue' : 'black'}>
      {step === 'request' ? (
        <form className="auth-form" onSubmit={(event) => { event.preventDefault(); void sendCode() }} noValidate>
          <AuthEntryHeading kicker="" title="找回你的账户" subtitle="输入登录邮箱，我们会向您的邮箱发送验证码。" />
          <FormField label="注册邮箱" type="email" autoComplete="email" value={email} onChange={(event) => setEmail(event.target.value)} onClear={() => setEmail('')} />
          <div className="auth-form__actions"><ActionButton type="submit" disabled={sending}><span>{sending ? '发送中' : '发送验证码'}</span><b aria-hidden="true">→</b></ActionButton></div>
          <button className="auth-form__back-link" type="button" onClick={() => navigate('/login')}>返回登录</button>
          {message ? <p className="form-message" role="status">{message}</p> : null}
        </form>
      ) : (
        <form className="auth-form" onSubmit={submit} noValidate>
          <AuthEntryHeading kicker="" title="重设密码" subtitle="输入收到的验证码，并设置新密码。" />
          <FormField label="验证码" inputMode="numeric" autoComplete="one-time-code" maxLength={6} value={resetToken} onChange={(event) => setResetToken(event.target.value.replace(/\D/g, ''))} />
          <FormField label="新密码" autoComplete="new-password" value={newPassword} onChange={(event) => setNewPassword(event.target.value)} passwordToggle />
          <div className="auth-form__actions"><ActionButton type="submit" disabled={busy}><span>{busy ? '重设中' : '确认重设密码'}</span><b aria-hidden="true">→</b></ActionButton></div>
          <button className="auth-form__back-link" type="button" onClick={() => navigate('/login')}>返回登录</button>
          {message ? <p className="form-message" role="status">{message}</p> : null}
        </form>
      )}
    </AuthLayout>
  )
}
