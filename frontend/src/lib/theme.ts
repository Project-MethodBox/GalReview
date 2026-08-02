const REDUCED_MOTION_KEY = 'galreview.reducedMotion'
const COLOR_THEME_KEY = 'galreview.colorTheme'

export type ColorTheme = 'light' | 'dark'

export function readColorTheme(): ColorTheme {
  try {
    return localStorage.getItem(COLOR_THEME_KEY) === 'dark' ? 'dark' : 'light'
  } catch {
    return 'light'
  }
}

export function applyColorTheme(value: ColorTheme): void {
  document.documentElement.dataset.theme = value
  document.documentElement.style.colorScheme = value
}

export function saveColorTheme(value: ColorTheme): void {
  try {
    localStorage.setItem(COLOR_THEME_KEY, value)
  } catch {
    // The selected theme still applies for this page when storage is unavailable.
  }
  applyColorTheme(value)
}

export function readReducedMotion(): boolean {
  try {
    return localStorage.getItem(REDUCED_MOTION_KEY) === 'true'
  } catch {
    return false
  }
}

export function saveReducedMotion(value: boolean): void {
  try {
    localStorage.setItem(REDUCED_MOTION_KEY, String(value))
  } catch {
    // The preference still applies for this page when storage is unavailable.
  }
  document.documentElement.dataset.reducedMotion = String(value)
}

