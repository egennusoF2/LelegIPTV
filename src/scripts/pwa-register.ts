/** Register the service worker only in browser deployments (not Tauri WebView). */
function isTauriShell(): boolean {
  if (typeof window === "undefined") return false
  const w = window as Window & { __TAURI__?: unknown; __TAURI_INTERNALS__?: unknown }
  return !!(w.__TAURI__ || w.__TAURI_INTERNALS__)
}

export function initPwa(): void {
  if (typeof window === "undefined" || isTauriShell()) return

  void import("virtual:pwa-register").then(({ registerSW }) => {
    registerSW({
      immediate: true,
      onOfflineReady() {
        console.info("[pwa] App shell cached for offline use")
      },
    })
  })

  void import("./lib/pwa-install.ts").then(({ initPwaInstallListeners }) => {
    initPwaInstallListeners()
  })
}

initPwa()
