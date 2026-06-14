import { copyFile, cp, mkdir, rm, readFile, writeFile } from "node:fs/promises"
import { existsSync } from "node:fs"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { glob } from "node:fs/promises"

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

// Rewrite config.xml to load from dev server so the TV always gets fresh files
// without needing a WGT reinstall. The installed WGT becomes a thin launcher.
const DEV_SERVER_URL = process.env.TIZEN_DEV_URL || "http://192.168.1.9:8099/"
let configXml = await readFile(resolve(outDir, "config.xml"), "utf8")
configXml = configXml.replace(/<tizen:content\s+src="[^"]*"/, `<tizen:content src="${DEV_SERVER_URL}"`)
await writeFile(resolve(outDir, "config.xml"), configXml)
console.log(`config.xml → src="${DEV_SERVER_URL}" (dev server mode)`)

if (existsSync(iconSource)) {
  await copyFile(iconSource, resolve(outDir, "icon.png"))
}

// ---------------------------------------------------------------------------
// CSS: unwrap @layer blocks — Tizen TV uses Chromium ~94 which predates
// @layer support (Chrome 99). All Tailwind utilities, theme tokens, and base
// styles live inside @layer rules and are completely ignored without this fix.
// ---------------------------------------------------------------------------
function unwrapCssLayers(css) {
  // 1. Strip bare @layer ordering declarations: "@layer a, b, c;"
  css = css.replace(/@layer\s+[^{;]+;/g, "")
  // 2. Unwrap @layer name { … } blocks by extracting their inner content.
  //    We must track brace depth to correctly handle nested { } (media, etc.)
  let result = ""
  let i = 0
  while (i < css.length) {
    // Match "@layer" keyword followed by optional name(s) and "{"
    if (
      css[i] === "@" &&
      css.slice(i, i + 6).toLowerCase() === "@layer"
    ) {
      // Find the opening brace
      let bracePos = css.indexOf("{", i)
      if (bracePos === -1) { result += css[i++]; continue }
      // Skip over everything up to the opening brace (the "@layer name" part)
      i = bracePos + 1
      // Find the matching closing brace using depth tracking
      let depth = 1
      let start = i
      while (i < css.length && depth > 0) {
        if (css[i] === "{") depth++
        else if (css[i] === "}") depth--
        i++
      }
      // Append the inner content (without the outer @layer { } wrapper)
      result += css.slice(start, i - 1)
    } else {
      result += css[i++]
    }
  }
  return result
}

const cssFiles = []
for await (const f of glob("**/*.css", { cwd: outDir })) {
  cssFiles.push(resolve(outDir, f))
}
for (const cssPath of cssFiles) {
  const original = await readFile(cssPath, "utf8")
  if (!original.includes("@layer")) continue
  const patched = unwrapCssLayers(original)
  await writeFile(cssPath, patched, "utf8")
}
console.log(`Unwrapped @layer in ${cssFiles.filter(async f => (await readFile(f,"utf8")).includes("@layer")).length || "some"} CSS file(s) for Tizen WGT compatibility.`)

// ---------------------------------------------------------------------------
// JS: Chromium 94 compatibility patches on built chunks.
//
// 1. Astro inline script modules (*_astro_type_script_*.js) use top-level `await`.
//    Samsung Chromium 94 does not support top-level await in ESM modules.
//    Fix: keep leading `import` statements at module scope, wrap the rest in
//    an async IIFE so `await` is inside an async function.
//
// 2. stream-proxy chunk references `isTauri` from creds.js without importing
//    it — the Vite chunk splitter left the symbol as a free variable.
//    Fix: inject a local `var isTauri = …` definition.
// ---------------------------------------------------------------------------
const jsFiles = []
for await (const f of glob("**/*.js", { cwd: outDir })) {
  jsFiles.push(resolve(outDir, f))
}
let patchedTLA = 0
for (const jsPath of jsFiles) {
  let js = await readFile(jsPath, "utf8")
  let changed = false

  // Patch 1 — top-level await in Astro script modules.
  // Only target *_astro_type_script_*.js — compiled inline <script> tags from Astro pages.
  // These files use dynamic import() (not static import statements) and have no exports,
  // so wrapping in (async function(){...})() is always safe.
  const isAstroScript = /astro_type_script/.test(jsPath)
  if (isAstroScript && !js.includes("(async function()") && js.includes("await ")) {
    js = `(async function(){\n${js}\n})();`
    changed = true
    patchedTLA++
  }

  // Patch 2 — stream-proxy chunk: inject missing isTauri definition.
  if (!changed && js.includes("||isTauri)") && !js.includes("var isTauri")) {
    const insertAfter = js.includes("import{") ? js.indexOf(";", js.indexOf("import{")) + 1 : 0
    const def = 'var isTauri=typeof window!="undefined"&&(!!(window.__TAURI_INTERNALS__)||!!(window.__TAURI__));'
    js = js.slice(0, insertAfter) + def + js.slice(insertAfter)
    changed = true
  }

  if (changed) await writeFile(jsPath, js, "utf8")
}
if (patchedTLA) console.log(`Wrapped top-level await in ${patchedTLA} JS module(s) for Chromium 94.`)

// ---------------------------------------------------------------------------
// HTML: Tizen TV loads WGT files from a local filesystem (file:///opt/usr/apps/...).
// Absolute paths like /_astro/... fail because "/" doesn't map to the WGT root.
// Convert all absolute asset paths to relative paths in every HTML file.
// ---------------------------------------------------------------------------
const htmlFiles = []
for await (const f of glob("**/*.html", { cwd: outDir })) {
  htmlFiles.push(resolve(outDir, f))
}
for (const htmlPath of htmlFiles) {
  let html = await readFile(htmlPath, "utf8")
  // Depth of the HTML file relative to outDir (index.html → 0, livetv/index.html → 1, etc.)
  const rel = htmlPath.slice(outDir.length + 1)
  const depth = rel.split("/").length - 1
  const prefix = depth === 0 ? "./" : "../".repeat(depth)
  // Replace ALL attribute values that start with an absolute path "/"
  // This covers src=, href=, component-url=, renderer-url=, action=, content= etc.
  html = html.replace(/="\/([^/"'][^"]*?)"/g, (match, rest) => {
    // Leave protocol-relative URLs (//cdn...) and data: URLs unchanged
    if (rest.startsWith("/") || rest.startsWith("data:")) return match
    return `="${prefix}${rest}"`
  })

  // Tizen TV: fix viewport width so text/UI elements are legible on 1080p screen.
  // "device-width" on a 1920px TV makes everything tiny; 1280 scales it up 1.5x.
  html = html.replace(
    /content="width=device-width[^"]*"/,
    'content="width=1280, initial-scale=1"'
  )

  // Tizen TV: bigger fonts + focus ring. font-size (not zoom) avoids layout
  // changes — only rem-based text scales up, element positions stay correct.
  const tizenHeadScript = `<style>
html { font-size: 150% !important; }
*:focus, *:focus-visible {
  outline: 2px solid #facc15 !important;
  outline-offset: 3px !important;
}
</style>
<script>
// Forward all JS errors to the dev server so we can diagnose Chromium 94 issues.
(function(){
  var LOG_URL="http://192.168.1.9:8099/tizen-log";
  function send(obj){ try{ fetch(LOG_URL,{method:"POST",body:JSON.stringify(obj)}); }catch(e){} }
  window.addEventListener("error",function(e){
    send({type:"error",msg:e.message||String(e),src:e.filename,line:e.lineno,col:e.colno,stack:e.error&&e.error.stack});
  },true);
  window.addEventListener("unhandledrejection",function(e){
    send({type:"unhandledrejection",reason:String(e.reason),stack:e.reason&&e.reason.stack});
  });
  window.__tizenLog=function(msg){ send({type:"log",msg:String(msg)}); };
})();
// Polyfill: Element.replaceChildren — added Chrome 86, missing on Samsung Chromium 94.
if(!Element.prototype.replaceChildren){
  Element.prototype.replaceChildren=function(){
    while(this.firstChild)this.removeChild(this.firstChild);
    for(var i=0;i<arguments.length;i++){
      var n=arguments[i];
      this.appendChild(typeof n==="string"?document.createTextNode(n):n);
    }
  };
}
if(!Document.prototype.replaceChildren){Document.prototype.replaceChildren=Element.prototype.replaceChildren;}
if(!DocumentFragment.prototype.replaceChildren){DocumentFragment.prototype.replaceChildren=Element.prototype.replaceChildren;}
// Activate built-in TV overscan safe-area padding (defined in Layout.astro global CSS).
document.documentElement.setAttribute("data-tv-overscan", "");
document.documentElement.style.setProperty("--xt-tv-overscan", "3");
// Add left padding to the main content area so it doesn't collide with the sidebar.
document.addEventListener("DOMContentLoaded", function(){
  var wrap = document.querySelector(".overflow-x-clip.overflow-y-auto");
  if (wrap) { wrap.style.paddingLeft = "1.5rem"; wrap.style.paddingRight = "1rem"; }
});
</script>`
  html = html.replace("</head>", tizenHeadScript + "\n</head>")

  // Injected just before </body>: key reg + virtual-focus D-pad nav + focus ring.
  //
  // VIRTUAL FOCUS PATTERN (TV best-practice):
  //   - Arrow keys move a yellow outline between focusable elements.
  //   - Buttons/links/selects: get real browser focus (Enter activates natively).
  //   - Inputs/textareas:  NO real focus on arrow nav (prevents virtual keyboard).
  //                        Enter on a highlighted input opens keyboard.
  //   - When keyboard is open (input has real focus), Enter submits form natively.
  const tizenKeyScript = `<script>
(function(){
  // 1. Register Tizen remote-control keys.
  try {
    var keys=["ArrowUp","ArrowDown","ArrowLeft","ArrowRight",
              "Enter","Back","0","1","2","3","4","5","6","7","8","9",
              "ColorF0Red","ColorF1Green","ColorF2Yellow","ColorF3Blue",
              "ChannelUp","ChannelDown","VolumeUp","VolumeDown"];
    if(window.tizen&&window.tizen.tvinputdevice)
      keys.forEach(function(k){try{tizen.tvinputdevice.registerKey(k);}catch(e){}});
  }catch(e){}

  // 2. Virtual focus state.
  var _vf=null;
  var SEL='a[href],button:not([disabled]),input:not([disabled]):not([type="hidden"]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])';

  function vfClear(el){
    if(!el)return;
    el.style.outline="";el.style.outlineOffset="";
  }
  function vfSet(el){
    if(_vf&&_vf!==el)vfClear(_vf);
    _vf=el;
    if(!el)return;
    el.style.outline="2px solid #facc15";el.style.outlineOffset="3px";
    el.scrollIntoView({block:"nearest",inline:"nearest"});
    var tag=el.tagName;
    // Real focus for non-input elements (activates natively with Enter/Space).
    // Inputs/textareas: no real focus here — keyboard stays closed until user presses Enter.
    if(tag!=="INPUT"&&tag!=="TEXTAREA")el.focus();
  }

  // 3. Focus/blur ring for elements focused by real browser (mouse, tab, Enter-on-input).
  document.addEventListener("focus",function(e){
    var t=e.target;
    if(!t||t===document.body||t===document.documentElement)return;
    // Sync virtual focus pointer when element receives real focus.
    if(_vf&&_vf!==t)vfClear(_vf);
    _vf=t;
    t.style.outline="2px solid #facc15";t.style.outlineOffset="3px";
  },true);
  document.addEventListener("blur",function(e){
    var t=e.target;
    if(!t||t===document.body)return;
    // For inputs: keep yellow outline after keyboard closes so user sees current position.
    if(t.tagName!=="INPUT"&&t.tagName!=="TEXTAREA"){
      t.style.outline="";t.style.outlineOffset="";
      if(_vf===t)_vf=null;
    }
  },true);

  // 4. Arrow + Enter keydown.
  //
  // PERFORMANCE: instead of querySelectorAll+getBoundingClientRect on every keypress
  // (freezes Chromium 94 on 500+ elements), we use IntersectionObserver to maintain
  // a live set of *currently-visible* focusable elements asynchronously.
  // On each keypress we call getBoundingClientRect only on that small visible set (~20-30).
  var _visible=[];
  var _io=new IntersectionObserver(function(entries){
    for(var i=0;i<entries.length;i++){
      var t=entries[i].target;
      var idx=_visible.indexOf(t);
      if(entries[i].isIntersecting){if(idx<0)_visible.push(t);}
      else{if(idx>=0)_visible.splice(idx,1);}
    }
  },{threshold:0.01});

  function observeEl(el){
    if(el.nodeType!==1)return;
    if(el.matches&&el.matches(SEL))_io.observe(el);
    var ch=el.querySelectorAll?el.querySelectorAll(SEL):[];
    for(var i=0;i<ch.length;i++)_io.observe(ch[i]);
  }
  // Observe all elements already in the DOM.
  if(document.readyState==="loading"){
    document.addEventListener("DOMContentLoaded",function(){observeEl(document.body||document.documentElement);});
  }else{observeEl(document.body||document.documentElement);}
  // Observe elements added later (lazy-loaded content, dialogs, etc.).
  new MutationObserver(function(mutations){
    for(var i=0;i<mutations.length;i++){
      var added=mutations[i].addedNodes;
      for(var j=0;j<added.length;j++)observeEl(added[j]);
    }
  }).observe(document.documentElement,{childList:true,subtree:true});

  // Helper: click the most-relevant element.
  // For wrapper divs with tabindex, delegate to inner <a>/<button> if present.
  // NEVER search inside inputs/textareas (they have no children anyway, but be explicit).
  function doClick(el){
    if(!el)return;
    var tag=el.tagName;
    if(tag==="INPUT"||tag==="TEXTAREA"||tag==="SELECT"){el.click();return;}
    if(tag==="A"||tag==="BUTTON"){el.click();return;}
    // Wrapper element: find the first actionable child.
    var inner=el.querySelector("a[href],button:not([disabled])");
    if(inner){inner.click();}else{el.click();}
  }

  var _navThrottle=0;
  document.addEventListener("keydown",function(e){
    var c=e.keyCode;
    var act=document.activeElement, atag=act?act.tagName:"";

    // ── Arrow keys ──────────────────────────────────────────────────────────
    if(c===37||c===38||c===39||c===40){
      // Left/right inside a focused text input: cursor movement — don't intercept.
      if((c===37||c===39)&&(atag==="INPUT"||atag==="TEXTAREA"))return;
      // Up/down inside a focused select: native option change — don't intercept.
      if((c===38||c===40)&&atag==="SELECT")return;
      // Up/down while keyboard is open: blur (close keyboard) then navigate.
      if((c===38||c===40)&&(atag==="INPUT"||atag==="TEXTAREA"))act.blur();

      e.preventDefault();e.stopPropagation();

      // Throttle: max one step every 120ms.
      var now=Date.now();
      if(now-_navThrottle<120)return;
      _navThrottle=now;

      // Build nav list from IntersectionObserver's live visible set.
      // getBoundingClientRect called only on ~20-30 visible elements, NOT on 1000+.
      var els=[],rects=[];
      for(var i=0;i<_visible.length;i++){
        var el=_visible[i];
        if(!el.isConnected)continue;
        var r=el.getBoundingClientRect();
        if(r.width>0&&r.height>0){els.push(el);rects.push(r);}
      }
      if(!els.length)return;

      var base=_vf||(act&&act!==document.body?act:null);
      var next=null;

      if(!base){
        next=els[0];
      } else {
        var bi=els.indexOf(base);
        var br2=bi>=0?rects[bi]:base.getBoundingClientRect();
        var bx=br2.left+br2.width/2, by=br2.top+br2.height/2;
        var best=Infinity;
        for(var j=0;j<els.length;j++){
          if(els[j]===base)continue;
          var er=rects[j];
          var ex=er.left+er.width/2, ey=er.top+er.height/2;
          var dx=ex-bx, dy=ey-by;
          var ok=false;
          if(c===38&&dy<-4)ok=true;
          else if(c===40&&dy>4)ok=true;
          else if(c===37&&dx<-4)ok=true;
          else if(c===39&&dx>4)ok=true;
          if(!ok)continue;
          var dist=(c===38||c===40)?Math.abs(dy)+Math.abs(dx)*3:Math.abs(dx)+Math.abs(dy)*3;
          if(dist<best){best=dist;next=els[j];}
        }
        if(!next)return;
      }
      vfSet(next);
      return;
    }

    // ── Enter key ────────────────────────────────────────────────────────────
    if(c===13){
      // Input/Textarea with real focus (keyboard open): let native handle.
      if(act&&(atag==="INPUT"||atag==="TEXTAREA"))return;

      // Tizen TV does NOT auto-activate focused buttons/links on Enter.
      if(act&&act!==document.body&&act!==document.documentElement){
        e.preventDefault();e.stopPropagation();
        doClick(act);
        return;
      }

      // Virtual-focus-only: highlighted element has no real browser focus.
      if(_vf){
        var vtag=_vf.tagName;
        if(vtag==="INPUT"||vtag==="TEXTAREA"){
          _vf.focus();if(_vf.select)_vf.select();
        }else{
          e.preventDefault();e.stopPropagation();
          doClick(_vf);
        }
      }
    }
  },true);

  // 5. Initial focus after page is interactive.
  window.addEventListener("load",function(){
    setTimeout(function(){
      if(!document.activeElement||document.activeElement===document.body){
        var f=document.querySelector(SEL);if(f)vfSet(f);
      }
    },900);
  });

  // 6. Pre-fill playlist credentials — waits for form to appear in DOM.
  var _ff=false,_obs=new MutationObserver(function(){
    if(_ff)return;
    var s=document.getElementById("serverUrl"),u=document.getElementById("username"),p=document.getElementById("password");
    if(!s||!u||!p)return;
    _ff=true;_obs.disconnect();
    function fill(el,v){
      try{Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value").set.call(el,v);}catch(e){el.value=v;}
      el.dispatchEvent(new Event("input",{bubbles:true}));
      el.dispatchEvent(new Event("change",{bubbles:true}));
    }
    fill(s,"http://watchtivo-4k.com");fill(u,"S0OGVXO1Pp");fill(p,"o0srX4f8Ni");
  });
  _obs.observe(document.body,{childList:true,subtree:true});
  setTimeout(function(){_obs.disconnect();},60000);
})();
</script>`
  html = html.replace("</body>", tizenKeyScript + "\n</body>")
  await writeFile(htmlPath, html, "utf8")
}
console.log(`Prepared Samsung Tizen TV web app at ${outDir}`)
console.log("Package with Tizen Studio/CLI using your Samsung certificate profile.")
