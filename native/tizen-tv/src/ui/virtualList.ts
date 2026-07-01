import { clearElement, el } from "./renderUtils";

export interface VirtualListOptions {
  rowHeight?: number;
  visibleRows?: number;
  emptyLabel?: string;
}

export class VirtualList<T> {
  private viewport: HTMLElement;
  private items: T[] = [];
  private labels: (item: T) => string;
  private logos: ((item: T) => string | undefined) | undefined;
  private focusIndex = 0;
  private scrollIndex = 0;
  private rowHeight: number;
  private visibleRows: number;
  private emptyLabel: string;
  private onFocusChange?: (item: T, index: number) => void;
  private onActivate?: (item: T, index: number) => void;
  private highlight: ((item: T) => boolean) | undefined;
  private isActive = false;

  readonly element: HTMLElement;

  constructor(
    labelFn: (item: T) => string,
    options: VirtualListOptions = {},
    logoFn?: (item: T) => string | undefined,
    highlightFn?: (item: T) => boolean,
  ) {
    this.labels = labelFn;
    this.logos = logoFn;
    this.highlight = highlightFn;
    this.rowHeight = options.rowHeight ?? 58;
    this.visibleRows = options.visibleRows ?? 14;
    this.emptyLabel = options.emptyLabel ?? "Nessun elemento";
    this.element = el("div", "virtual-list panel");
    this.viewport = el("div", "virtual-list-viewport");
    this.element.append(this.viewport);
    this.element.style.setProperty("--row-height", `${this.rowHeight}px`);
    this.element.style.setProperty("--visible-rows", String(this.visibleRows));
  }

  setHandlers(handlers: {
    onFocusChange?: (item: T, index: number) => void;
    onActivate?: (item: T, index: number) => void;
  }): void {
    this.onFocusChange = handlers.onFocusChange;
    this.onActivate = handlers.onActivate;
  }

  setItems(items: T[], focusIndex = 0, notifyFocus = false): void {
    this.items = items;
    this.focusIndex = items.length ? Math.max(0, Math.min(focusIndex, items.length - 1)) : 0;
    this.scrollIndex = this.computeScrollFor(this.focusIndex);
    this.paint();
    if (notifyFocus && items.length && this.isActive) {
      this.onFocusChange?.(items[this.focusIndex]!, this.focusIndex);
    }
  }

  get length(): number {
    return this.items.length;
  }

  get index(): number {
    return this.focusIndex;
  }

  setActive(active: boolean): void {
    this.isActive = active;
    this.element.classList.toggle("virtual-list-active", active);
    this.paint();
  }

  current(): T | null {
    return this.items[this.focusIndex] ?? null;
  }

  move(delta: -1 | 1): boolean {
    if (!this.items.length) return false;
    const next = this.focusIndex + delta;
    if (next < 0 || next >= this.items.length) return false;
    this.focusIndex = next;
    this.scrollIndex = this.computeScrollFor(this.focusIndex);
    this.paint();
    this.onFocusChange?.(this.items[this.focusIndex]!, this.focusIndex);
    return true;
  }

  activate(): boolean {
    const item = this.current();
    if (!item || !this.onActivate) return false;
    this.onActivate(item, this.focusIndex);
    return true;
  }

  private computeScrollFor(index: number): number {
    const maxScroll = Math.max(0, this.items.length - this.visibleRows);
    const centered = index - Math.floor(this.visibleRows / 2);
    return Math.max(0, Math.min(centered, maxScroll));
  }

  private paint(): void {
    clearElement(this.viewport);
    if (!this.items.length) {
      this.viewport.append(el("div", "empty", this.emptyLabel));
      return;
    }

    const slice = this.items.slice(this.scrollIndex, this.scrollIndex + this.visibleRows);
    for (let i = 0; i < slice.length; i += 1) {
      const absolute = this.scrollIndex + i;
      const item = slice[i]!;
      const row = el("div", "list-item virtual-row");
      if (this.isActive && absolute === this.focusIndex) row.classList.add("focused");
      if (this.highlight?.(item)) row.classList.add("active");
      const logo = this.logos?.(item);
      if (logo) {
        const img = document.createElement("img");
        img.src = logo;
        img.alt = "";
        row.append(img);
      }
      row.append(el("div", "name", this.labels(item)));
      this.viewport.append(row);
    }
  }
}
