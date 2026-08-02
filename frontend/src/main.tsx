import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import { readReducedMotion } from './lib/theme'
import './styles/global.css'

document.documentElement.dataset.theme = 'light'
document.documentElement.style.colorScheme = 'light'
document.documentElement.dataset.reducedMotion = String(readReducedMotion())

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
