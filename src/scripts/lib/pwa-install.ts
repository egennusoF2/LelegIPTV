/** PWA install prompt handling (browser only — not Tauri shells). */

export type PwaInstallState =
  | "unavailable"
  | "installable"
  | "ios-hint"
  | "desktop-hint"
  | "insecure"
  | "no-service-worker"
  | "installed"

interface BeforeInstallPromptEvent extends Event {
  prompt: () => Promise<void>
  userChoice: Promise<{ outcome: "accepted" | "dismissed" }>
}

let deferredPrompt: BeforeInstallPromptEvent | null = null
let listenersInitialized = false
let serviceWorkerActive = false
const stateListeners = new Set<(state: PwaInstallState) => void>()

export function isTauriShell(): boolean {
  if (typeof window === "undefined") return false
  const w = window as Window & { __TAURI__?: unknown; __TAURI_INTERNALS__?: unknown }
  return !!(w.__TAURI__ || w.__TAURI_INTERNALS__)
}

export function isStandalonePwa(): boolean {
  if (typeof window === "undefined") return false
  const nav = navigator as Navigator & { standalone?: boolean }
  return (
    window.matchMedia("(display-mode: standalone)").matches ||
    window.matchMedia("(display-mode: minimal-ui)").matches ||
    nav.standalone === true
  )
}

export function isSecureInstallContext(): boolean {
  if (typeof window === "undefined") return false
  return window.isSecureContext
}

/** iOS Safari can be added to Home Screen but has no beforeinstallprompt. */
export function isIosInstallHint(): boolean {
  if (typeof navigator === "undefined") return false
  const ua = navigator.userAgent || ""
  const isIos = /iPad|iPhone|iPod/.test(ua)
  const isSafari =
    /Safari/i.test(ua) && !/CriOS|FxiOS|EdgiOS|OPiOS|Chrome/i.test(ua)
  return isIos && isSafari
}

/** Chrome / Edge on desktop — install often lives in the browser menu, not the address bar. */
export function isDesktopChromium(): boolean {
  if (typeof navigator === "undefined") return false
  const ua = navigator.userAgent || ""
  return /Chrome|Chromium|Edg\//.test(ua) && !/Android|Mobile/i.test(ua)
}

export function getPwaInstallState(): PwaInstallState {
  if (typeof window === "undefined" || isTauriShell()) return "unavailable"
  if (isStandalonePwa()) return "installed"
  if (!isSecureInstallContext()) return "insecure"
  if (deferredPrompt) return "installable"
  if (isIosInstallHint()) return "ios-hint"
  if (!serviceWorkerActive) return "no-service-worker"
  if (isDesktopChromium()) return "desktop-hint"
  return "desktop-hint"
}

function notifyStateListeners(): void {
  const state = getPwaInstallState()
  for (const listener of stateListeners) listener(state)
}

async function probeServiceWorker(): Promise<void> {
  if (typeof navigator === "undefined" || !("serviceWorker" in navigator)) return
  try {
    const registration = await navigator.serviceWorker.getRegistration()
    serviceWorkerActive = !!(registration?.active || registration?.installing || registration?.waiting)
  } catch {
    serviceWorkerActive = false
  }
  notifyStateListeners()
}

export function subscribePwaInstallState(
  listener: (state: PwaInstallState) => void,
): () => void {
  initPwaInstallListeners()
  stateListeners.add(listener)
  listener(getPwaInstallState())
  return () => {
    stateListeners.delete(listener)
  }
}

export function initPwaInstallListeners(): void {
  if (typeof window === "undefined" || listenersInitialized || isTauriShell()) return
  listenersInitialized = true

  void probeServiceWorker()

  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.addEventListener("controllerchange", () => {
      void probeServiceWorker()
    })
    navigator.serviceWorker.ready
      .then(() => probeServiceWorker())
      .catch(() => probeServiceWorker())
  }

  window.addEventListener("beforeinstallprompt", (event) => {
    event.preventDefault()
    deferredPrompt = event as BeforeInstallPromptEvent
    notifyStateListeners()
  })

  window.addEventListener("appinstalled", () => {
    deferredPrompt = null
    notifyStateListeners()
  })

  const onDisplayModeChange = (): void => notifyStateListeners()
  for (const mode of ["standalone", "minimal-ui", "browser"] as const) {
    window.matchMedia(`(display-mode: ${mode})`).addEventListener("change", onDisplayModeChange)
  }

  window.setTimeout(() => void probeServiceWorker(), 1500)
  window.setTimeout(() => void probeServiceWorker(), 5000)
}

export async function promptPwaInstall(): Promise<
  "accepted" | "dismissed" | "unavailable"
> {
  if (!deferredPrompt) return "unavailable"
  const prompt = deferredPrompt
  deferredPrompt = null
  notifyStateListeners()
  await prompt.prompt()
  const { outcome } = await prompt.userChoice
  notifyStateListeners()
  return outcome
}
