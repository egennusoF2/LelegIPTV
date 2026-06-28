import type { CatalogSnapshot, XtreamProfile } from "./models";
import { CATALOG_TTL_MS } from "./models";

const PROFILE_KEY = "leleg.tizen.profile";
const CATALOG_KEY = "leleg.tizen.catalog";

export function loadProfile(): XtreamProfile | null {
  try {
    const raw = localStorage.getItem(PROFILE_KEY);
    if (!raw) return null;
    return JSON.parse(raw) as XtreamProfile;
  } catch {
    return null;
  }
}

export function saveProfile(profile: XtreamProfile): void {
  localStorage.setItem(PROFILE_KEY, JSON.stringify(profile));
}

export function clearProfile(): void {
  localStorage.removeItem(PROFILE_KEY);
  localStorage.removeItem(CATALOG_KEY);
}

export function loadCatalogCache(): CatalogSnapshot | null {
  try {
    const raw = localStorage.getItem(CATALOG_KEY);
    if (!raw) return null;
    const snapshot = JSON.parse(raw) as CatalogSnapshot;
    if (Date.now() - snapshot.savedAt > CATALOG_TTL_MS) return null;
    return snapshot;
  } catch {
    return null;
  }
}

export function saveCatalogCache(snapshot: CatalogSnapshot): void {
  try {
    localStorage.setItem(CATALOG_KEY, JSON.stringify(snapshot));
  } catch {
    // Catalog may exceed quota on some TVs; ignore.
  }
}
