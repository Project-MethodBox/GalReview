import type { ButtonHTMLAttributes, ReactNode } from 'react'

interface ActionButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  children: ReactNode
  variant?: 'primary' | 'secondary'
}

export default function ActionButton({ children, variant = 'primary', className = '', ...props }: ActionButtonProps) {
  return (
    <button className={`action-button action-button--${variant} ${className}`.trim()} {...props}>
      {children}
    </button>
  )
}
