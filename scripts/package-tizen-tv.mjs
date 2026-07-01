import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const tizenRoot = resolve(repoRoot, "native/tizen-tv");
const dist = resolve(tizenRoot, "dist");
const wgtRoot = resolve(tizenRoot, "build/wgt");
const outDir = resolve(repoRoot, "www/downloads/current");

if (!existsSync(dist)) {
  console.error("Build Tizen TV first: pnpm tizen-tv:build");
  process.exit(1);
}

mkdirSync(wgtRoot, { recursive: true });
for (const entry of readdirSync(dist)) {
  cpSync(resolve(dist, entry), resolve(wgtRoot, entry), { recursive: true });
}
cpSync(resolve(tizenRoot, "config.xml"), resolve(wgtRoot, "config.xml"));
const icon = resolve(tizenRoot, "public/icon.png");
if (existsSync(icon)) cpSync(icon, resolve(wgtRoot, "icon.png"));

mkdirSync(outDir, { recursive: true });

const signedWgt = resolve(tizenRoot, "build/LelegIPTV-tizen-tv.wgt");
const outWgt = resolve(outDir, "LelegIPTV-tizen-tv-release.wgt");
const outTpk = resolve(outDir, "LelegIPTV-tizen-tv-release.tpk");

execSync("npm run package:wgt", {
  cwd: tizenRoot,
  stdio: "inherit",
  env: {
    ...process.env,
    TIZEN_CLI:
      process.env.TIZEN_CLI ??
      resolve(process.env.HOME ?? "", "tizen-studio/tools/ide/bin/tizen"),
  },
});

if (existsSync(signedWgt)) {
  cpSync(signedWgt, outWgt);
  cpSync(signedWgt, outTpk);
} else {
  mkdirSync(resolve(tizenRoot, "build"), { recursive: true });
  const tmpZip = resolve(tizenRoot, "build/tizen-web.zip");
  execSync(`cd "${wgtRoot}" && zip -qr "${tmpZip}" .`, { stdio: "inherit" });
  cpSync(tmpZip, outWgt);
  cpSync(tmpZip, outTpk);
}

console.log(`Published: ${outWgt}`);

const sumsPath = resolve(outDir, "SHA256SUMS.txt");
let lines = existsSync(sumsPath)
  ? readFileSync(sumsPath, "utf8").split("\n").filter(Boolean)
  : [];
lines = lines.filter((l) => !l.includes("LelegIPTV-tizen-tv-release"));
for (const file of ["LelegIPTV-tizen-tv-release.wgt", "LelegIPTV-tizen-tv-release.tpk"]) {
  const path = resolve(outDir, file);
  if (!existsSync(path)) continue;
  const hash = createHash("sha256").update(readFileSync(path)).digest("hex");
  lines.push(`${hash}  ./${file}`);
}
writeFileSync(sumsPath, `${lines.join("\n")}\n`);
