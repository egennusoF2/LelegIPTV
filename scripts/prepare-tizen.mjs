import { copyFile, cp, mkdir, rm } from "node:fs/promises"
import { existsSync } from "node:fs"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const distDir = resolve(root, "dist")
const templateDir = resolve(root, "packaging", "tizen")
const outDir = resolve(root, "build", "tizen-web")
const iconSource = resolve(root, "src-tauri", "icons", "128x128.png")

if (!existsSync(resolve(distDir, "index.html"))) {
  console.error("Missing dist/index.html. Run `pnpm build` before `pnpm tizen:prepare`.")
  process.exit(1)
}

await rm(outDir, { recursive: true, force: true })
await mkdir(outDir, { recursive: true })
await cp(distDir, outDir, { recursive: true })
await copyFile(resolve(templateDir, "config.xml"), resolve(outDir, "config.xml"))

if (existsSync(iconSource)) {
  await copyFile(iconSource, resolve(outDir, "icon.png"))
}

console.log(`Prepared Samsung Tizen TV web app at ${outDir}`)
console.log("Package with Tizen Studio/CLI using your Samsung certificate profile.")
