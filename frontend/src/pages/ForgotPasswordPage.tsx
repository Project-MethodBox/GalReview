import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router'
import ActionButton from '../components/ActionButton'
import AuthLayout, { AuthHeading } from '../components/AuthLayout'
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

  async function sendCode() {
    if (!/^\S+@\S+\.\S+$/.test(email)) {
      setMessage('请先输入有效邮箱。')
      return
    }
    setSending(true)
    setMessage('')
    try {
      await api.requestPasswordReset(email)
      setMessage('验证码已发送，请在 10 分钟内完成修改。')
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
    <AuthLayout page="forgot">
      <form className="auth-form" onSubmit={submit} noValidate>
        <AuthHeading title="忘记密码" subtitle="始于微光，终成星河。" />
        <FormField label="邮箱" type="email" autoComplete="email" placeholder="在此处输入您的邮箱" value={email} onChange={(event) => setEmail(event.target.value)} />
        <FormField
          label="验证码"
          inputMode="numeric"
          autoComplete="one-time-code"
          maxLength={6}
          placeholder="在此处输入您邮箱中的验证码"
          value={resetToken}
          onChange={(event) => setResetToken(event.target.value.replace(/\D/g, ''))}
          trailing={<button className="inline-button" type="button" disabled={sending} onClick={sendCode}>{sending ? '发送中' : '发送'}</button>}
        />
        <FormField label="新密码" autoComplete="new-password" placeholder="在此处输入您的密码" value={newPassword} onChange={(event) => setNewPassword(event.target.value)} passwordToggle />
        <div className="auth-form__actions"><ActionButton type="submit" disabled={busy}>{busy ? '更改中' : '更改'}</ActionButton></div>
        <button className="auth-form__back-link" type="button" onClick={() => navigate('/login')}>返回登录</button>
        {message ? <p className="form-message" role="status">{message}</p> : null}
      </form>
    </AuthLayout>
  )
}
