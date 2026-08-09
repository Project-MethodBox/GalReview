import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router'
import ActionButton from '../components/ActionButton'
import AuthLayout, { AuthEntryHeading } from '../components/AuthLayout'
import FormField from '../components/FormField'
import { api } from '../lib/api'
import { clearSession, saveProfile, saveSession } from '../lib/session'
import { resetWorkflow } from '../lib/workflow'

export default function RegisterPage() {
  const navigate = useNavigate()
  const [form, setForm] = useState({ displayName: '', email: '', password: '' })
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
        <AuthEntryHeading kicker="创建学习账户" title="开始使用 千知万理" subtitle="注册后直接进入你的复习主页。" />
        <FormField label="你的名字" autoComplete="nickname" value={form.displayName} onChange={(event) => update('displayName', event.target.value)} onClear={() => update('displayName', '')} error={errors.displayName} />
        <FormField label="邮箱" type="email" autoComplete="email" value={form.email} onChange={(event) => update('email', event.target.value)} onClear={() => update('email', '')} error={errors.email} />
        <FormField label="密码" autoComplete="new-password" value={form.password} onChange={(event) => update('password', event.target.value)} error={errors.password} passwordToggle />
        <p className="auth-entry-field-help">至少 8 个字符</p>
        <div className="auth-form__actions"><ActionButton type="submit" disabled={busy}><span>{busy ? '创建中' : '创建账户并进入'}</span><b aria-hidden="true">→</b></ActionButton></div>
        <p className="auth-entry-switch">已经有账户？<button type="button" onClick={() => navigate('/login')}>直接登录</button></p>
        {message ? <p className="form-message form-message--error" role="status">{message}</p> : null}
      </form>
    </AuthLayout>
  )
}
