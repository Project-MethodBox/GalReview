import { useId, useRef, useState, type InputHTMLAttributes, type ReactNode } from 'react'
import { ArrowIcon, EyeIcon } from './icons'

interface FormFieldProps extends Omit<InputHTMLAttributes<HTMLInputElement>, 'size'> {
  label: string
  error?: string
  trailing?: ReactNode
  passwordToggle?: boolean
  onClear?: () => void
}

export default function FormField({ label, error, trailing, passwordToggle, onClear, id, type, ...props }: FormFieldProps) {
  const generatedId = useId()
  const inputId = id || generatedId
  const inputRef = useRef<HTMLInputElement>(null)
  const [revealed, setRevealed] = useState(false)
  const inputType = passwordToggle ? (revealed ? 'text' : 'password') : type

  function clearInput() {
    onClear?.()
    inputRef.current?.focus()
  }

  return (
    <div className={`form-field${error ? ' form-field--error' : ''}`}>
      <label htmlFor={inputId}>{label}</label>
      <div className="form-field__control">
        <input ref={inputRef} id={inputId} type={inputType} aria-invalid={Boolean(error)} aria-describedby={error ? `${inputId}-error` : undefined} {...props} />
        {passwordToggle ? (
          <button className="form-field__icon" type="button" aria-label={revealed ? '隐藏密码' : '显示密码'} onClick={() => setRevealed((value) => !value)}>
            <EyeIcon />
          </button>
        ) : trailing ? (
          trailing
        ) : onClear ? (
          <button className="form-field__icon" type="button" aria-label={`清除${label}`} disabled={!String(props.value ?? '').length} onClick={clearInput}>
            <ArrowIcon />
          </button>
        ) : (
          <ArrowIcon className="form-field__decorative" />
        )}
      </div>
      {error ? <span className="form-field__error" id={`${inputId}-error`}>{error}</span> : null}
    </div>
  )
}
