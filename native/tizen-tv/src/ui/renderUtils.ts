import type { FocusableElement } from "../app/focusManager";
import type { LiveChannel, SeriesShow, VodMovie } from "../data/models";
import { liveUrl, movieUrl } from "../data/models";
import type { CatalogState } from "../state/catalogState";

export function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  className?: string,
  text?: string,
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

/** Tizen WebKit spesso non ha Element.replaceChildren (Chrome 86+). */
export function clearElement(node: Element): void {
  while (node.firstChild) {
    node.removeChild(node.firstChild);
  }
}

export function setElementChildren(node: Element, children: Node[]): void {
  clearElement(node);
  for (const child of children) {
    node.appendChild(child);
  }
}

export function pageHeader(eyebrow: string, title: string): HTMLElement {
  const wrap = el("div");
  wrap.append(el("p", "page-eyebrow", eyebrow), el("h1", "page-title", title));
  return wrap;
}

export function renderChannelList(
  container: HTMLElement,
  channels: LiveChannel[],
  selectedId: number | null,
  onSelect: (channel: LiveChannel) => void,
): FocusableElement[] {
  clearElement(container);
  if (!channels.length) {
    container.append(el("div", "empty", "Nessun canale in questa categoria."));
    return [];
  }
  return channels.map((channel) => {
    const row = el("div", "list-item focusable");
    if (channel.id === selectedId) row.classList.add("active");
    if (channel.logo) {
      const img = document.createElement("img");
      img.src = channel.logo;
      img.alt = "";
      row.append(img);
    }
    const textWrap = el("div");
    textWrap.append(el("div", "name", channel.name));
    row.append(textWrap);
    return {
      el: row,
      onActivate: () => onSelect(channel),
    } satisfies FocusableElement;
  });
}

export function renderEpgList(container: HTMLElement, programmes: { title: string; start: string }[]): void {
  clearElement(container);
  if (!programmes.length) {
    container.append(el("div", "empty", "EPG non disponibile."));
    return;
  }
  for (const item of programmes) {
    const row = el("div", "list-item");
    const textWrap = el("div");
    textWrap.append(el("div", "name", item.title), el("div", "meta", item.start));
    row.append(textWrap);
    container.append(row);
  }
}

export function formatEpgTime(ms: number): string {
  return new Date(ms).toLocaleString("it-IT", {
    day: "2-digit",
    month: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function renderPosterRow(
  container: HTMLElement,
  movies: VodMovie[],
  onSelect: (movie: VodMovie) => void,
  onItemsChanged?: (items: FocusableElement[], startIndex: number) => void,
): FocusableElement[] {
  clearElement(container);
  const grid = el("div", "poster-grid");
  container.append(grid);
  if (!movies.length) {
    grid.append(el("div", "empty", "Nessun titolo in questa categoria."));
    return [];
  }
  const items: FocusableElement[] = [];
  let rendered = 0;
  const appendBatch = (): void => {
    const startIndex = rendered;
    const end = Math.min(movies.length, rendered + 12);
    for (let index = rendered; index < end; index += 1) {
      const movie = movies[index]!;
      const card = createPosterCard(
        movie.name,
        movie.logo,
        [movie.year, movie.rating].filter(Boolean).join(" · "),
      );
      const item: FocusableElement = {
        el: card,
        onActivate: () => onSelect(movie),
        onFocus: () => {
          if (index >= rendered - 4 && rendered < movies.length) {
            appendBatch();
          }
        },
      };
      items.push(item);
      grid.append(card);
    }
    rendered = end;
    if (startIndex > 0) onItemsChanged?.(items, startIndex);
  };
  appendBatch();
  return items;
}

export function renderSeriesPosterRow(
  container: HTMLElement,
  shows: SeriesShow[],
  onSelect: (show: SeriesShow) => void,
  onItemsChanged?: (items: FocusableElement[], startIndex: number) => void,
): FocusableElement[] {
  clearElement(container);
  const grid = el("div", "poster-grid");
  container.append(grid);
  if (!shows.length) {
    grid.append(el("div", "empty", "Nessuna serie in questa categoria."));
    return [];
  }
  const items: FocusableElement[] = [];
  let rendered = 0;
  const appendBatch = (): void => {
    const startIndex = rendered;
    const end = Math.min(shows.length, rendered + 12);
    for (let index = rendered; index < end; index += 1) {
      const show = shows[index]!;
      const card = createPosterCard(
        show.name,
        show.logo,
        [show.year, show.rating].filter(Boolean).join(" · "),
      );
      const item: FocusableElement = {
        el: card,
        onActivate: () => onSelect(show),
        onFocus: () => {
          if (index >= rendered - 4 && rendered < shows.length) {
            appendBatch();
          }
        },
      };
      items.push(item);
      grid.append(card);
    }
    rendered = end;
    if (startIndex > 0) onItemsChanged?.(items, startIndex);
  };
  appendBatch();
  return items;
}

function createPosterCard(
  title: string,
  imageUrl: string,
  subtitle: string,
): HTMLElement {
  const card = el("div", "poster-card focusable");
  card.tabIndex = -1;
  const image = document.createElement("img");
  image.src = imageUrl || "";
  image.alt = title;
  image.loading = "lazy";
  image.decoding = "async";
  const overlay = el("div", "poster-copy");
  overlay.append(el("div", "title", title));
  if (subtitle) overlay.append(el("div", "meta", subtitle));
  card.append(image, overlay);
  return card;
}

export function playbackUrlForChannel(catalog: CatalogState, channel: LiveChannel): string | null {
  const profile = catalog.activeProfile;
  if (!profile) return null;
  return liveUrl(profile, channel.id);
}

export function playbackUrlForMovie(catalog: CatalogState, movie: VodMovie): string | null {
  const profile = catalog.activeProfile;
  if (!profile) return null;
  return movieUrl(profile, movie.id, movie.containerExtension);
}
