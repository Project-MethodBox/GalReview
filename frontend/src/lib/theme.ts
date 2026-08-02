const REDUCED_MOTION_KEY = 'galreview.reducedMotion'

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

