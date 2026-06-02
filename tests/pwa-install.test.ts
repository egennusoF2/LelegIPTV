import { describe, expect, it, vi, beforeEach, afterEach } from "vitest"
import {
  getPwaInstallState,
  initPwaInstallListeners,
  isDesktopChromium,
  isIosInstallHint,
  isSecureInstallContext,
  isStandalonePwa,
  isTauriShell,
} from "../src/scripts/lib/pwa-install.ts"

describe("pwa-install", () => {
  beforeEach(() => {
    vi.stubGlobal("window", {
      isSecureContext: true,
      matchMedia: vi.fn(() => ({ matches: false, addEventListener: vi.fn() })),
      addEventListener: vi.fn(),
      setTimeout: (fn: () => void) => {
        fn()
        return 0
      },
    })
    vi.stubGlobal("navigator", {
      userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36",
      serviceWorker: {
        getRegistration: vi.fn(async () => ({ active: {} })),
        addEventListener: vi.fn(),
        ready: Promise.resolve({}),
      },
    })
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it("detects Tauri shell", () => {
    ;(window as Window & { __TAURI__?: unknown }).__TAURI__ = {}
    expect(isTauriShell()).toBe(true)
    expect(getPwaInstallState()).toBe("unavailable")
  })

  it("detects standalone display mode", () => {
    vi.mocked(window.matchMedia).mockImplementation((query: string) => ({
      matches: query.includes("standalone"),
      addEventListener: vi.fn(),
    }))
    expect(isStandalonePwa()).toBe(true)
    expect(getPwaInstallState()).toBe("installed")
  })

  it("detects iOS Safari install hint", () => {
    vi.stubGlobal("navigator", {
      userAgent:
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
      serviceWorker: { getRegistration: vi.fn(async () => null), addEventListener: vi.fn(), ready: Promise.resolve({}) },
    })
    expect(isIosInstallHint()).toBe(true)
    expect(getPwaInstallState()).toBe("ios-hint")
  })

  it("shows desktop hint on secure Chrome desktop with service worker", async () => {
    initPwaInstallListeners()
    await Promise.resolve()
    expect(isDesktopChromium()).toBe(true)
    expect(isSecureInstallContext()).toBe(true)
    expect(getPwaInstallState()).toBe("desktop-hint")
  })

  it("blocks install on insecure HTTP LAN origins", () => {
    vi.stubGlobal("window", {
      isSecureContext: false,
      matchMedia: vi.fn(() => ({ matches: false, addEventListener: vi.fn() })),
      addEventListener: vi.fn(),
      setTimeout: vi.fn(),
    })
    expect(getPwaInstallState()).toBe("insecure")
  })
})
