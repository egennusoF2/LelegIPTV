import type { SeriesShow, VodMovie } from "./models";

export type CatalogSort = "recent" | "title" | "rating" | "recommended";

export const CATALOG_SORT_OPTIONS: ReadonlyArray<{
  value: CatalogSort;
  label: string;
}> = [
  { value: "recent", label: "Più recenti" },
  { value: "title", label: "Titolo A-Z" },
  { value: "rating", label: "Punteggio" },
  { value: "recommended", label: "Consigliati per te" },
];

type CatalogEntry = Pick<
  VodMovie | SeriesShow,
  "id" | "name" | "categoryId" | "genre" | "rating" | "added"
>;

function numericRating(value: string): number {
  const parsed = Number.parseFloat(value.replace(",", "."));
  return Number.isFinite(parsed) ? parsed : 0;
}

function words(value: string): Set<string> {
  return new Set(
    value
      .toLocaleLowerCase("it")
      .replace(/[^\p{L}\p{N}]+/gu, " ")
      .split(/\s+/)
      .filter((word) => word.length >= 3),
  );
}

function recommendationScore<T extends CatalogEntry>(
  item: T,
  favorites: T[],
  favoriteIds: Set<number>,
): number {
  if (!favorites.length) return item.added || item.id;
  const itemWords = words(`${item.genre} ${item.name}`);
  let score = favoriteIds.has(item.id) ? -1000 : 0;
  for (const favorite of favorites) {
    if (favorite.categoryId && favorite.categoryId === item.categoryId) score += 6;
    const favoriteWords = words(`${favorite.genre} ${favorite.name}`);
    for (const token of itemWords) {
      if (favoriteWords.has(token)) score += 2;
    }
  }
  return score + numericRating(item.rating) * 0.1;
}

export function sortCatalog<T extends CatalogEntry>(
  source: T[],
  mode: CatalogSort,
  favoriteIds: Set<number>,
): T[] {
  const items = source.slice();
  if (mode === "title") {
    return items.sort((a, b) =>
      a.name.localeCompare(b.name, "it", { sensitivity: "base" }),
    );
  }
  if (mode === "rating") {
    return items.sort(
      (a, b) =>
        numericRating(b.rating) - numericRating(a.rating) ||
        a.name.localeCompare(b.name, "it", { sensitivity: "base" }),
    );
  }
  if (mode === "recommended") {
    const favorites = source.filter((item) => favoriteIds.has(item.id));
    return items.sort(
      (a, b) =>
        recommendationScore(b, favorites, favoriteIds) -
          recommendationScore(a, favorites, favoriteIds) ||
        (b.added || b.id) - (a.added || a.id),
    );
  }
  return items.sort((a, b) => (b.added || b.id) - (a.added || a.id));
}
