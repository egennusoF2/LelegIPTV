import type { FocusDirection } from "./focusManager";
import { safeScrollIntoView } from "../polyfills";
import type { FocusableElement } from "./focusManager";

/** Focus per colonne (categorie | canali) con navigazione left/right tra zone. */
export class ColumnFocusManager {
  private columns: FocusableElement[][] = [];
  private col = 0;
  private row = 0;

  setColumns(columns: FocusableElement[][]): void {
    this.columns = columns.filter((c) => c.length > 0);
    if (this.col >= this.columns.length) this.col = Math.max(0, this.columns.length - 1);
    if (this.row >= (this.columns[this.col]?.length ?? 0)) {
      this.row = Math.max(0, (this.columns[this.col]?.length ?? 1) - 1);
    }
    this.applyFocus();
  }

  focusColumn(col: number, row = 0): void {
    if (!this.columns.length) return;
    this.col = Math.max(0, Math.min(col, this.columns.length - 1));
    const items = this.columns[this.col] ?? [];
    this.row = Math.max(0, Math.min(row, Math.max(0, items.length - 1)));
    this.applyFocus();
  }

  current(): FocusableElement | null {
    return this.columns[this.col]?.[this.row] ?? null;
  }

  move(direction: FocusDirection): boolean {
    const items = this.columns[this.col];
    if (!items?.length) return false;

    if (direction === "left") {
      if (this.col <= 0) return false;
      this.col -= 1;
      this.row = Math.min(this.row, Math.max(0, (this.columns[this.col]?.length ?? 1) - 1));
      this.applyFocus();
      return true;
    }
    if (direction === "right") {
      if (this.col >= this.columns.length - 1) return false;
      this.col += 1;
      this.row = Math.min(this.row, Math.max(0, (this.columns[this.col]?.length ?? 1) - 1));
      this.applyFocus();
      return true;
    }

    const delta = direction === "up" ? -1 : 1;
    const next = this.row + delta;
    if (next < 0 || next >= items.length) return false;
    this.row = next;
    this.applyFocus();
    return true;
  }

  activate(): boolean {
    const item = this.current();
    if (!item?.onActivate) return false;
    item.onActivate();
    return true;
  }

  private applyFocus(): void {
    for (const column of this.columns) {
      for (const item of column) {
        item.el.classList.remove("focused");
        item.el.setAttribute("aria-selected", "false");
      }
    }
    const current = this.current();
    if (!current) return;
    current.el.classList.add("focused");
    current.el.setAttribute("aria-selected", "true");
    safeScrollIntoView(current.el);
  }
}
