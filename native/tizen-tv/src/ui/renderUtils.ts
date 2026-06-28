import type { FocusableElement } from "../app/focusManager";
import type { LiveChannel, VodMovie } from "../data/models";
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
  container.replaceChildren();
  if (!channels.length) {
    container.append(el("div", "empty", "Nessun canale in questa categoria."));
    return [];
  }
  return channels.map((channel, index) => {
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
      onUp: () => index > 0,
      onDown: () => index < channels.length - 1,
    } satisfies FocusableElement;
  });
}

export function renderEpgList(container: HTMLElement, programmes: { title: string; start: string }[]): void {
  container.replaceChildren();
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
): FocusableElement[] {
  container.replaceChildren();
  const row = el("div", "poster-row");
  container.append(row);
  if (!movies.length) {
    row.append(el("div", "empty", "Nessun titolo in questa categoria."));
    return [];
  }
  return movies.slice(0, 40).map((movie, index) => {
    const card = el("div", "poster-card focusable");
    const img = document.createElement("img");
    img.src = movie.logo || "";
    img.alt = movie.name;
    card.append(img, el("div", "title", movie.name));
    return {
      el: card,
      onActivate: () => onSelect(movie),
      onLeft: () => index > 0,
      onRight: () => index < Math.min(movies.length, 40) - 1,
    } satisfies FocusableElement;
  });
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
