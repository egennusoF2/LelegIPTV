export type ResumeKind = "movie" | "episode";

export interface PlaybackResume {
  key: string;
  kind: ResumeKind;
  mediaId: number;
  title: string;
  logo: string;
  containerExtension: string;
  positionMs: number;
  durationMs: number;
  updatedAt: number;
}

const STORAGE_KEY = "leleg.tizen.playback.progress.v1";
export const RESUME_MIN_MS = 15_000;
export const COMPLETED_FRACTION = 0.92;

function loadMap(): Record<string, PlaybackResume> {
  try {
    const parsed = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? "{}") as unknown;
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? (parsed as Record<string, PlaybackResume>)
      : {};
  } catch {
    return {};
  }
}

function saveMap(map: Record<string, PlaybackResume>): void {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(map));
}

export function progressKey(kind: ResumeKind, mediaId: number): string {
  return `${kind}:${mediaId}`;
}

export function loadProgress(key: string): PlaybackResume | null {
  const item = loadMap()[key];
  if (!item || item.durationMs <= 0 || item.positionMs < 0) return null;
  return item;
}

export function saveProgress(
  metadata: Omit<PlaybackResume, "positionMs" | "durationMs" | "updatedAt">,
  positionMs: number,
  durationMs: number,
): void {
  if (durationMs <= 0) return;
  const map = loadMap();
  map[metadata.key] = {
    ...metadata,
    positionMs: Math.max(0, positionMs),
    durationMs,
    updatedAt: Date.now(),
  };
  saveMap(map);
}

export function clearProgress(key: string): void {
  const map = loadMap();
  if (!map[key]) return;
  delete map[key];
  saveMap(map);
}

export function progressFraction(progress: PlaybackResume): number {
  return progress.durationMs > 0
    ? Math.max(0, Math.min(1, progress.positionMs / progress.durationMs))
    : 0;
}

export function canResume(progress: PlaybackResume | null): progress is PlaybackResume {
  return !!progress &&
    progress.positionMs >= RESUME_MIN_MS &&
    progressFraction(progress) < COMPLETED_FRACTION;
}

export function continueWatching(limit = 8): PlaybackResume[] {
  return Object.values(loadMap())
    .filter((item) => canResume(item))
    .sort((a, b) => b.updatedAt - a.updatedAt)
    .slice(0, limit);
}
