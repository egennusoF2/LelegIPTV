<script lang="ts">
  import { onMount } from "svelte"
  import { IconDeviceMobile, IconCheck } from "@tabler/icons-svelte"
  import { t, LOCALE_EVENT } from "@/scripts/lib/i18n.js"
  import {
    subscribePwaInstallState,
    promptPwaInstall,
    type PwaInstallState,
  } from "@/scripts/lib/pwa-install.ts"

  interface Props {
    variant?: "card" | "banner"
  }

  let { variant = "card" }: Props = $props()

  let state = $state<PwaInstallState>("unavailable")
  let installing = $state(false)
  let locale = $state(0)
  const tr = (key: string) => (locale, t(key))

  function helperKey(): string {
    switch (state) {
      case "installed":
        return "settings.webApp.installedHelper"
      case "ios-hint":
        return "settings.webApp.iosHelper"
      case "desktop-hint":
        return "settings.webApp.desktopHelper"
      case "insecure":
        return "settings.webApp.insecureHelper"
      case "no-service-worker":
        return "settings.webApp.noSwHelper"
      default:
        return variant === "banner"
          ? "settings.webApp.helperShort"
          : "settings.webApp.helper"
    }
  }

  async function install() {
    if (installing || state !== "installable") return
    installing = true
    try {
      await promptPwaInstall()
    } finally {
      installing = false
    }
  }

  onMount(() => {
    const unsub = subscribePwaInstallState((next) => { state = next })
    const onLocale = () => { locale++ }
    document.addEventListener(LOCALE_EVENT, onLocale)
    return () => {
      unsub()
      document.removeEventListener(LOCALE_EVENT, onLocale)
    }
  })
</script>

{#if state !== "unavailable"}
  {#if variant === "banner"}
    <section
      id="web-app-install-banner"
      class="rounded-xl border border-line bg-surface px-4 py-3 flex flex-col sm:flex-row sm:items-center gap-3 dl-page-enter dl-stagger-2">
      <div class="flex items-start gap-3 flex-1 min-w-0">
        <IconDeviceMobile aria-hidden="true" class="size-5 text-accent shrink-0 mt-0.5" stroke={2} />
        <div class="flex flex-col gap-1 min-w-0">
          <p class="text-sm font-medium text-fg">{tr("settings.webApp.title")}</p>
          <p class="text-xs text-fg-3">{tr(helperKey())}</p>
        </div>
      </div>
      {#if state === "installable"}
        <button
          type="button"
          class="btn btn-primary shrink-0 self-start sm:self-center"
          disabled={installing}
          onclick={install}>
          {installing ? tr("settings.webApp.installing") : tr("settings.webApp.install")}
        </button>
      {:else if state === "installed"}
        <span class="inline-flex items-center gap-1.5 text-xs text-accent shrink-0">
          <IconCheck aria-hidden="true" class="size-4" stroke={2.5} />
          {tr("settings.webApp.installed")}
        </span>
      {/if}
    </section>
  {:else}
    <article
      id="card-web-app"
      class="icon-mark-host rounded-2xl border border-line bg-surface p-5 sm:p-6 flex flex-col gap-4 scroll-mt-6">
      <div class="flex items-start gap-3">
        <span class="icon-mark">
          <IconDeviceMobile aria-hidden="true" stroke={2} />
        </span>
        <div class="flex flex-col gap-1 min-w-0">
          <h3 class="text-base font-semibold">{tr("settings.webApp.title")}</h3>
          <p class="text-xs text-fg-3">{tr(helperKey())}</p>
        </div>
      </div>

      {#if state === "installable"}
        <button
          type="button"
          class="btn btn-primary self-start"
          disabled={installing}
          onclick={install}>
          {installing ? tr("settings.webApp.installing") : tr("settings.webApp.install")}
        </button>
      {:else if state === "installed"}
        <p class="inline-flex items-center gap-2 text-sm text-accent">
          <IconCheck aria-hidden="true" class="size-4" stroke={2.5} />
          {tr("settings.webApp.installed")}
        </p>
      {/if}
    </article>
  {/if}
{/if}
