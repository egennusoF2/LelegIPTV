import { safeScrollIntoView } from "../polyfills";

export type FocusDirection = "up" | "down" | "left" | "right";

export interface FocusableElement {
  el: HTMLElement;
  onActivate?: () => void;
  onLeft?: () => boolean;
  onRight?: () => boolean;
  onUp?: () => boolean;
  onDown?: () => boolean;
}

export class FocusManager {
  private items: FocusableElement[] = [];
  private index = 0;

  setItems(items: FocusableElement[]): void {
    this.items = items;
    if (this.index >= this.items.length) this.index = Math.max(0, this.items.length - 1);
    this.applyFocus();
  }

  focusIndex(index: number): void {
    if (!this.items.length) return;
    this.index = Math.max(0, Math.min(index, this.items.length - 1));
    this.applyFocus();
  }

  current(): FocusableElement | null {
    return this.items[this.index] ?? null;
  }

  move(direction: FocusDirection): boolean {
    const item = this.items[this.index];
    if (!item) return false;
    const handled =
      direction === "left"
        ? item.onLeft?.()
        : direction === "right"
          ? item.onRight?.()
          : direction === "up"
            ? item.onUp?.()
            : item.onDown?.();
    if (handled) return true;

    const delta =
      direction === "up" || direction === "left" ? -1 : 1;
    const next = this.index + delta;
    if (next < 0 || next >= this.items.length) return false;
    this.index = next;
    this.applyFocus();
    return true;
  }

  activate(): boolean {
    const item = this.items[this.index];
    if (!item?.onActivate) return false;
    item.onActivate();
    return true;
  }

  private applyFocus(): void {
    for (const item of this.items) {
      item.el.classList.remove("focused");
      item.el.setAttribute("aria-selected", "false");
    }
    const current = this.items[this.index];
    if (!current) return;
    current.el.classList.add("focused");
    current.el.setAttribute("aria-selected", "true");
    safeScrollIntoView(current.el);
  }
}

export function registerTvKeys(): void {
  const keys = [
    "MediaPlay",
    "MediaPause",
    "MediaPlayPause",
    "MediaStop",
    "MediaFastForward",
    "MediaRewind",
  ];
  try {
    const batch = (globalThis as { tizen?: { tvinputdevice?: { registerKeyBatch?: (k: string[]) => void } } }).tizen
      ?.tvinputdevice?.registerKeyBatch;
    batch?.(keys);
  } catch {
    // Browser dev mode.
  }
}

export function mapKeyToDirection(key: string): FocusDirection | "activate" | "back" | null {
  switch (key) {
    case "ArrowUp":
      return "up";
    case "ArrowDown":
      return "down";
    case "ArrowLeft":
      return "left";
    case "ArrowRight":
      return "right";
    case "Enter":
    case " ":
      return "activate";
    case "Escape":
    case "Backspace":
      return "back";
    default:
      return null;
  }
}
