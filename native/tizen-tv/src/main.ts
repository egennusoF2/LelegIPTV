import "./polyfills";
import { setVisible } from "./polyfills";
import { LelegTvApp } from "./app";

declare global {
  interface Window {
    __lelegTvBooted?: boolean;
  }
}

function hideSplash(): void {
  setVisible(document.getElementById("boot-splash"), false);
}

function showBootError(message: string): void {
  hideSplash();
  const panel = document.getElementById("boot-error");
  if (!panel) return;
  panel.textContent = message;
  setVisible(panel, true);
  panel.style.display = "flex";
}

window.addEventListener("error", (event) => {
  if (!window.__lelegTvBooted) showBootError(`Errore avvio: ${event.message}`);
  else console.error("[Leleg IPTV runtime]", event.message, event.filename, event.lineno);
});

window.addEventListener("unhandledrejection", (event) => {
  const reason = event.reason instanceof Error ? event.reason.message : String(event.reason);
  if (!window.__lelegTvBooted) showBootError(`Errore: ${reason}`);
  else console.error("[Leleg IPTV promise]", reason);
});

function boot(): void {
  if (window.__lelegTvBooted) return;
  window.__lelegTvBooted = true;

  const root = document.getElementById("app");
  if (!root) {
    showBootError("Elemento #app non trovato");
    return;
  }
  try {
    new LelegTvApp();
    hideSplash();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    showBootError(`Errore avvio: ${message}`);
  }
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
