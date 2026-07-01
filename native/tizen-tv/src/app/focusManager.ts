import { safeScrollIntoView } from "../polyfills";

export type FocusDirection = "up" | "down" | "left" | "right";

export type TvKeyAction = FocusDirection | "activate" | "back" | "play_pause";

export interface FocusableElement {
  el: HTMLElement;
  onActivate?: () => void;
  onFocus?: () => void;
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

  focusCurrent(): void {
    this.applyFocus();
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

    const origin = item.el.getBoundingClientRect();
    const originX = origin.left + origin.width / 2;
    const originY = origin.top + origin.height / 2;
    let next = -1;
    let bestScore = Number.POSITIVE_INFINITY;

    for (let index = 0; index < this.items.length; index += 1) {
      if (index === this.index) continue;
      const rect = this.items[index]!.el.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) continue;
      const x = rect.left + rect.width / 2;
      const y = rect.top + rect.height / 2;
      const dx = x - originX;
      const dy = y - originY;
      const inDirection =
        direction === "left"
          ? dx < -1
          : direction === "right"
            ? dx > 1
            : direction === "up"
              ? dy < -1
              : dy > 1;
      if (!inDirection) continue;

      const primary = direction === "left" || direction === "right" ? Math.abs(dx) : Math.abs(dy);
      const secondary = direction === "left" || direction === "right" ? Math.abs(dy) : Math.abs(dx);
      const score = primary + secondary * 2.5;
      if (score < bestScore) {
        bestScore = score;
        next = index;
      }
    }

    if (next < 0) return false;
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
    try {
      current.el.focus({ preventScroll: true });
    } catch {
      current.el.focus();
    }
    safeScrollIntoView(current.el);
    current.onFocus?.();
  }
}

const NAV_KEYS = [
  "ArrowUp",
  "ArrowDown",
  "ArrowLeft",
  "ArrowRight",
  "Enter",
  "Return",
] as const;

const MEDIA_KEYS = [
  "MediaPlay",
  "MediaPause",
  "MediaPlayPause",
  "MediaStop",
  "MediaFastForward",
  "MediaRewind",
] as const;

type TizenInputDevice = {
  registerKey?: (key: string) => void;
  registerKeyBatch?: (keys: string[]) => void;
};

export function registerTvKeys(): void {
  const input = (globalThis as { tizen?: { tvinputdevice?: TizenInputDevice } }).tizen?.tvinputdevice;
  if (!input) return;

  const keys = [...NAV_KEYS, ...MEDIA_KEYS];
  try {
    if (input.registerKeyBatch) {
      input.registerKeyBatch([...keys]);
      return;
    }
    if (input.registerKey) {
      for (const key of keys) {
        try {
          input.registerKey(key);
        } catch {
          // Some keys may be unsupported on older firmware.
        }
      }
    }
  } catch {
    // Browser dev mode.
  }
}

export function mapKeyToDirection(key: string): TvKeyAction | null {
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
    case "GoBack":
    case "XF86Back":
      return "back";
    case "MediaPlay":
    case "MediaPause":
    case "MediaPlayPause":
      return "play_pause";
    default:
      return null;
  }
}

/** Samsung Tizen remote often reports keyCode without a usable event.key. */
export function mapKeyFromEvent(event: KeyboardEvent): TvKeyAction | null {
  const fromKey = mapKeyToDirection(event.key);
  if (fromKey) return fromKey;

  switch (event.keyCode) {
    case 38:
      return "up";
    case 40:
      return "down";
    case 37:
      return "left";
    case 39:
      return "right";
    case 13:
      return "activate";
    case 10009: // Return (Tizen Back)
    case 461: // Back on some Samsung models
    case 8: // Backspace on some remotes
      return "back";
    case 415: // MediaPlay
    case 19: // MediaPause
    case 10252: // MediaPlayPause
    case 179: // Play/pause (alternate)
      return "play_pause";
    default:
      return null;
  }
}
