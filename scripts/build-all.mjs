#!/usr/bin/env node
/**
 * Build Leleg IPTV targets supported on this machine.
 *
 * Usage:
 *   pnpm build:all
 *   pnpm build:all -- --only web,tizen
 *   pnpm build:all -- --only desktop --skip-test --skip-lint
 *   pnpm build:all -- --continue
 */

import { spawnSync } from "node:child_process"
import { existsSync, readdirSync } from "node:fs"
import { homedir } from "node:os"
import { delimiter, dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const isWin = process.platform === "win32"
const isMac = process.platform === "darwin"
const isLinux = process.platform === "linux"

const ALL_TARGETS = ["web", "tizen", "desktop", "android", "ios"]
const NATIVE_TARGETS = new Set(["desktop", "android", "ios"])

function parseArgs(argv) {
  const opts = {
    only: null,
    skipTest: false,
    skipLint: false,
    continueOnError: false,
    strict: false,
    help: false,
  }
  for (const arg of argv.filter((a) => a !== "--")) {
    if (arg === "--help" || arg === "-h") opts.help = true
    else if (arg === "--skip-test") opts.skipTest = true
    else if (arg === "--skip-lint") opts.skipLint = true
    else if (arg === "--continue") opts.continueOnError = true
    else if (arg === "--strict") opts.strict = true
    else if (arg.startsWith("--only=")) {
      opts.only = arg
        .slice("--only=".length)
        .split(",")
        .map((s) => s.trim().toLowerCase())
        .filter(Boolean)
    }
  }
  return opts
}

function printHelp() {
  console.log(`
Leleg IPTV — build all targets

  pnpm build:all [options]

Options:
  --only=web,tizen,desktop,android,ios   Build subset only
  --skip-test                            Skip vitest
  --skip-lint                            Skip eslint
  --continue                             Keep going after a failed step
  --strict                               Exit 1 if a requested target was skipped (missing tooling)
  -h, --help                             Show this help

Quick commands:
  pnpm build:web      Astro → dist/
  pnpm build:desktop  Tauri (needs Rust: https://rustup.rs)
  pnpm build:android  APK/AAB (Rust + Android SDK)
  pnpm build:ios      iOS (macOS, Xcode, Rust; run pnpm tauri:ios:init first)

Native builds need Rust/Cargo on PATH. Install:
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

After tizen prepare:
  tizen package -t wgt -s <profile> -- build/tizen-web
`)
}

/** rustup installs cargo under ~/.cargo/bin — often missing in non-login shells. */
function ensureCargoInPath() {
  const cargoHome = process.env.CARGO_HOME || join(homedir(), ".cargo")
  const cargoBin = join(cargoHome, "bin")
  if (existsSync(join(cargoBin, "cargo"))) {
    const pathKey = isWin ? "Path" : "PATH"
    const current = process.env[pathKey] || ""
    if (!current.split(delimiter).includes(cargoBin)) {
      process.env[pathKey] = `${cargoBin}${delimiter}${current}`
    }
  }
}

function hasCommand(name) {
  const lookup = isWin ? "where" : "which"
  const result = spawnSync(lookup, [name], { stdio: "ignore", shell: isWin })
  return result.status === 0
}

function hasCargo() {
  ensureCargoInPath()
  return hasCommand("cargo")
}

/** Tauri Android needs a populated SDK (cmdline-tools, platforms, NDK). */
function ensureAndroidEnv() {
  if (process.env.ANDROID_HOME && existsSync(process.env.ANDROID_HOME)) {
    return process.env.ANDROID_HOME
  }
  if (process.env.ANDROID_SDK_ROOT && existsSync(process.env.ANDROID_SDK_ROOT)) {
    process.env.ANDROID_HOME = process.env.ANDROID_SDK_ROOT
    return process.env.ANDROID_SDK_ROOT
  }
  const candidates = isMac
    ? [join(homedir(), "Library", "Android", "sdk")]
    : [join(homedir(), "Android", "Sdk")]
  for (const sdk of candidates) {
    if (existsSync(sdk)) {
      process.env.ANDROID_HOME = sdk
      process.env.ANDROID_SDK_ROOT = sdk
      return sdk
    }
  }
  return null
}

function hasAndroidSdk() {
  const sdk = ensureAndroidEnv()
  if (!sdk) {
    return {
      ok: false,
      reason:
        "Android SDK not found — install Android Studio: https://developer.android.com/studio then set ANDROID_HOME",
    }
  }
  const cmdline = join(sdk, "cmdline-tools")
  const platforms = join(sdk, "platforms")
  const hasCmdline =
    existsSync(join(cmdline, "latest", "bin")) ||
    existsSync(join(cmdline, "bin")) ||
    hasCommand("sdkmanager")
  const hasPlatform = existsSync(platforms) && platformsHasEntries(platforms)
  if (!hasCmdline || !hasPlatform) {
    return {
      ok: false,
      reason: `Android SDK at ${sdk} is incomplete — open Android Studio → SDK Manager, install SDK Platform + Build-Tools + NDK; see https://tauri.app/start/prerequisites/#android`,
    }
  }
  return { ok: true }
}

function platformsHasEntries(dir) {
  try {
    return readdirSync(dir).some((name) => name.startsWith("android-"))
  } catch {
    return false
  }
}

function runStep(label, cmd, args, { cwd = root } = {}) {
  console.log(`\n▶ ${label}`)
  console.log(`  ${cmd} ${args.join(" ")}`)
  const result = spawnSync(cmd, args, {
    cwd,
    stdio: "inherit",
    shell: isWin,
    env: process.env,
  })
  if (result.status !== 0) {
    throw new Error(`${label} failed (exit ${result.status ?? "unknown"})`)
  }
}

function pnpm(args) {
  const cmd = isWin ? "pnpm.cmd" : "pnpm"
  return { cmd, args }
}

function targetAvailable(name) {
  switch (name) {
    case "web":
    case "tizen":
      return { ok: true }
    case "desktop": {
      if (!isWin && !isMac && !isLinux) {
        return { ok: false, reason: "unsupported host OS for Tauri desktop" }
      }
      if (!hasCargo()) {
        return {
          ok: false,
          reason: "Rust/Cargo not found — install: https://rustup.rs then reopen the terminal",
        }
      }
      return { ok: true }
    }
    case "android": {
      const gen = resolve(root, "src-tauri", "gen", "android")
      if (!existsSync(gen)) {
        return {
          ok: false,
          reason: "Android project missing — run: pnpm tauri android init",
        }
      }
      if (!hasCargo()) {
        return {
          ok: false,
          reason: "Rust/Cargo not found — install: https://rustup.rs",
        }
      }
      const sdk = hasAndroidSdk()
      if (!sdk.ok) return sdk
      return { ok: true }
    }
    case "ios": {
      if (!isMac) return { ok: false, reason: "iOS builds require macOS" }
      const apple = resolve(root, "src-tauri", "gen", "apple")
      if (!existsSync(apple)) {
        return {
          ok: false,
          reason: "iOS project missing — run: pnpm tauri:ios:init",
        }
      }
      if (!hasCargo()) {
        return {
          ok: false,
          reason: "Rust/Cargo not found — install: https://rustup.rs",
        }
      }
      return { ok: true }
    }
    default:
      return { ok: false, reason: `unknown target "${name}"` }
  }
}

function collectArtifacts(built) {
  const lines = []
  const add = (line) => lines.push(line)

  if (built.includes("web") && existsSync(resolve(root, "dist", "index.html"))) {
    add("Web:        dist/")
  }
  if (
    built.includes("tizen") &&
    existsSync(resolve(root, "build", "tizen-web", "config.xml"))
  ) {
    add(
      "Tizen:      build/tizen-web/  (then: tizen package -t wgt -s <profile> -- build/tizen-web)",
    )
  }
  if (built.includes("desktop")) {
    const bundle = resolve(root, "src-tauri", "target", "release", "bundle")
    if (existsSync(bundle)) {
      add(`Desktop:    ${bundle}/`)
      if (isMac) add("            …/macos/*.app, …/dmg/*.dmg")
      if (isWin) add("            …/nsis/*.exe, …/msi/*.msi")
      if (isLinux) add("            …/deb/*.deb, …/rpm/*.rpm, …/appimage/*.AppImage")
    }
  }
  if (built.includes("android")) {
    const apkRoot = resolve(
      root,
      "src-tauri",
      "gen",
      "android",
      "app",
      "build",
      "outputs",
    )
    if (existsSync(apkRoot)) {
      add(`Android:    ${apkRoot}/apk/ and …/bundle/`)
    }
  }
  if (built.includes("ios")) {
    const apple = resolve(root, "src-tauri", "gen", "apple")
    if (existsSync(apple)) {
      add(`iOS:        ${apple}/  (Xcode archive / export .ipa)`)
    }
  }
  return lines
}

async function main() {
  ensureCargoInPath()

  const opts = parseArgs(process.argv.slice(2))
  if (opts.help) {
    printHelp()
    return
  }

  const requested = opts.only?.length ? opts.only : ALL_TARGETS
  const unknown = requested.filter((t) => !ALL_TARGETS.includes(t))
  if (unknown.length) {
    console.error(`Unknown target(s): ${unknown.join(", ")}`)
    console.error(`Valid: ${ALL_TARGETS.join(", ")}`)
    process.exit(1)
  }

  const toRun = []
  const skipped = []

  for (const name of requested) {
    const check = targetAvailable(name)
    if (check.ok) toRun.push(name)
    else skipped.push({ name, reason: check.reason })
  }

  console.log("Leleg IPTV — build all")
  console.log(`Host: ${process.platform} ${process.arch}`)
  console.log(`Rust/Cargo: ${hasCargo() ? "yes" : "no"}`)
  console.log(`Will run: ${toRun.join(", ") || "(none)"}`)
  if (skipped.length) {
    console.log("Skipped (preflight):")
    for (const s of skipped) console.log(`  - ${s.name}: ${s.reason}`)
  }

  const failures = []
  const built = []

  const step = async (label, fn) => {
    try {
      await fn()
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err)
      console.error(`\n✗ ${msg}`)
      failures.push({ label, msg })
      if (!opts.continueOnError) throw err
    }
  }

  try {
    if (!opts.skipLint) {
      await step("lint", () => {
        const { cmd, args } = pnpm(["lint"])
        runStep("lint", cmd, args)
      })
    }

    if (!opts.skipTest) {
      await step("test", () => {
        const { cmd, args } = pnpm(["test"])
        runStep("test", cmd, args)
      })
    }

    const needsWebDist =
      toRun.includes("web") ||
      toRun.includes("tizen") ||
      toRun.includes("desktop") ||
      toRun.includes("android") ||
      toRun.includes("ios")

    if (needsWebDist) {
      await step("web (astro build)", () => {
        const { cmd, args } = pnpm(["build"])
        runStep("web", cmd, args)
      })
      if (toRun.includes("web") || toRun.includes("tizen")) built.push("web")
    }

    if (toRun.includes("tizen")) {
      await step("tizen prepare", () => {
        const { cmd, args } = pnpm(["tizen:prepare"])
        runStep("tizen:prepare", cmd, args)
      })
      built.push("tizen")
    }

    if (toRun.includes("desktop")) {
      await step("desktop (tauri build)", () => {
        const { cmd, args } = pnpm(["tauri", "build"])
        runStep("desktop", cmd, args)
      })
      built.push("desktop")
    }

    if (toRun.includes("android")) {
      await step("android", () => {
        const { cmd, args } = pnpm(["tauri", "android", "build"])
        runStep("android", cmd, args)
      })
      built.push("android")
    }

    if (toRun.includes("ios")) {
      await step("ios", () => {
        const { cmd, args } = pnpm(["tauri", "ios", "build"])
        runStep("ios", cmd, args)
      })
      built.push("ios")
    }
  } catch {
    // logged; summary below
  }

  console.log("\n" + "=".repeat(60))

  if (failures.length) {
    console.log("Failures:")
    for (const f of failures) console.log(`  - ${f.label}: ${f.msg}`)
  } else if (built.length) {
    console.log(`Built: ${built.join(", ")}`)
  } else if (toRun.length === 0 && skipped.length) {
    console.log("Nothing to build — fix skipped targets above.")
  }

  const artifacts = collectArtifacts(built)
  if (artifacts.length) {
    console.log("\nArtifacts:")
    for (const line of artifacts) console.log(`  ${line}`)
  }

  if (skipped.some((s) => NATIVE_TARGETS.has(s.name)) && !hasCargo()) {
    console.log("\nInstall Rust for desktop/Android/iOS builds:")
    console.log("  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh")
    console.log("  source \"$HOME/.cargo/env\"")
  }

  console.log("=".repeat(60))

  // Web/tizen/desktop succeeded but android/ios skipped or failed → still OK unless --strict
  const onlyNativeFailed =
    failures.length > 0 &&
    failures.every((f) => /android|ios/i.test(f.label)) &&
    built.some((t) => t === "web" || t === "tizen" || t === "desktop")

  if (failures.length && !onlyNativeFailed) process.exit(1)

  if (opts.strict && skipped.length) {
    const requestedSkip = skipped.filter((s) => requested.includes(s.name))
    if (requestedSkip.length) process.exit(1)
  }

  if (built.length === 0 && requested.length > 0) process.exit(1)

  if (onlyNativeFailed) {
    console.log(
      "\nNote: web/tizen/desktop built successfully; fix Android/iOS tooling for native mobile builds.",
    )
  }
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
