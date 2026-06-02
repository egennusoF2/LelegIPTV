// @ts-check
import { defineConfig } from "astro/config"
import tailwindcss from "@tailwindcss/vite"
import { optimizeTablerIconsImport } from "./src/plugins/vite-plugin-optimize-tabler-icons.ts"
import { streamProxyPlugin } from "./src/plugins/vite-plugin-stream-proxy.ts"
import svelte from "@astrojs/svelte"
import AstroPWA from "@vite-pwa/astro"

/** LAN IP for HMR when running `tauri ios dev` on a physical device (or XTREAM_HMR_HOST override). */
const tauriDevHost = process.env.TAURI_DEV_HOST
const hmrHost = process.env.XTREAM_HMR_HOST || tauriDevHost

export default defineConfig({
  devToolbar: {
    enabled: false,
  },
  vite: {
    define: {
      __XT_PLAYBACK_BUILD__: JSON.stringify("2026-06-01-ios-hls"),
    },
    plugins: [tailwindcss(), optimizeTablerIconsImport(), streamProxyPlugin()],
    server: {
      host: "0.0.0.0",
      port: 4321,
      hmr: hmrHost
        ? { host: hmrHost, protocol: "ws", port: 4321 }
        : undefined,
      warmup: {
        clientFiles: [
          "./src/scripts/movies/detail.ts",
          "./src/scripts/series/detail.ts",
          "./src/scripts/lib/player-runtime.ts",
          "./src/components/PlaylistSwitcher.svelte",
        ],
      },
    },
    build: {
      chunkSizeWarningLimit: 800,
    },
    optimizeDeps: {
      include: [
        "@tauri-apps/api/app",
        "@tauri-apps/api/window",
        "@tauri-apps/api/event",
        "@tauri-apps/plugin-process",
        "@tauri-apps/plugin-updater",
        "@tauri-apps/plugin-http",
        "@tauri-apps/plugin-fs",
        "@tauri-apps/plugin-dialog",
        "@tauri-apps/plugin-notification",
        "@tauri-apps/plugin-opener",
        "tauri-plugin-android-fs-api",
        "@tabler/icons-svelte/icons/chevron-down",
        "@tabler/icons-svelte/icons/plus",
        "@tabler/icons-svelte/icons/refresh",
        "artplayer",
        "hls.js",
        "video.js",
      ],
    },
  },

  integrations: [
    svelte(),
    AstroPWA({
      registerType: "autoUpdate",
      injectRegister: false,
      manifest: {
        id: "/",
        name: "Leleg IPTV",
        short_name: "LelegIPTV",
        description: "IPTV player for live TV, movies and series.",
        lang: "en",
        dir: "ltr",
        start_url: "/",
        scope: "/",
        display: "standalone",
        orientation: "any",
        theme_color: "#0e1628",
        background_color: "#f8fafc",
        categories: ["entertainment", "video"],
        icons: [
          {
            src: "/icon-192.png",
            sizes: "192x192",
            type: "image/png",
            purpose: "any",
          },
          {
            src: "/icon-512.png",
            sizes: "512x512",
            type: "image/png",
            purpose: "any",
          },
          {
            src: "/icon-512.png",
            sizes: "512x512",
            type: "image/png",
            purpose: "maskable",
          },
          {
            src: "/apple-touch-icon.png",
            sizes: "180x180",
            type: "image/png",
          },
        ],
      },
      workbox: {
        globPatterns: ["**/*.{js,css,html,ico,png,svg,woff,woff2}"],
        navigateFallbackDenylist: [/^\/__stream/],
        runtimeCaching: [
          {
            urlPattern: ({ request }) => request.mode === "navigate",
            handler: "NetworkFirst",
            options: {
              cacheName: "pages",
              networkTimeoutSeconds: 5,
              expiration: { maxEntries: 32, maxAgeSeconds: 86400 },
            },
          },
        ],
      },
      devOptions: {
        enabled: true,
        suppressWarnings: true,
      },
    }),
  ],
})
