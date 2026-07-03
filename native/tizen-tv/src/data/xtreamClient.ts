import type {
  EpgProgramme,
  LiveCategory,
  LiveChannel,
  SeriesCategory,
  SeriesEpisode,
  SeriesInfo,
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
    const binary = atob(trimmed);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }
    const decoded =
      typeof TextDecoder !== "undefined"
        ? new TextDecoder("utf-8").decode(bytes)
        : binary;
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
      const value = v.trim();
      if (/^\d+$/.test(value)) {
        const n = Number.parseInt(value, 10);
        if (!Number.isNaN(n) && n > 0) return n < 10_000_000_000 ? n * 1000 : n;
      }
      const parsed = Date.parse(value.replace(" ", "T"));
      if (!Number.isNaN(parsed)) return parsed;
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
  const explicit = text(item, "catchup", "catchup_mode").trim();
  if (explicit) return explicit;
  return int(item, "tv_archive") > 0 ? "xtream" : "";
}

function parseCatchupDays(item: Record<string, unknown>): number {
  const explicit = int(item, "tv_archive_duration", "catchup_days");
  if (explicit > 0) return explicit;
  return int(item, "tv_archive") > 0 ? 7 : 0;
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

function parseVodInfo(value: JsonValue, fallback: VodMovie): VodMovie {
  const root = object(value) ?? {};
  const info = object(root.info) ?? {};
  const movieData = object(root.movie_data) ?? {};
  const merged = { ...movieData, ...info };
  return {
    ...fallback,
    name: text(merged, "name", "title") || fallback.name,
    logo:
      text(merged, "movie_image", "cover_big", "cover", "stream_icon", "poster") ||
      fallback.logo,
    containerExtension:
      text(merged, "container_extension", "containerExtension", "extension").replace(/^\./, "") ||
      fallback.containerExtension,
    rating: text(merged, "rating", "rating_5based", "tmdb_rating") || fallback.rating,
    year:
      text(merged, "year", "releaseDate", "release_date", "releasedate") ||
      fallback.year,
    plot:
      decodeBase64Maybe(text(merged, "plot", "description", "overview", "storyline")).trim() ||
      fallback.plot,
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

function object(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function parseEpisode(item: Record<string, unknown>, seasonHint = 0): SeriesEpisode | null {
  const info = object(item.info) ?? {};
  const merged = { ...info, ...item };
  const id = int(merged, "id", "stream_id", "episode_id");
  if (id <= 0) return null;
  return {
    id,
    title: text(merged, "title", "name") || `Episodio ${id}`,
    season: seasonHint || int(merged, "season", "season_num"),
    episode: int(merged, "episode_num", "episode", "episode_number"),
    containerExtension:
      text(merged, "container_extension", "containerExtension", "extension").replace(/^\./, "") ||
      "mp4",
    duration: text(merged, "duration", "runtime"),
    plot: text(merged, "plot", "description", "overview"),
    image: text(merged, "movie_image", "cover", "stream_icon", "poster"),
  };
}

function parseEpisodes(value: unknown): SeriesEpisode[] {
  const episodes: SeriesEpisode[] = [];
  const append = (entry: unknown, seasonHint = 0): void => {
    if (Array.isArray(entry)) {
      for (const item of entry) {
        const parsed = object(item) ? parseEpisode(object(item)!, seasonHint) : null;
        if (parsed) episodes.push(parsed);
      }
      return;
    }
    const item = object(entry);
    if (!item) return;
    const nested = item.episodes;
    if (Array.isArray(nested)) {
      append(nested, seasonHint);
      return;
    }
    const parsed = parseEpisode(item, seasonHint);
    if (parsed) episodes.push(parsed);
  };

  if (Array.isArray(value)) {
    append(value);
  } else {
    const seasons = object(value);
    if (seasons) {
      for (const key of Object.keys(seasons)) {
        append(seasons[key], Number.parseInt(key, 10) || 0);
      }
    }
  }
  const unique = new Map<number, SeriesEpisode>();
  for (const episode of episodes) unique.set(episode.id, episode);
  return [...unique.values()].sort(
    (a, b) => a.season - b.season || a.episode - b.episode || a.id - b.id,
  );
}

export class XtreamClient {
  async loadAccountExpiry(profile: XtreamProfile): Promise<number | null> {
    const account = await request(profile, "get_account_info");
    const accountRoot =
      account && typeof account === "object" && !Array.isArray(account)
        ? (account as Record<string, unknown>)
        : {};
    const userInfo = object(accountRoot.user_info) ?? accountRoot;
    for (const key of ["exp_date", "expiration", "expiry", "expiration_date"]) {
      const raw = userInfo[key];
      const seconds =
        typeof raw === "number" ? raw : Number.parseInt(String(raw ?? ""), 10);
      if (Number.isFinite(seconds) && seconds > 0) return seconds * 1000;
      if (typeof raw === "string") {
        const parsed = Date.parse(raw);
        if (Number.isFinite(parsed) && parsed > 0) return parsed;
      }
    }
    return null;
  }

  async loadLive(profile: XtreamProfile): Promise<{
    categories: LiveCategory[];
    channels: LiveChannel[];
    expiresAt: number | null;
  }> {
    const [expiresAt, categoriesRaw, channelsRaw] = await Promise.all([
      this.loadAccountExpiry(profile),
      request(profile, "get_live_categories"),
      request(profile, "get_live_streams"),
    ]);
    const categories = parseCategories(categoriesRaw);
    const channels = parseChannels(channelsRaw);
    return {
      categories,
      channels,
      expiresAt,
    };
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

  async loadSimpleEpg(profile: XtreamProfile, streamId: number): Promise<EpgProgramme[]> {
    if (streamId <= 0) return [];
    for (const action of ["get_simple_data_table", "get_simple_date_table"]) {
      try {
        const programmes = parseShortEpg(
          await request(profile, action, { stream_id: String(streamId) }),
        );
        if (programmes.length) return programmes;
      } catch {
        // Providers expose one of the two historical action spellings.
      }
    }
    return [];
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

  async loadVodInfo(
    profile: XtreamProfile,
    streamId: number,
    fallback: VodMovie,
  ): Promise<VodMovie> {
    if (streamId <= 0) return fallback;
    return parseVodInfo(
      await request(profile, "get_vod_info", { vod_id: String(streamId) }),
      fallback,
    );
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

  async loadSeriesInfo(profile: XtreamProfile, seriesId: number): Promise<SeriesInfo> {
    const value = await request(profile, "get_series_info", {
      series_id: String(seriesId),
    });
    const root = object(value);
    if (!root) throw new Error("Dettaglio serie non valido");
    const info = object(root.info) ?? object(root.series_info) ?? {};
    const showData = object(root.series) ?? object(root.show) ?? {};
    const show =
      parseSeriesShow({ ...info, ...showData, series_id: seriesId }) ??
      ({
        id: seriesId,
        name: `Serie ${seriesId}`,
        logo: "",
        categoryId: "",
        rating: "",
        year: "",
        plot: "",
      } satisfies SeriesShow);
    return { show, episodes: parseEpisodes(root.episodes) };
  }
}
