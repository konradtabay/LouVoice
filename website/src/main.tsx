import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'

// No StrictMode: its dev double-mount calls loseContext() on the WebGL canvases
// (Dither + EngravedBrain), leaving the remount with a dead context.
createRoot(document.getElementById('root')!).render(<App />)
