export default function BrandMark({ compact = false }: { compact?: boolean }) {
  return (
    <img
      className={`brand-mark${compact ? ' brand-mark--compact' : ''}`}
      src="/brand-logo.svg"
      alt=""
      aria-hidden="true"
    />
  )
}
