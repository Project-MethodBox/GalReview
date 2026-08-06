type LoadingIndicatorProps = {
  label: string
  compact?: boolean
  className?: string
}

export default function LoadingIndicator({ label, compact = false, className = '' }: LoadingIndicatorProps) {
  const classes = ['loading-indicator', compact ? 'loading-indicator--compact' : '', className]
    .filter(Boolean)
    .join(' ')

  return (
    <div className={classes} role="status" aria-live="polite">
      <span className="loading-indicator__buffer" aria-hidden="true">
        <i />
        <i />
        <i />
      </span>
      <span className="loading-indicator__label">{label}</span>
    </div>
  )
}
