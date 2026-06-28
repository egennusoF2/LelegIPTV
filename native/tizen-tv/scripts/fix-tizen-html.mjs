import { readFileSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const indexPath = resolve(root, "dist", "index.html");
let html = readFileSync(indexPath, "utf8");

html = html.replace(/ crossorigin/g, "");

const cssMatch = html.match(/<link rel="stylesheet" href="\.\/assets\/[^"]+\.css">/);
const jsMatch = html.match(/<script type="module" src="\.\/assets\/[^"]+\.js"><\/script>/);

if (!jsMatch) {
  console.error("fix-tizen-html: bundled JS tag not found in dist/index.html");
  process.exit(1);
}

const cssTag = cssMatch?.[0] ?? "";
const jsSrc = jsMatch[0].replace('type="module"', 'type="text/javascript"');

html = html
  .replace(/<link rel="stylesheet" href="\.\/assets\/[^"]+\.css">\s*/g, "")
  .replace(/<script type="module" src="\.\/assets\/[^"]+\.js"><\/script>\s*/g, "")
  .replace("</head>", cssTag ? `  ${cssTag}\n  </head>` : "</head>")
  .replace(
    "</body>",
    `    <script type="text/javascript" src="$WEBAPIS/webapis/webapis.js"></script>\n    ${jsSrc}\n  </body>`,
  );

writeFileSync(indexPath, html);
console.log("Fixed dist/index.html for Samsung Tizen TV");
