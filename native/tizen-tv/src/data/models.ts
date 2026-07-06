export interface XtreamProfile {
  title: string;
  serverUrl: string;
  username: string;
  password: string;
  liveContainer?: string;
}

export const LIVE_FAVORITES_CATEGORY_ID = "__favorites__";

export interface LiveCategory {
  id: string;
  name: string;
}

export interface LiveChannel {
  id: number;
  name: string;
  logo: string;
  categoryId: string;
  epgChannelId: string;
  catchupMode: string;
  catchupDays: number;
}

export function isPlayableChannel(channel: LiveChannel): boolean {
  const name = channel.name.trim();
  return !!name && !/^[-_=:.·]{2,}.*[-_=:.·]{2,}$/.test(name);
}

export interface EpgProgramme {
  title: string;
  description: string;
  startTimeMillis: number;
  endTimeMillis: number;
}

export function currentProgrammeIndex(
  programmes: EpgProgramme[],
  now = Date.now(),
): number {
  let selected = -1;
  for (let index = 0; index < programmes.length; index += 1) {
    const item = programmes[index]!;
    if (now < item.startTimeMillis || now >= item.endTimeMillis) continue;
    if (
      selected < 0 ||
      item.startTimeMillis > programmes[selected]!.startTimeMillis
    ) {
      selected = index;
    }
  }
  return selected;
}

export interface VodCategory {
  id: string;
  name: string;
}

export interface VodMovie {
  id: number;
  name: string;
  logo: string;
  categoryId: string;
  containerExtension: string;
  rating: string;
  year: string;
  plot: string;
  genre: string;
  added: number;
}

export interface SeriesCategory {
  id: string;
  name: string;
}

export interface SeriesShow {
  id: number;
  name: string;
  logo: string;
  categoryId: string;
  rating: string;
  year: string;
  plot: string;
  genre: string;
  added: number;
}

export interface SeriesEpisode {
  id: number;
  title: string;
  season: number;
  episode: number;
  containerExtension: string;
  duration: string;
  plot: string;
  image: string;
}

export interface SeriesInfo {
  show: SeriesShow;
  episodes: SeriesEpisode[];
}

export function profileBaseUrl(profile: XtreamProfile): string {
  const raw = profile.serverUrl.trim().replace(/\/+$/, "");
  if (raw.startsWith("http://") || raw.startsWith("https://")) return raw;
  return `http://${raw}`;
}

function liveExtension(profile: XtreamProfile): string {
  return profile.liveContainer?.trim().toLowerCase() === "m3u8" ? "m3u8" : "ts";
}

export function liveUrl(profile: XtreamProfile, streamId: number): string {
  return liveStreamUrls(profile, streamId)[0] ?? "";
}

/** Rispetta il contenitore Xtream configurato e usa l'altro solo come fallback. */
export function liveStreamUrls(profile: XtreamProfile, streamId: number): string[] {
  const base = profileBaseUrl(profile);
  const user = profile.username;
  const pass = profile.password;
  const primary = liveExtension(profile);
  const secondary = primary === "m3u8" ? "ts" : "m3u8";
  const first = `${base}/live/${user}/${pass}/${streamId}.${primary}`;
  const second = `${base}/live/${user}/${pass}/${streamId}.${secondary}`;
  return [first, second];
}

export function alternateLiveUrl(url: string): string | null {
  const lower = url.toLowerCase();
  if (lower.endsWith(".ts")) return `${url.slice(0, -3)}m3u8`;
  if (lower.endsWith(".m3u8")) return `${url.slice(0, -5)}ts`;
  return null;
}

export function movieUrl(
  profile: XtreamProfile,
  streamId: number,
  extension = "mp4",
): string {
  const base = profileBaseUrl(profile);
  const ext = extension.trim().replace(/^\./, "") || "mp4";
  return `${base}/movie/${profile.username}/${profile.password}/${streamId}.${ext}`;
}

export function seriesUrl(
  profile: XtreamProfile,
  episodeId: number,
  extension = "mp4",
): string {
  const base = profileBaseUrl(profile);
  const ext = extension.trim().replace(/^\./, "") || "mp4";
  return `${base}/series/${profile.username}/${profile.password}/${episodeId}.${ext}`;
}

function catchupStamp(timestamp: number): string {
  const date = new Date(timestamp);
  const pad = (value: number): string => String(value).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}:${pad(
    date.getHours(),
  )}-${pad(date.getMinutes())}`;
}

export function catchupStreamUrls(
  profile: XtreamProfile,
  channel: LiveChannel,
  programme: EpgProgramme,
): string[] {
  if (!canReplayProgramme(channel, programme)) return [];
  const minutes = Math.max(
    1,
    Math.floor((programme.endTimeMillis - programme.startTimeMillis) / 60_000),
  );
  const base = `${profileBaseUrl(profile)}/timeshift/${profile.username}/${profile.password}/${
    minutes
  }/${catchupStamp(programme.startTimeMillis)}/${channel.id}`;
  const primary = liveExtension(profile);
  const alternate = primary === "ts" ? "m3u8" : "ts";
  return [`${base}.${primary}`, `${base}.${alternate}`];
}

export function canReplayProgramme(
  channel: LiveChannel,
  programme: EpgProgramme,
  now = Date.now(),
): boolean {
  if (!channel.catchupMode && channel.catchupDays <= 0) return false;
  if (programme.endTimeMillis >= now || programme.endTimeMillis <= programme.startTimeMillis) {
    return false;
  }
  const days = channel.catchupDays > 0 ? channel.catchupDays : 7;
  return programme.startTimeMillis > now - days * 24 * 60 * 60 * 1000;
}

export function mergeEpgProgrammes(...sources: EpgProgramme[][]): EpgProgramme[] {
  const result: EpgProgramme[] = [];
  const sorted = sources
    .flat()
    .filter((programme) => programme.title.trim())
    .sort((a, b) => a.startTimeMillis - b.startTimeMillis);

  for (const programme of sorted) {
    const duplicateIndex = result.findIndex((existing) =>
      epgProgrammesLookDuplicate(existing, programme),
    );
    if (duplicateIndex >= 0) {
      const existing = result[duplicateIndex]!;
      if (epgProgrammeScore(programme) > epgProgrammeScore(existing)) {
        result[duplicateIndex] = programme;
      }
      continue;
    }
    result.push(programme);
  }
  return result.sort((a, b) => a.startTimeMillis - b.startTimeMillis);
}

function normalizeEpgTitle(title: string): string {
  return title.trim().toLowerCase().replace(/\s+/g, " ");
}

function epgProgrammeScore(programme: EpgProgramme): number {
  const duration = Math.max(0, programme.endTimeMillis - programme.startTimeMillis);
  return duration + programme.description.length * 1000;
}

function epgProgrammesLookDuplicate(a: EpgProgramme, b: EpgProgramme): boolean {
  if (normalizeEpgTitle(a.title) !== normalizeEpgTitle(b.title)) return false;
  const startDiff = Math.abs(a.startTimeMillis - b.startTimeMillis);
  const endDiff = Math.abs(a.endTimeMillis - b.endTimeMillis);
  if (startDiff <= 3 * 60_000 && endDiff <= 3 * 60_000) return true;
  if (startDiff <= 20 * 60_000 && endDiff <= 5 * 60_000) return true;

  const overlapStart = Math.max(a.startTimeMillis, b.startTimeMillis);
  const overlapEnd = Math.min(a.endTimeMillis, b.endTimeMillis);
  const overlap = overlapEnd - overlapStart;
  if (overlap <= 0) return false;
  const shortest = Math.min(
    a.endTimeMillis - a.startTimeMillis,
    b.endTimeMillis - b.startTimeMillis,
  );
  return shortest > 0 && overlap / shortest >= 0.75;
}

export interface CatalogSnapshot {
  profile: XtreamProfile;
  accountExpiresAt?: number | null;
  liveCategories: LiveCategory[];
  liveChannels: LiveChannel[];
  vodCategories: VodCategory[];
  seriesCategories: SeriesCategory[];
  savedAt: number;
}

export const CATALOG_TTL_MS = 24 * 60 * 60 * 1000;
