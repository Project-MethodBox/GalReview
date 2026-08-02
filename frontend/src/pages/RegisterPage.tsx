import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router'
import ActionButton from '../components/ActionButton'
import AuthLayout, { AuthHeading } from '../components/AuthLayout'
import FormField from '../components/FormField'
import { api } from '../lib/api'
import { clearSession, saveProfile, saveSession } from '../lib/session'
import { resetWorkflow } from '../lib/workflow'

export default function RegisterPage() {
  const navigate = useNavigate()
  const [form, setForm] = useState({ displayName: '', email: '', password: '', invitationCode: '' })
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const [errors, setErrors] = useState<Record<string, string>>({})

  function update(name: keyof typeof form, value: string) {
    setForm((current) => ({ ...current, [name]: value }))
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const nextErrors: Record<string, string> = {}
    if (!form.displayName.trim()) nextErrors.displayName = '请输入用户名'
    if (!/^\S+@\S+\.\S+$/.test(form.email)) nextErrors.email = '请输入有效邮箱'
    if (form.password.length < 8) nextErrors.password = '密码至少需要 8 个字符'
    if (!form.invitationCode.trim()) nextErrors.invitationCode = '请输入邀请码'
    setErrors(nextErrors)
    if (Object.keys(nextErrors).length) return

    setBusy(true)
    setMessage('')
    try {
      const session = await api.register(form)
      clearSession()
      resetWorkflow()
      saveSession(session)
      saveProfile(await api.getCurrentUser())
      navigate('/home')
    } catch (error) {
      setMessage(error instanceof Error ? error.message : '注册失败，请重试。')
    } finally {
      setBusy(false)
    }
  }

  return (
    <AuthLayout page="register">
      <form className="auth-form" onSubmit={submit} noValidate>
        <AuthHeading title="注册" subtitle="邀请码由管理员提供。" />
        <FormField label="用户名" autoComplete="nickname" placeholder="在此处输入您的用户名" value={form.displayName} onChange={(event) => update('displayName', event.target.value)} onClear={() => update('displayName', '')} error={errors.displayName} />
        <FormField label="邮箱" type="email" autoComplete="email" placeholder="在此处输入您的邮箱" value={form.email} onChange={(event) => update('email', event.target.value)} onClear={() => update('email', '')} error={errors.email} />
        <FormField label="密码" autoComplete="new-password" placeholder="在此处输入您的密码" value={form.password} onChange={(event) => update('password', event.target.value)} error={errors.password} passwordToggle />
        <FormField
          label="注册邀请码"
          autoComplete="off"
          placeholder="请输入管理员提供的邀请码"
          value={form.invitationCode}
          onChange={(event) => update('invitationCode', event.target.value)}
          error={errors.invitationCode}
        />
        <div className="auth-form__actions"><ActionButton type="submit" disabled={busy}>{busy ? '创建中' : '创建'}</ActionButton></div>
        <button className="auth-form__back-link" type="button" onClick={() => navigate('/login')}>已有账户，返回登录</button>
        {message ? <p className="form-message" role="status">{message}</p> : null}
      </form>
    </AuthLayout>
  )
}
