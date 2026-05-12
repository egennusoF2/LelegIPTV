// @ts-nocheck - DOM-heavy module, typing pass deferred. The exported helpers
// have explicit types so call sites are still safe.
//
// Shared dialog-driven category picker used by Live TV, Movies, Series, and
// EPG. The four pages used to each carry ~250 lines of near-identical code -
// see `git log -- src/scripts/{stream,movies,series,epg}` if you need the
// pre-extraction versions.
import { t, LOCALE_EVENT } from "@/scripts/lib/i18n.js"
import { debounce } from "@/scripts/lib/debounce.js"
import { normalize } from "@/scripts/lib/text.js"
import { toast } from "@/scripts/lib/toast.js"
import { ICON_X } from "@/scripts/lib/icons.js"
import {
  getHiddenCategories,
  setCategoryHidden,
  getAllowedCategories,
  setCategoryAllowed,
  setAllowedCategories,
  getCategoryMode,
  setCategoryMode,
  getFavorites,
  getRecents,
  getSyncEpgWithLive,
  setSyncEpgWithLive,
  resolveEpgKind,
} from "@/scripts/lib/preferences.js"
import { attachDialogSpatialNav } from "@/scripts/lib/dialog-spatial-nav.js"

const CAT_FAVORITES = "__favorites__"
const CAT_RECENTS = "__recents__"

const EYE_OPEN_SVG =
  '<svg xmlns="http://www.w3.org/2000/svg" width="1em" height="1em" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2 12s3-7 10-7 10 7 10 7"/><circle cx="12" cy="12" r="3"/></svg>'

const CHECK_SVG =
  '<svg xmlns="http://www.w3.org/2000/svg" width="1em" height="1em" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="20 6 9 17 4 12"/></svg>'

export type PickerKind = "live" | "vod" | "series" | "epg"

export interface CategoryPickerItem {
  category?: string | null
}

export interface CategoryPickerOptions {
  /** Storage / preferences kind. Use "epg" for the schedule grid. */
  kind: PickerKind
  /**
   * Shared DOM-ID prefix for the trigger button, dialog, and dialog
   * internals. Example: "category-picker" -> "#category-picker-trigger",
   * "#category-picker-dialog", "#category-picker-list", ...
   */
  idPrefix: string
  /** localStorage key for the transient single-category drill-down. */
  activeCatStorageKey: string
  /** Custom event name to fire when the active drill-down changes. */
  activeCatChangedEvent: string
  /** Read-only accessor for the active playlist id. */
  getActivePlaylistId(): string
  /** Read-only accessor for the channel / movie / series items. */
  getItems(): CategoryPickerItem[]
  /**
   * The kind used to source favourites / recents pseudo-rows. EPG shows
   * Live TV favourites, so it overrides to "live"; the others default to
   * `kind`.
   */
  pseudoRowKind?: "live" | "vod" | "series"
  /** Fired after the picker writes a new active cat. */
  onActiveCatChange?(cat: string): void
  /**
   * Fired when the user toggles the EPG <-> Live TV sync checkbox. Only
   * relevant for kind === "epg".
   */
  onSyncToggle?(on: boolean): void
}

export interface CategoryPickerHandle {
  /** Re-render the picker list. Call after items change. */
  rerender(): void
  /** Refresh the favourites / recents pseudo-row counts. */
  refreshPseudoRows(): void
  /** Set the active drill-down category (without firing the change event). */
  setActiveCat(cat: string, opts?: { silent?: boolean }): void
  getActiveCat(): string
  /** The kind whose hide / allow / mode are currently being applied. */
  resolvedKind(): PickerKind
  hiddenCategories(): Set<string>
  allowedCategories(): Set<string>
  categoryMode(): "hide" | "select"
  /** True if a category passes the resolved hide / allow filter. */
  categoryPassesFilter(name: string): boolean
}

export function mountCategoryPicker(
  opts: CategoryPickerOptions
): CategoryPickerHandle {
  const pseudoKind = opts.pseudoRowKind || (opts.kind === "epg" ? "live" : opts.kind)

  const dialog = document.getElementById(
    `${opts.idPrefix}-dialog`
  ) as HTMLDialogElement | null
  const triggerEl = document.getElementById(`${opts.idPrefix}-trigger`)
  const labelEl = document.getElementById(`${opts.idPrefix}-label`)
  const closeBtn = document.getElementById(`${opts.idPrefix}-close`)
  const listEl = document.getElementById(`${opts.idPrefix}-list`)
  const statusEl = document.getElementById(`${opts.idPrefix}-list-status`)
  const searchEl = document.getElementById(
    `${opts.idPrefix}-search`
  ) as HTMLInputElement | null
  const modeHideBtn = document.getElementById(`${opts.idPrefix}-mode-hide`)
  const modeSelectBtn = document.getElementById(`${opts.idPrefix}-mode-select`)
  const selectActions = document.getElementById(`${opts.idPrefix}-select-actions`)
  const showSelectedBtn = document.getElementById(`${opts.idPrefix}-show-selected`)
  const selectAllBtn = document.getElementById(`${opts.idPrefix}-select-all`)
  const selectClearBtn = document.getElementById(`${opts.idPrefix}-select-clear`)
  const syncInput = document.getElementById(
    `${opts.idPrefix}-sync-input`
  ) as HTMLInputElement | null

  if (dialog) {
    attachDialogSpatialNav(dialog, { defaultElement: `#${opts.idPrefix}-search` })
  }

  let activeCat = ""
  try {
    activeCat = localStorage.getItem(opts.activeCatStorageKey) || ""
  } catch {}

  let showHidden = false
  let showSelectedOnly = false

  const resolvedKind = (): PickerKind => {
    if (opts.kind !== "epg") return opts.kind
    const pid = opts.getActivePlaylistId()
    return pid ? resolveEpgKind(pid) : "live"
  }

  const hiddenSet = (): Set<string> => {
    const pid = opts.getActivePlaylistId()
    return pid ? getHiddenCategories(pid, resolvedKind()) : new Set()
  }

  const allowedSet = (): Set<string> => {
    const pid = opts.getActivePlaylistId()
    return pid ? getAllowedCategories(pid, resolvedKind()) : new Set()
  }

  const categoryMode = (): "hide" | "select" => {
    const pid = opts.getActivePlaylistId()
    return pid ? getCategoryMode(pid, resolvedKind()) : "hide"
  }

  const categoryPassesFilter = (name: string): boolean => {
    const mode = categoryMode()
    if (mode === "select") {
      const allowed = allowedSet()
      if (allowed.size === 0) return true
      return allowed.has(name)
    }
    return !hiddenSet().has(name)
  }

  const computeCategoryCounts = (items: CategoryPickerItem[]): Map<string, number> => {
    const counts = new Map<string, number>()
    for (const item of items) {
      const key = ((item.category || "") + "").trim() || t("list.uncategorized")
      counts.set(key, (counts.get(key) || 0) + 1)
    }
    return counts
  }

  const syncLabel = (): void => {
    if (!labelEl) return
    labelEl.removeAttribute("data-i18n")
    if (activeCat === CAT_FAVORITES) {
      labelEl.setAttribute("data-i18n", "list.specialFavorites")
      labelEl.textContent = t("list.specialFavorites")
    } else if (activeCat === CAT_RECENTS) {
      labelEl.setAttribute("data-i18n", "list.specialRecents")
      labelEl.textContent = t("list.specialRecents")
    } else if (activeCat) {
      labelEl.textContent = activeCat
    } else {
      labelEl.setAttribute("data-i18n", "list.allCategories")
      labelEl.textContent = t("list.allCategories")
    }
  }

  const highlightActiveInList = (): void => {
    if (!listEl) return
    for (const el of Array.from(listEl.querySelectorAll('button[role="option"]'))) {
      const btn = el as HTMLElement
      btn.classList.toggle("bg-surface-2", (btn.dataset.val || "") === activeCat)
    }
  }

  const setActiveCat = (next: string, options: { silent?: boolean } = {}): void => {
    const cleaned = next || ""
    if (cleaned === activeCat) {
      syncLabel()
      highlightActiveInList()
      return
    }
    activeCat = cleaned
    try {
      if (activeCat) localStorage.setItem(opts.activeCatStorageKey, activeCat)
      else localStorage.removeItem(opts.activeCatStorageKey)
    } catch {}
    syncLabel()
    highlightActiveInList()
    if (!options.silent) {
      document.dispatchEvent(
        new CustomEvent(opts.activeCatChangedEvent, { detail: activeCat })
      )
      opts.onActiveCatChange?.(activeCat)
    }
  }

  const addRow = (
    val: string,
    label: string,
    count: number | null,
    extraClass: string,
    rowOpts: {
      hideAction?: "hide" | "unhide"
      selectAction?: boolean
      selectChecked?: boolean
      dim?: boolean
    } = {}
  ): HTMLButtonElement => {
    const btn = document.createElement("button")
    btn.type = "button"
    btn.setAttribute("role", "option")
    btn.dataset.val = val
    btn.className =
      "group/cat relative w-full py-2 px-2 text-sm flex items-center justify-between hover:bg-surface-2 focus:bg-surface-2 outline-none text-fg" +
      (extraClass ? " " + extraClass : "") +
      (rowOpts.dim ? " opacity-60" : "")

    const left = document.createElement("span")
    left.className = "truncate"
    left.textContent = label
    btn.appendChild(left)

    const right = document.createElement("span")
    right.className = "ml-3 shrink-0 flex items-center gap-1.5"

    let rightAction: HTMLButtonElement | null = null
    if (rowOpts.hideAction === "hide" || rowOpts.hideAction === "unhide") {
      rightAction = document.createElement("button")
      rightAction.type = "button"
      rightAction.tabIndex = 0
      rightAction.className =
        "category-hide-btn shrink-0 size-6 inline-flex items-center justify-center rounded-md text-fg-3 hover:text-fg hover:bg-surface-3 focus-visible:bg-surface-3 focus-visible:text-fg outline-none opacity-0 group-hover/cat:opacity-100 group-focus-within/cat:opacity-100 focus-visible:opacity-100 transition-opacity"
      rightAction.setAttribute(
        "aria-label",
        rowOpts.hideAction === "hide"
          ? `Hide category "${label}"`
          : `Unhide category "${label}"`
      )
      rightAction.title =
        rowOpts.hideAction === "hide"
          ? t("list.hideCategory")
          : t("list.unhideCategory")
      rightAction.innerHTML = rowOpts.hideAction === "hide" ? ICON_X : EYE_OPEN_SVG
      rightAction.addEventListener("click", (ev) => {
        ev.stopPropagation()
        ev.preventDefault()
        const pid = opts.getActivePlaylistId()
        if (!pid) return
        const willHide = rowOpts.hideAction === "hide"
        setCategoryHidden(pid, resolvedKind(), val, willHide)
        if (willHide) {
          toast({
            title: t("list.toast.hidCategory", { label }),
            description: t("stream.toast.hiddenInSettings"),
            duration: 4000,
          })
          if (activeCat === val) setActiveCat("")
        }
      })
    } else if (rowOpts.selectAction) {
      const checked = !!rowOpts.selectChecked
      rightAction = document.createElement("button")
      rightAction.type = "button"
      rightAction.tabIndex = 0
      rightAction.setAttribute("role", "checkbox")
      rightAction.setAttribute("aria-checked", String(checked))
      rightAction.setAttribute(
        "aria-label",
        checked
          ? `Remove "${label}" from shown categories`
          : `Show only checked categories - include "${label}"`
      )
      rightAction.title = checked ? "Showing this category" : "Show this category"
      rightAction.className =
        "category-select-btn shrink-0 size-6 inline-flex items-center justify-center rounded-md " +
        "border outline-none transition-colors focus-visible:ring-2 focus-visible:ring-accent " +
        (checked
          ? "bg-accent border-accent text-bg"
          : "border-line text-fg-3 hover:text-fg hover:border-fg-3 focus-visible:border-fg-3")
      rightAction.innerHTML = checked ? CHECK_SVG : ""
      rightAction.addEventListener("click", (ev) => {
        ev.stopPropagation()
        ev.preventDefault()
        const pid = opts.getActivePlaylistId()
        if (!pid) return
        setCategoryAllowed(pid, resolvedKind(), val, !checked)
      })
    }

    const countEl = document.createElement("span")
    countEl.className =
      "category-count text-xs text-fg-3 tabular-nums min-w-8 text-right"
    countEl.textContent = count != null ? String(count) : ""
    right.appendChild(countEl)

    if (rightAction) {
      right.appendChild(rightAction)
    } else {
      const spacer = document.createElement("span")
      spacer.className = "shrink-0 size-6"
      spacer.setAttribute("aria-hidden", "true")
      right.appendChild(spacer)
    }

    btn.appendChild(right)
    btn.addEventListener("click", () => {
      setActiveCat(val)
    })
    return btn
  }

  const renderList = (): void => {
    if (!listEl) return
    const items = opts.getItems()
    const counts = computeCategoryCounts(items)
    const names = Array.from(counts.keys()).sort((a, b) =>
      a.localeCompare(b, "en", { sensitivity: "base" })
    )
    const mode = categoryMode()
    const hidden = hiddenSet()
    const allowed = allowedSet()
    const visibleNames =
      mode === "hide" ? names.filter((name) => !hidden.has(name)) : names
    const hiddenNames =
      mode === "hide" ? names.filter((name) => hidden.has(name)) : []

    const frag = document.createDocumentFragment()
    const pid = opts.getActivePlaylistId()

    const favs = pid ? getFavorites(pid, pseudoKind) : new Set<number>()
    const recs = pid ? getRecents(pid, pseudoKind) : []

    const favRow = addRow(CAT_FAVORITES, "★ Favorites", favs.size, "text-accent")
    if (favs.size === 0) favRow.style.display = "none"
    frag.appendChild(favRow)

    const recRow = addRow(CAT_RECENTS, "🕒 Recently watched", recs.length, "")
    if (recs.length === 0) recRow.style.display = "none"
    frag.appendChild(recRow)

    frag.appendChild(addRow("", t("list.allCategories"), null, ""))

    if (mode === "select") {
      for (const name of visibleNames) {
        frag.appendChild(
          addRow(name, name, counts.get(name) || 0, "", {
            selectAction: true,
            selectChecked: allowed.has(name),
          })
        )
      }
    } else {
      for (const name of visibleNames) {
        frag.appendChild(
          addRow(name, name, counts.get(name) || 0, "", { hideAction: "hide" })
        )
      }
    }

    if (hiddenNames.length) {
      const toggle = document.createElement("button")
      toggle.type = "button"
      toggle.className =
        "w-full px-2 py-2 text-xs text-fg-3 hover:text-fg hover:bg-surface-2 focus:bg-surface-2 outline-none flex items-center justify-between"
      toggle.innerHTML =
        `<span class="truncate">${showHidden ? "Hide" : "Show"} ${hiddenNames.length} hidden ${hiddenNames.length === 1 ? "category" : "categories"}</span>` +
        `<span class="ml-3 shrink-0 tabular-nums">${showHidden ? "▴" : "▾"}</span>`
      toggle.addEventListener("click", () => {
        showHidden = !showHidden
        renderList()
      })
      frag.appendChild(toggle)
      if (showHidden) {
        for (const name of hiddenNames) {
          frag.appendChild(
            addRow(name, name, counts.get(name) || 0, "", {
              hideAction: "unhide",
              dim: true,
            })
          )
        }
      }
    }

    listEl.replaceChildren(frag)

    if (statusEl) {
      if (mode === "select") {
        const totalCats = names.length
        const pickedCount = names.reduce(
          (acc, name) => (allowed.has(name) ? acc + 1 : acc),
          0
        )
        statusEl.textContent =
          pickedCount === 0
            ? `Tick categories to include - ${totalCats.toLocaleString()} total`
            : `Showing ${pickedCount.toLocaleString()} of ${totalCats.toLocaleString()} categories`
      } else {
        const total = visibleNames.length
        statusEl.textContent =
          `${total.toLocaleString()} ${total === 1 ? "category" : "categories"}` +
          (hiddenNames.length ? ` · ${hiddenNames.length} hidden` : "")
      }
    }

    highlightActiveInList()
    filterCategories()
  }

  const filterCategories = (): void => {
    if (!listEl || !statusEl || !searchEl) return
    const qnorm = normalize(searchEl.value || "")
    const tokens = qnorm.length ? qnorm.split(" ") : []
    const mode = categoryMode()
    const allowed = mode === "select" ? allowedSet() : null
    const filterToSelected = mode === "select" && showSelectedOnly

    let visibleCount = 0
    let totalCount = 0

    for (const el of Array.from(
      listEl.querySelectorAll('button[role="option"]')
    )) {
      const btn = el as HTMLElement
      const val = btn.dataset.val || ""
      const isPseudo = val.startsWith("__")
      const isAllButton = val === ""
      const isRegularRow = !isAllButton && !isPseudo
      if (isRegularRow) totalCount++
      const label = normalize(val || btn.textContent || "")
      const searchMatches =
        !tokens.length || tokens.every((token) => label.includes(token))
      let show = searchMatches
      if (show && filterToSelected && isRegularRow) {
        show = !!allowed && allowed.has(val)
      }
      btn.style.display = show ? "" : "none"
      if (show && isRegularRow) visibleCount++
    }

    if (mode === "select") {
      const pickedCount = allowed ? allowed.size : 0
      statusEl.textContent = filterToSelected
        ? `${visibleCount.toLocaleString()} of ${pickedCount.toLocaleString()} selected (filtered)`
        : pickedCount === 0
          ? `Tick categories to include - ${totalCount.toLocaleString()} total`
          : `${pickedCount.toLocaleString()} of ${totalCount.toLocaleString()} selected`
    } else {
      statusEl.textContent = `${visibleCount.toLocaleString()} of ${totalCount.toLocaleString()} categories`
    }
  }

  const syncModeToggle = (): void => {
    const mode = categoryMode()
    modeHideBtn?.setAttribute("aria-checked", String(mode === "hide"))
    modeSelectBtn?.setAttribute("aria-checked", String(mode === "select"))
    if (selectActions) {
      if (mode === "select") selectActions.removeAttribute("hidden")
      else selectActions.setAttribute("hidden", "")
    }
    if (mode !== "select" && showSelectedOnly) {
      showSelectedOnly = false
      showSelectedBtn?.setAttribute("aria-pressed", "false")
    }
  }

  const refreshPseudoRows = (): void => {
    if (!listEl) return
    const pid = opts.getActivePlaylistId()
    if (!pid) return
    const favs = getFavorites(pid, pseudoKind)
    const recs = getRecents(pid, pseudoKind)
    for (const [val, count] of [
      [CAT_FAVORITES, favs.size],
      [CAT_RECENTS, recs.length],
    ] as Array<[string, number]>) {
      const btn = listEl.querySelector(
        `button[role="option"][data-val="${val}"]`
      ) as HTMLElement | null
      if (!btn) continue
      const countEl = btn.querySelector(".category-count")
      if (countEl) countEl.textContent = String(count)
      btn.style.display = count > 0 ? "" : "none"
    }
  }

  // Mode buttons
  const onModeClick = (event: Event): void => {
    const target = event.currentTarget as HTMLElement
    const mode = target?.dataset?.mode
    const pid = opts.getActivePlaylistId()
    if (!pid || (mode !== "hide" && mode !== "select")) return
    setCategoryMode(pid, resolvedKind(), mode)
  }
  modeHideBtn?.addEventListener("click", onModeClick)
  modeSelectBtn?.addEventListener("click", onModeClick)

  showSelectedBtn?.addEventListener("click", () => {
    showSelectedOnly = !showSelectedOnly
    showSelectedBtn.setAttribute("aria-pressed", String(showSelectedOnly))
    filterCategories()
  })

  selectAllBtn?.addEventListener("click", () => {
    const pid = opts.getActivePlaylistId()
    if (!pid || !listEl) return
    const allowed = new Set(allowedSet())
    for (const el of Array.from(
      listEl.querySelectorAll('button[role="option"]')
    )) {
      const btn = el as HTMLElement
      const val = btn.dataset?.val
      if (!val) continue
      if (val.startsWith("__")) continue
      if (btn.style.display === "none") continue
      allowed.add(val)
    }
    setAllowedCategories(pid, resolvedKind(), allowed)
  })

  selectClearBtn?.addEventListener("click", () => {
    const pid = opts.getActivePlaylistId()
    if (!pid) return
    setAllowedCategories(pid, resolvedKind(), [])
  })

  searchEl?.addEventListener("input", debounce(filterCategories, 120))

  // Sync-with-Live toggle (EPG only). Reflect current state on mount so the
  // checkbox doesn't show a hardcoded "checked".
  if (syncInput && opts.kind === "epg") {
    const reflectSync = (): void => {
      const pid = opts.getActivePlaylistId()
      syncInput.checked = pid ? getSyncEpgWithLive(pid) : true
    }
    reflectSync()
    syncInput.addEventListener("change", () => {
      const pid = opts.getActivePlaylistId()
      if (!pid) return
      setSyncEpgWithLive(pid, syncInput.checked)
      opts.onSyncToggle?.(syncInput.checked)
    })
    document.addEventListener("xt:epg-sync-changed", (event: Event) => {
      const detail = (event as CustomEvent).detail
      if (!detail || detail.playlistId !== opts.getActivePlaylistId()) return
      syncInput.checked = !!detail.on
      syncModeToggle()
      renderList()
    })
    document.addEventListener("xt:active-changed", () => {
      reflectSync()
      syncModeToggle()
      renderList()
    })
  }

  const onAnyPrefChange = (event: Event): void => {
    const detail = (event as CustomEvent).detail
    if (!detail) return
    if (detail.playlistId !== opts.getActivePlaylistId()) return
    const targetKind = resolvedKind()
    if (detail.kind !== targetKind) return
    syncModeToggle()
    renderList()
  }
  document.addEventListener("xt:hidden-categories-changed", onAnyPrefChange)
  document.addEventListener("xt:allowed-categories-changed", onAnyPrefChange)
  document.addEventListener("xt:category-mode-changed", onAnyPrefChange)

  triggerEl?.addEventListener("click", () => {
    if (!dialog) return
    if (typeof dialog.showModal === "function") dialog.showModal()
    else dialog.setAttribute("open", "")
    setTimeout(() => {
      ;(window as any).SpatialNavigation?.makeFocusable?.()
      searchEl?.focus()
      searchEl?.select?.()
    }, 0)
  })

  closeBtn?.addEventListener("click", () => dialog?.close?.())

  listEl?.addEventListener("click", (event: Event) => {
    const target = event.target as HTMLElement
    if (!target.closest("button[role='option']")) return
    queueMicrotask(() => {
      if (dialog?.open) dialog.close()
    })
  })

  dialog?.addEventListener("click", (event: Event) => {
    if (event.target === dialog) dialog.close()
  })

  dialog?.addEventListener("close", () => {
    syncLabel()
    if (searchEl) {
      searchEl.value = ""
      filterCategories()
    }
    triggerEl?.focus()
  })

  document.addEventListener(LOCALE_EVENT, syncLabel)
  document.addEventListener(opts.activeCatChangedEvent, (event: Event) => {
    const next = ((event as CustomEvent).detail || "") as string
    if (next === activeCat) return
    setActiveCat(next, { silent: true })
  })

  // Initial paint
  syncModeToggle()
  syncLabel()

  return {
    rerender: () => {
      syncModeToggle()
      renderList()
    },
    refreshPseudoRows,
    setActiveCat,
    getActiveCat: () => activeCat,
    resolvedKind,
    hiddenCategories: hiddenSet,
    allowedCategories: allowedSet,
    categoryMode,
    categoryPassesFilter,
  }
}
