import { LelegTvApp } from "./app";

function hideSplash(): void {
  const splash = document.getElementById("boot-splash");
  if (splash) splash.hidden = true;
}

function showBootError(message: string): void {
  hideSplash();
  const panel = document.getElementById("boot-error");
  if (!panel) return;
  panel.hidden = false;
  panel.textContent = message;
}

window.addEventListener("error", (event) => {
  showBootError(`Errore avvio: ${event.message}`);
});

window.addEventListener("unhandledrejection", (event) => {
  const reason = event.reason instanceof Error ? event.reason.message : String(event.reason);
  showBootError(`Errore: ${reason}`);
});

function boot(): void {
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
