/** DOM/API polyfills for Samsung Tizen TV web runtime (older WebKit). */

function appendNodes(node: Element, nodes: Array<Node | string>): void {
  for (const entry of nodes) {
    node.appendChild(typeof entry === "string" ? document.createTextNode(entry) : entry);
  }
}

function prependNodes(node: Element, nodes: Array<Node | string>): void {
  const first = node.firstChild;
  for (const entry of nodes) {
    const child = typeof entry === "string" ? document.createTextNode(entry) : entry;
    if (first) node.insertBefore(child, first);
    else node.appendChild(child);
  }
}

if (typeof Element !== "undefined") {
  if (!Element.prototype.append) {
    Element.prototype.append = function appendPolyfill(this: Element, ...nodes: Array<Node | string>) {
      appendNodes(this, nodes);
    };
  }
  if (!Element.prototype.prepend) {
    Element.prototype.prepend = function prependPolyfill(this: Element, ...nodes: Array<Node | string>) {
      prependNodes(this, nodes);
    };
  }
  if (!Element.prototype.replaceChildren) {
    Element.prototype.replaceChildren = function replaceChildrenPolyfill(
      this: Element,
      ...nodes: Array<Node | string>
    ) {
      while (this.firstChild) this.removeChild(this.firstChild);
      appendNodes(this, nodes);
    };
  }
}

if (typeof HTMLElement !== "undefined" && !("hidden" in HTMLElement.prototype)) {
  Object.defineProperty(HTMLElement.prototype, "hidden", {
    configurable: true,
    get(this: HTMLElement) {
      return this.hasAttribute("hidden");
    },
    set(this: HTMLElement, value: boolean) {
      if (value) this.setAttribute("hidden", "");
      else this.removeAttribute("hidden");
    },
  });
}

export function setVisible(node: HTMLElement | null, visible: boolean): void {
  if (!node) return;
  if (visible) {
    node.removeAttribute("hidden");
    node.style.display = "";
  } else {
    node.setAttribute("hidden", "");
    node.style.display = "none";
  }
}

export function safeScrollIntoView(node: HTMLElement): void {
  try {
    node.scrollIntoView({ block: "nearest", inline: "nearest" });
  } catch {
    try {
      node.scrollIntoView(false);
    } catch {
      // ignore
    }
  }
}

/** Load Samsung webapis.js on demand (never block app boot). */
export function ensureWebapisLoaded(): Promise<void> {
  const global = globalThis as { webapis?: unknown };
  if (global.webapis) return Promise.resolve();

  return new Promise((resolve, reject) => {
    const existing = document.querySelector('script[data-leleg-webapis="1"]');
    if (existing) {
      existing.addEventListener("load", () => resolve());
      existing.addEventListener("error", () => reject(new Error("webapis.js non caricato")));
      return;
    }
    const script = document.createElement("script");
    script.type = "text/javascript";
    script.src = "$WEBAPIS/webapis/webapis.js";
    script.setAttribute("data-leleg-webapis", "1");
    script.onload = () => resolve();
    script.onerror = () => reject(new Error("webapis.js non disponibile"));
    document.head.appendChild(script);
  });
}
