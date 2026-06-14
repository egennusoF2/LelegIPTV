// Ambient global types for browser-side code that touches Tauri runtime
// internals, the spatial-navigation polyfill, and Android intent bridges.

interface AndroidPipBridge {
  enter?: () => void
  exit?: () => void
}

interface AndroidIntentBridge {
  isVlcInstalled?: () => boolean
  isMxPlayerInstalled?: () => boolean
  viewStream?: (
    url: string,
    mime: string,
    userAgent: string,
    referer: string,
    title: string,
  ) => boolean
  openInVlc?: (
    url: string,
    mime: string,
    userAgent: string,
    referer: string,
    title: string,
  ) => boolean
  /** Returns a JSON-encoded array of {pkg, label, activity}. */
  listVideoPlayerApps?: (url: string, mime: string) => string
  openInPackage?: (
    pkg: string,
    activity: string,
    url: string,
    mime: string,
    userAgent: string,
    referer: string,
    title: string,
  ) => boolean
}

interface SpatialNavigationApi {
  init: () => void
  uninit: () => void
  add: (config: Record<string, unknown>) => void
  remove: (sectionId: string) => void
  focus: (sectionId?: string) => boolean
  move: (direction: string) => boolean
  makeFocusable: (sectionId?: string) => void
  setDefaultSection: (sectionId: string) => void
  pause: () => void
  resume: () => void
  enable: (sectionId?: string) => void
  disable: (sectionId?: string) => void
  isFocusable: (element: Element, sectionId?: string) => boolean
  set: (sectionId: string, config: Record<string, unknown>) => void
}

/** Injected by `astro.config.mjs` vite.define for Tauri builds that use the web `/__stream` proxy. */
declare const __XT_STREAM_PROXY_ORIGIN__: string
declare const __XT_WEB_STREAM_PROXY__: string

declare global {
  interface Window {
    __TAURI__?: unknown
    __TAURI_INTERNALS__?: unknown
    SpatialNavigation?: SpatialNavigationApi
    AndroidPip?: AndroidPipBridge
    AndroidIntent?: AndroidIntentBridge
  }
}

export {}
