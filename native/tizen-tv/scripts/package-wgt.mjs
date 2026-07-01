import { cpSync, existsSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const dist = resolve(root, "dist");
const wgtRoot = resolve(root, "build", "wgt");
const outWgt = resolve(root, "build", "LelegIPTV-tizen-tv.wgt");

if (!existsSync(dist)) {
  console.error("Missing dist/. Run: npm run build");
  process.exit(1);
}

rmSync(wgtRoot, { recursive: true, force: true });
rmSync(outWgt, { force: true });
mkdirSync(wgtRoot, { recursive: true });

for (const entry of readdirSync(dist)) {
  cpSync(resolve(dist, entry), resolve(wgtRoot, entry), { recursive: true });
}

cpSync(resolve(root, "config.xml"), resolve(wgtRoot, "config.xml"));

const iconSrc = resolve(root, "public", "icon.png");
if (existsSync(iconSrc)) {
  cpSync(iconSrc, resolve(wgtRoot, "icon.png"));
} else {
  console.warn("public/icon.png missing — add a 117x117 PNG before release");
}

const tizenBin = process.env.TIZEN_CLI || "tizen";
try {
  execSync(`"${tizenBin}" package -t wgt -s ${process.env.TIZEN_CERT_PROFILE || "DevProfile"} -- "${wgtRoot}"`, {
    stdio: "inherit",
    cwd: root,
  });
} catch {
  console.warn("tizen CLI package failed — WGT folder prepared at build/wgt/");
  process.exit(0);
}

const wgts = readdirSync(resolve(root, "build", "wgt")).filter((f) => f.endsWith(".wgt"));
if (wgts.length) {
  const packaged = wgts[0];
  cpSync(resolve(root, "build", "wgt", packaged), outWgt);
  console.log(`Packaged: ${outWgt}`);
}
