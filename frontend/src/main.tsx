import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import { applyColorTheme, readColorTheme, readReducedMotion } from './lib/theme'
import './styles/global.css'

applyColorTheme(readColorTheme())
document.documentElement.dataset.reducedMotion = String(readReducedMotion())

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
