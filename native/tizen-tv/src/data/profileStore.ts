import type { CatalogSnapshot, XtreamProfile } from "./models";
import { CATALOG_TTL_MS } from "./models";

const PROFILE_KEY = "leleg.tizen.profile";
const PROFILES_KEY = "leleg.tizen.profiles";
const CATALOG_KEY = "leleg.tizen.catalog";
const MEDIA_CACHE_PREFIX = "leleg.tizen.media.";
const MEDIA_CACHE_TTL_MS = 24 * 60 * 60 * 1000;
const MEDIA_DB_NAME = "leleg-tizen-catalog";
const MEDIA_DB_STORE = "media";

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
  const profiles = loadProfiles();
  const index = profiles.findIndex(
    (item) =>
      item.serverUrl === profile.serverUrl && item.username === profile.username,
  );
  if (index >= 0) profiles[index] = profile;
  else profiles.push(profile);
  localStorage.setItem(PROFILES_KEY, JSON.stringify(profiles));
}

export function loadProfiles(): XtreamProfile[] {
  try {
    const raw = localStorage.getItem(PROFILES_KEY);
    const profiles = raw ? (JSON.parse(raw) as XtreamProfile[]) : [];
    const valid = Array.isArray(profiles)
      ? profiles.filter(
          (item) =>
            !!item?.serverUrl && !!item?.username && !!item?.password,
        )
      : [];
    const active = loadProfile();
    if (
      active &&
      !valid.some(
        (item) =>
          item.serverUrl === active.serverUrl &&
          item.username === active.username,
      )
    ) {
      valid.push(active);
    }
    return valid;
  } catch {
    return [];
  }
}

export function removeProfile(profile: XtreamProfile): void {
  const profiles = loadProfiles().filter(
    (item) =>
      item.serverUrl !== profile.serverUrl || item.username !== profile.username,
  );
  localStorage.setItem(PROFILES_KEY, JSON.stringify(profiles));
  const active = loadProfile();
  if (
    active?.serverUrl === profile.serverUrl &&
    active.username === profile.username
  ) {
    localStorage.removeItem(PROFILE_KEY);
  }
}

export function clearProfile(): void {
  localStorage.removeItem(PROFILE_KEY);
  localStorage.removeItem(CATALOG_KEY);
}

function catalogCacheKey(profile: XtreamProfile | null): string {
  if (!profile) return CATALOG_KEY;
  const identity = `${profile.serverUrl}|${profile.username}`;
  let hash = 2166136261;
  for (let index = 0; index < identity.length; index += 1) {
    hash ^= identity.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return `${CATALOG_KEY}.${(hash >>> 0).toString(16)}`;
}

export function loadCatalogCache(
  profile: XtreamProfile | null = loadProfile(),
): CatalogSnapshot | null {
  try {
    const raw =
      localStorage.getItem(catalogCacheKey(profile)) ??
      localStorage.getItem(CATALOG_KEY);
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
    localStorage.setItem(
      catalogCacheKey(snapshot.profile),
      JSON.stringify(snapshot),
    );
  } catch {
    // Catalog may exceed quota on some TVs; ignore.
  }
}

function mediaCacheKey(
  kind: "vod" | "series",
  profile: XtreamProfile,
  categoryId: string,
): string {
  const identity = `${profile.serverUrl}|${profile.username}|${categoryId || "__all__"}`;
  let hash = 2166136261;
  for (let index = 0; index < identity.length; index += 1) {
    hash ^= identity.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return `${MEDIA_CACHE_PREFIX}${kind}.${(hash >>> 0).toString(16)}`;
}

function openMediaDb(): Promise<IDBDatabase | null> {
  return new Promise((resolve) => {
    if (!globalThis.indexedDB) {
      resolve(null);
      return;
    }
    const request = indexedDB.open(MEDIA_DB_NAME, 1);
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains(MEDIA_DB_STORE)) {
        request.result.createObjectStore(MEDIA_DB_STORE);
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => resolve(null);
  });
}

export async function loadMediaCache<T>(
  kind: "vod" | "series",
  profile: XtreamProfile,
  categoryId: string,
): Promise<T[] | null> {
  const key = mediaCacheKey(kind, profile, categoryId);
  const db = await openMediaDb();
  if (db) {
    const cached = await new Promise<{ savedAt: number; items: T[] } | null>((resolve) => {
      const request = db.transaction(MEDIA_DB_STORE, "readonly").objectStore(MEDIA_DB_STORE).get(key);
      request.onsuccess = () => resolve(request.result ?? null);
      request.onerror = () => resolve(null);
    });
    if (
      cached &&
      Array.isArray(cached.items) &&
      Date.now() - cached.savedAt <= MEDIA_CACHE_TTL_MS
    ) {
      return cached.items;
    }
  }
  try {
    const raw = localStorage.getItem(key);
    if (!raw) return null;
    const cached = JSON.parse(raw) as { savedAt: number; items: T[] };
    if (
      !Array.isArray(cached.items) ||
      Date.now() - cached.savedAt > MEDIA_CACHE_TTL_MS
    ) {
      return null;
    }
    return cached.items;
  } catch {
    return null;
  }
}

export async function saveMediaCache<T>(
  kind: "vod" | "series",
  profile: XtreamProfile,
  categoryId: string,
  items: T[],
): Promise<void> {
  const key = mediaCacheKey(kind, profile, categoryId);
  const value = { savedAt: Date.now(), items };
  const db = await openMediaDb();
  if (db) {
    await new Promise<void>((resolve) => {
      const request = db.transaction(MEDIA_DB_STORE, "readwrite").objectStore(MEDIA_DB_STORE).put(value, key);
      request.onsuccess = () => resolve();
      request.onerror = () => resolve();
    });
    return;
  }
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // Older TVs have a small quota. Playback must keep working without cache.
  }
}
