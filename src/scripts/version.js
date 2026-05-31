// scripts/version.js
import { log } from "@/scripts/lib/log.js"

function isTauriRuntime() {
    return typeof window !== "undefined" &&
        (!!window.__TAURI_INTERNALS__ || !!window.__TAURI__)
}

export async function injectVersion() {
    if (!isTauriRuntime()) return
    const target = document.getElementById('app-version')
    if (!target) return
    try {
        const { getVersion, getName } = await import('@tauri-apps/api/app')
        const version = await getVersion()
        const name = await getName()
        target.textContent = `${name} v${version}`
    } catch (e) {
        log.warn('Could not get app version:', e)
    }
}
