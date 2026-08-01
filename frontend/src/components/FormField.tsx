import { useId, useState, type InputHTMLAttributes, type ReactNode } from 'react'
import { ArrowIcon, EyeIcon } from './icons'

interface FormFieldProps extends Omit<InputHTMLAttributes<HTMLInputElement>, 'size'> {
  label: string
  error?: string
  trailing?: ReactNode
  passwordToggle?: boolean
}

export default function FormField({ label, error, trailing, passwordToggle, id, type, ...props }: FormFieldProps) {
  const generatedId = useId()
  const inputId = id || generatedId
  const [revealed, setRevealed] = useState(false)
  const inputType = passwordToggle ? (revealed ? 'text' : 'password') : type

  return (
    <div className={`form-field${error ? ' form-field--error' : ''}`}>
      <label htmlFor={inputId}>{label}</label>
      <div className="form-field__control">
        <input id={inputId} type={inputType} aria-invalid={Boolean(error)} aria-describedby={error ? `${inputId}-error` : undefined} {...props} />
        {passwordToggle ? (
          <button className="form-field__icon" type="button" aria-label={revealed ? '隐藏密码' : '显示密码'} onClick={() => setRevealed((value) => !value)}>
            <EyeIcon />
          </button>
        ) : trailing ? (
          trailing
        ) : (
          <ArrowIcon className="form-field__decorative" />
        )}
      </div>
      {error ? <span className="form-field__error" id={`${inputId}-error`}>{error}</span> : null}
    </div>
  )
}
