import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const sourceHtml = resolve(root, "docs", "installazione-dispositivi.html")
const sourceBuildDocs = resolve(root, "docs", "BUILD_ARTIFACTS.md")
const sourceDownloads = resolve(root, "www", "downloads", "current")
const dist = resolve(root, "dist")
const distDownloads = resolve(dist, "downloads", "current")

if (!existsSync(dist)) {
  throw new Error("Missing dist/. Run pnpm build:pages before prepare-download-center.")
}
if (!existsSync(sourceHtml)) {
  throw new Error(`Missing ${sourceHtml}`)
}
if (!existsSync(sourceDownloads)) {
  throw new Error(`Missing ${sourceDownloads}`)
}

mkdirSync(distDownloads, { recursive: true })
for (const entry of readdirSync(sourceDownloads)) {
  const source = resolve(sourceDownloads, entry)
  if (!statSync(source).isFile()) continue
  cpSync(source, resolve(distDownloads, entry))
}

let html = readFileSync(sourceHtml, "utf8")
html = html.replaceAll("../www/downloads/current/", "downloads/current/")
html = html.replaceAll('href="BUILD_ARTIFACTS.md', 'href="BUILD_ARTIFACTS.md')
html = html.replaceAll('href="../dist/login/index.html"', 'href="login/"')
writeFileSync(resolve(dist, "index.html"), html)

if (existsSync(sourceBuildDocs)) {
  cpSync(sourceBuildDocs, resolve(dist, "BUILD_ARTIFACTS.md"))
}

const staleNested = resolve(dist, "www")
if (existsSync(staleNested)) {
  rmSync(staleNested, { recursive: true, force: true })
}

console.log("Download center prepared at dist/index.html")
console.log("Artifacts copied to dist/downloads/current/")
