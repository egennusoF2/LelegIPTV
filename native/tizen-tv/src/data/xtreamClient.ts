import type {
  EpgProgramme,
  LiveCategory,
  LiveChannel,
  SeriesCategory,
  SeriesShow,
  VodCategory,
  VodMovie,
  XtreamProfile,
} from "./models";
import { profileBaseUrl } from "./models";

type JsonValue = unknown;

function encode(value: string): string {
  return encodeURIComponent(value);
}

function apiUrl(
  profile: XtreamProfile,
  action: string,
  parameters: Record<string, string> = {},
): string {
  const base = profileBaseUrl(profile);
  const parts = [
    ["username", profile.username],
    ["password", profile.password],
    ["action", action],
    ...Object.entries(parameters),
  ]
    .map(([k, v]) => `${encode(k)}=${encode(v)}`)
    .join("&");
  return `${base}/player_api.php?${parts}`;
}

async function request(
  profile: XtreamProfile,
  action: string,
  parameters: Record<string, string> = {},
): Promise<JsonValue> {
  const timeoutMs =
    action === "get_live_streams"
      ? 90_000
      : action === "get_vod_streams" || action === "get_series"
        ? parameters.category_id
          ? 90_000
          : 150_000
        : action === "get_short_epg"
          ? 12_000
          : 45_000;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(apiUrl(profile, action, parameters), {
      signal: controller.signal,
      headers: {
        Accept: "application/json,text/plain,*/*",
        "User-Agent": "VLC/3.0.20 LibVLC/3.0.20",
        Referer: `${profileBaseUrl(profile)}/`,
      },
    });
    const body = await response.text();
    if (!response.ok) throw new Error(`${action} HTTP ${response.status}`);
    const trimmed = body.trim();
    if (!trimmed.startsWith("{") && !trimmed.startsWith("[")) {
      throw new Error(`${action} risposta non JSON`);
    }
    return JSON.parse(trimmed) as JsonValue;
  } finally {
    clearTimeout(timer);
  }
}

function asArray(value: JsonValue, ...keys: string[]): Record<string, unknown>[] {
  if (Array.isArray(value)) {
    return value.filter((item): item is Record<string, unknown> => !!item && typeof item === "object");
  }
  if (value && typeof value === "object") {
    const obj = value as Record<string, unknown>;
    for (const key of keys) {
      const arr = obj[key];
      if (Array.isArray(arr)) {
        return arr.filter((item): item is Record<string, unknown> => !!item && typeof item === "object");
      }
    }
  }
  return [];
}

function text(item: Record<string, unknown>, ...keys: string[]): string {
  for (const key of keys) {
    const v = item[key];
    if (typeof v === "string") return v;
    if (typeof v === "number") return String(v);
  }
  return "";
}

function int(item: Record<string, unknown>, ...keys: string[]): number {
  for (const key of keys) {
    const v = item[key];
    if (typeof v === "number") return v;
    if (typeof v === "string") {
      const n = Number.parseInt(v, 10);
      if (!Number.isNaN(n)) return n;
    }
  }
  return 0;
}

function decodeBase64Maybe(value: string): string {
  const trimmed = value.trim();
  if (!trimmed || !/^[A-Za-z0-9+/=]+$/.test(trimmed) || trimmed.length % 4 !== 0) {
    return value;
  }
  try {
    const decoded = atob(trimmed);
    if (/[\x00-\x08\x0E-\x1F]/.test(decoded)) return value;
    return decoded;
  } catch {
    return value;
  }
}

function parseTimestamp(item: Record<string, unknown>, ...keys: string[]): number | null {
  for (const key of keys) {
    const v = item[key];
    if (typeof v === "number" && v > 0) {
      return v < 10_000_000_000 ? v * 1000 : v;
    }
    if (typeof v === "string" && v.trim()) {
      const n = Number.parseInt(v, 10);
      if (!Number.isNaN(n) && n > 0) return n < 10_000_000_000 ? n * 1000 : n;
    }
  }
  return null;
}

function parseCategories(value: JsonValue): LiveCategory[] {
  const items = asArray(value, "categories");
  const categories: LiveCategory[] = [{ id: "", name: "Tutti i canali" }];
  for (const item of items) {
    const id = text(item, "category_id");
    const name = text(item, "category_name");
    if (id && name) categories.push({ id, name });
  }
  return categories;
}

function parseCatchupMode(item: Record<string, unknown>): string {
  return text(item, "tv_archive", "catchup", "catchup_mode");
}

function parseCatchupDays(item: Record<string, unknown>): number {
  return int(item, "tv_archive_duration", "catchup_days") || 0;
}

function parseChannels(value: JsonValue): LiveChannel[] {
  const items = asArray(value, "streams");
  const channels: LiveChannel[] = [];
  for (const item of items) {
    const id = int(item, "stream_id");
    if (id <= 0) continue;
    channels.push({
      id,
      name: text(item, "name") || `Canale ${id}`,
      logo: text(item, "stream_icon"),
      categoryId: text(item, "category_id"),
      epgChannelId: text(item, "epg_channel_id", "tvg_id"),
      catchupMode: parseCatchupMode(item),
      catchupDays: parseCatchupDays(item),
    });
  }
  return channels;
}

function parseShortEpg(value: JsonValue): EpgProgramme[] {
  const items = asArray(value, "epg_listings", "epg_list", "epg", "programmes");
  const programmes: EpgProgramme[] = [];
  for (const item of items) {
    const title = decodeBase64Maybe(text(item, "title", "title_raw")).trim();
    if (!title) continue;
    const start = parseTimestamp(item, "start_timestamp", "start");
    const end = parseTimestamp(item, "stop_timestamp", "end_timestamp", "end", "stop");
    if (!start || !end || end <= start) continue;
    programmes.push({
      title,
      description: decodeBase64Maybe(text(item, "description", "description_raw", "desc")).trim(),
      startTimeMillis: start,
      endTimeMillis: end,
    });
  }
  return programmes.sort((a, b) => a.startTimeMillis - b.startTimeMillis);
}

function parseVodMovie(item: Record<string, unknown>): VodMovie | null {
  const id = int(item, "stream_id", "vod_id", "id");
  if (id <= 0) return null;
  const ext = text(item, "container_extension", "containerExtension", "extension") || "mp4";
  return {
    id,
    name: text(item, "name", "title") || `Film ${id}`,
    logo: text(item, "stream_icon", "cover", "movie_image", "poster"),
    categoryId: text(item, "category_id"),
    containerExtension: ext.replace(/^\./, "") || "mp4",
    rating: text(item, "rating", "rating_5based", "tmdb_rating"),
    year: text(item, "year", "releaseDate", "release_date", "releasedate"),
    plot: text(item, "plot", "description", "overview"),
  };
}

function parseSeriesShow(item: Record<string, unknown>): SeriesShow | null {
  const id = int(item, "series_id", "stream_id", "id");
  if (id <= 0) return null;
  return {
    id,
    name: text(item, "name", "title") || `Serie ${id}`,
    logo: text(item, "cover", "stream_icon", "poster"),
    categoryId: text(item, "category_id"),
    rating: text(item, "rating", "rating_5based", "tmdb_rating"),
    year: text(item, "year", "releaseDate", "release_date"),
    plot: text(item, "plot", "description", "overview"),
  };
}

export class XtreamClient {
  async loadLive(profile: XtreamProfile): Promise<{
    categories: LiveCategory[];
    channels: LiveChannel[];
  }> {
    await request(profile, "get_account_info");
    const categories = parseCategories(await request(profile, "get_live_categories"));
    const channels = parseChannels(await request(profile, "get_live_streams"));
    return { categories, channels };
  }

  async loadShortEpg(profile: XtreamProfile, streamId: number, limit = 100): Promise<EpgProgramme[]> {
    if (streamId <= 0) return [];
    return parseShortEpg(
      await request(profile, "get_short_epg", {
        stream_id: String(streamId),
        limit: String(Math.max(1, limit)),
      }),
    );
  }

  async loadVodCategories(profile: XtreamProfile): Promise<VodCategory[]> {
    const items = asArray(await request(profile, "get_vod_categories"), "categories", "vod_categories");
    const categories: VodCategory[] = [{ id: "", name: "Tutte le categorie" }];
    for (const item of items) {
      const id = text(item, "category_id", "id");
      const name = text(item, "category_name", "name", "title");
      if (id && name) categories.push({ id, name });
    }
    return categories;
  }

  async loadVodMovies(profile: XtreamProfile, categoryId?: string): Promise<VodMovie[]> {
    const params: Record<string, string> = {};
    if (categoryId?.trim()) params.category_id = categoryId.trim();
    const items = asArray(
      await request(profile, "get_vod_streams", params),
      "movies",
      "streams",
      "vod_streams",
    );
    return items.map(parseVodMovie).filter((m): m is VodMovie => m !== null);
  }

  async loadSeriesCategories(profile: XtreamProfile): Promise<SeriesCategory[]> {
    const items = asArray(await request(profile, "get_series_categories"), "categories", "series_categories");
    const categories: SeriesCategory[] = [{ id: "", name: "Tutte le categorie" }];
    for (const item of items) {
      const id = text(item, "category_id", "id");
      const name = text(item, "category_name", "name", "title");
      if (id && name) categories.push({ id, name });
    }
    return categories;
  }

  async loadSeries(profile: XtreamProfile, categoryId?: string): Promise<SeriesShow[]> {
    const params: Record<string, string> = {};
    if (categoryId?.trim()) params.category_id = categoryId.trim();
    const items = asArray(
      await request(profile, "get_series", params),
      "series",
      "shows",
      "streams",
    );
    return items.map(parseSeriesShow).filter((s): s is SeriesShow => s !== null);
  }
}
