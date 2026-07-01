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
  const unique = new Map<string, EpgProgramme>();
  for (const source of sources) {
    for (const programme of source) {
      const key = `${programme.startTimeMillis}|${programme.endTimeMillis}|${programme.title.toLowerCase()}`;
      unique.set(key, programme);
    }
  }
  return [...unique.values()].sort((a, b) => a.startTimeMillis - b.startTimeMillis);
}

export interface CatalogSnapshot {
  profile: XtreamProfile;
  liveCategories: LiveCategory[];
  liveChannels: LiveChannel[];
  vodCategories: VodCategory[];
  seriesCategories: SeriesCategory[];
  savedAt: number;
}

export const CATALOG_TTL_MS = 24 * 60 * 60 * 1000;
