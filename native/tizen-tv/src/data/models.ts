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

export function profileBaseUrl(profile: XtreamProfile): string {
  const raw = profile.serverUrl.trim().replace(/\/+$/, "");
  if (raw.startsWith("http://") || raw.startsWith("https://")) return raw;
  return `http://${raw}`;
}

function liveExtension(profile: XtreamProfile): string {
  return profile.liveContainer?.trim().toLowerCase() === "m3u8" ? "m3u8" : "ts";
}

export function liveUrl(profile: XtreamProfile, streamId: number): string {
  const base = profileBaseUrl(profile);
  const ext = liveExtension(profile);
  return `${base}/live/${profile.username}/${profile.password}/${streamId}.${ext}`;
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

export interface CatalogSnapshot {
  profile: XtreamProfile;
  liveCategories: LiveCategory[];
  liveChannels: LiveChannel[];
  vodCategories: VodCategory[];
  seriesCategories: SeriesCategory[];
  savedAt: number;
}

export const CATALOG_TTL_MS = 24 * 60 * 60 * 1000;
