import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { marked } from "marked"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const sourceHtml = resolve(root, "docs", "installazione-dispositivi.html")
const sourceBuildDocs = resolve(root, "docs", "BUILD_ARTIFACTS.md")
const sourceDownloads = resolve(root, "www", "downloads", "current")
const dist = resolve(root, "dist")
const distDownloads = resolve(dist, "downloads", "current")
const allowLargeDownloads = process.env.ALLOW_LARGE_DOWNLOADS === "1"
const maxHostedDownloadBytes = 50 * 1024 * 1024

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
  const stat = statSync(source)
  if (!stat.isFile()) continue
  if (!allowLargeDownloads && stat.size > maxHostedDownloadBytes) {
    console.warn(`Skipping large download artifact for Pages deploy: ${entry}`)
    continue
  }
  cpSync(source, resolve(distDownloads, entry))
}

let html = readFileSync(sourceHtml, "utf8")
html = html.replaceAll("../www/downloads/current/", "downloads/current/")
html = html.replaceAll('href="../dist/login/index.html"', 'href="login/"')
writeFileSync(resolve(dist, "index.html"), html)

if (existsSync(sourceBuildDocs)) {
  cpSync(sourceBuildDocs, resolve(dist, "BUILD_ARTIFACTS.md"))
  const buildMarkdown = readFileSync(sourceBuildDocs, "utf8")
  const buildHtml = `<!doctype html>
<html lang="it">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Leleg IPTV - Playbook tecnico</title>
  <style>
    :root{color-scheme:dark;--bg:#071014;--panel:#111b21;--fg:#e8f0f4;--muted:#9fb0bb;--line:#29414d;--accent:#45c7f0}
    body{margin:0;background:radial-gradient(circle at top left,#07323b 0,#071014 42rem);color:var(--fg);font:16px/1.58 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    main{max-width:1040px;margin:0 auto;padding:32px 20px 72px}
    a{color:var(--accent)}
    h1,h2,h3{line-height:1.12}
    h1{font-size:clamp(2.2rem,7vw,4rem);margin:0 0 1rem}
    h2{margin-top:2.2rem;border-top:1px solid var(--line);padding-top:1.4rem}
    pre{overflow:auto;background:#03080b;border:1px solid var(--line);border-radius:10px;padding:16px}
    code{background:#03080b;border:1px solid rgba(255,255,255,.08);border-radius:6px;padding:.12em .35em}
    pre code{border:0;padding:0}
    table{width:100%;border-collapse:collapse;margin:1rem 0;border:1px solid var(--line)}
    th,td{border-bottom:1px solid var(--line);padding:10px;text-align:left;vertical-align:top}
    th{color:var(--accent);background:rgba(69,199,240,.08)}
    .back{display:inline-flex;margin-bottom:22px;text-decoration:none;font-weight:700}
  </style>
</head>
<body>
  <main>
    <a class="back" href="./">← Torna ai download</a>
    ${marked.parse(buildMarkdown)}
  </main>
</body>
</html>`
  writeFileSync(resolve(dist, "BUILD_ARTIFACTS.html"), buildHtml)
}

const staleNested = resolve(dist, "www")
if (existsSync(staleNested)) {
  rmSync(staleNested, { recursive: true, force: true })
}

console.log("Download center prepared at dist/index.html")
console.log("Artifacts copied to dist/downloads/current/")
