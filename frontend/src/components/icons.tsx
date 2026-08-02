import type { SVGProps } from 'react'

type IconProps = SVGProps<SVGSVGElement>

export function EyeIcon(props: IconProps) {
  return <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" {...props}><path d="M2.75 12s3.2-5.25 9.25-5.25S21.25 12 21.25 12 18.05 17.25 12 17.25 2.75 12 2.75 12Z" stroke="currentColor" strokeWidth="1.7" strokeLinejoin="round"/><circle cx="12" cy="12" r="2.65" stroke="currentColor" strokeWidth="1.7"/></svg>
}

export function ArrowIcon(props: IconProps) {
  return <svg viewBox="0 0 24 24" aria-hidden="true" {...props}><path d="M20 15.5c-2.4-4.1-5.7-5.8-10.5-5.4V6L3 12.5 9.5 19v-4.3c3.8-.5 6.9-.2 10.5.8Z" fill="currentColor"/></svg>
}

export function FullscreenIcon(props: IconProps) {
  return <svg viewBox="0 0 24 24" aria-hidden="true" {...props}><path d="M4 9V4h5M15 4h5v5M20 15v5h-5M9 20H4v-5" fill="none" stroke="currentColor" strokeWidth="2.3" strokeLinecap="round"/></svg>
}

export function BookIcon(props: IconProps) {
  return <svg viewBox="0 0 24 24" aria-hidden="true" {...props}><path d="M5 4h8a3 3 0 0 1 3 3v13H8a3 3 0 0 1-3-3V4Z" fill="none" stroke="currentColor" strokeWidth="2"/><path d="M16 7h3v13h-3" fill="none" stroke="currentColor" strokeWidth="2"/></svg>
}

export function ClockIcon(props: IconProps) {
  return <svg viewBox="0 0 24 24" aria-hidden="true" {...props}><circle cx="12" cy="12" r="8.7" fill="none" stroke="currentColor" strokeWidth="2"/><path d="M12 7v5l-3 2" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/></svg>
}

export function SettingsIcon(props: IconProps) {
  return <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" {...props}><path d="M9.4 3.4 8.8 5.6l-1.5.9-2.2-.6-1.7 3 1.6 1.6v1.8l-1.6 1.6 1.7 3 2.2-.6 1.5.9.6 2.2h3.4l.6-2.2 1.5-.9 2.2.6 1.7-3-1.6-1.6v-1.8l1.6-1.6-1.7-3-2.2.6-1.5-.9-.6-2.2H9.4Z" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round"/><circle cx="11.1" cy="11.4" r="2.5" stroke="currentColor" strokeWidth="1.6"/></svg>
}

export function BackIcon(props: IconProps) {
  return <svg viewBox="0 0 24 24" aria-hidden="true" {...props}><path d="m10 5-7 7 7 7M4 12h16" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"/></svg>
}
