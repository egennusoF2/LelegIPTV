import { XtreamClient } from "../data/xtreamClient";
import type {
  CatalogSnapshot,
  EpgProgramme,
  LiveCategory,
  LiveChannel,
  SeriesCategory,
  SeriesShow,
  SeriesInfo,
  VodCategory,
  VodMovie,
  XtreamProfile,
} from "../data/models";
import {
  loadCatalogCache,
  loadMediaCache,
  loadProfile,
  loadProfiles,
  removeProfile,
  saveCatalogCache,
  saveMediaCache,
  saveProfile,
} from "../data/profileStore";
import { mergeEpgProgrammes } from "../data/models";

export type StatusListener = (message: string, isError?: boolean) => void;

export class CatalogState {
  private client = new XtreamClient();
  private profile: XtreamProfile | null = loadProfile();
  private snapshot: CatalogSnapshot | null = loadCatalogCache(this.profile);
  private statusListener: StatusListener | null = null;
  private expiresAt: number | null = this.snapshot?.accountExpiresAt ?? null;

  private vodCache = new Map<string, VodMovie[]>();
  private seriesCache = new Map<string, SeriesShow[]>();
  private vodRequests = new Map<string, Promise<VodMovie[]>>();
  private seriesRequests = new Map<string, Promise<SeriesShow[]>>();
  private epgCache = new Map<number, EpgProgramme[]>();

  onStatus(listener: StatusListener): void {
    this.statusListener = listener;
  }

  private status(message: string, isError = false): void {
    this.statusListener?.(message, isError);
  }

  get activeProfile(): XtreamProfile | null {
    return this.profile;
  }

  get profiles(): XtreamProfile[] {
    return loadProfiles();
  }

  get accountExpiresAt(): number | null {
    return this.expiresAt;
  }

  get liveCategories(): LiveCategory[] {
    return this.snapshot?.liveCategories ?? [];
  }

  get liveChannels(): LiveChannel[] {
    return this.snapshot?.liveChannels ?? [];
  }

  get vodCategories(): VodCategory[] {
    return this.snapshot?.vodCategories ?? [];
  }

  get seriesCategories(): SeriesCategory[] {
    return this.snapshot?.seriesCategories ?? [];
  }

  channelsForCategory(categoryId: string): LiveChannel[] {
    const all = this.liveChannels;
    if (!categoryId) return all;
    return all.filter((c) => c.categoryId === categoryId);
  }

  async connect(profile: XtreamProfile): Promise<void> {
    this.profile = profile;
    saveProfile(profile);
    this.snapshot = loadCatalogCache(profile);
    this.expiresAt = this.snapshot?.accountExpiresAt ?? null;
    this.vodCache.clear();
    this.seriesCache.clear();
    this.vodRequests.clear();
    this.seriesRequests.clear();
    this.epgCache.clear();
    await this.refreshCatalog(true);
  }

  async selectProfile(profile: XtreamProfile): Promise<void> {
    this.profile = profile;
    saveProfile(profile);
    this.snapshot = loadCatalogCache(profile);
    this.expiresAt = this.snapshot?.accountExpiresAt ?? null;
    this.vodCache.clear();
    this.seriesCache.clear();
    this.vodRequests.clear();
    this.seriesRequests.clear();
    this.epgCache.clear();
    await this.refreshCatalog(false);
  }

  async deleteProfile(profile: XtreamProfile): Promise<void> {
    const wasActive =
      this.profile?.serverUrl === profile.serverUrl &&
      this.profile.username === profile.username;
    removeProfile(profile);
    if (!wasActive) return;
    const next = loadProfiles()[0] ?? null;
    this.profile = next;
    this.snapshot = loadCatalogCache(next);
    this.expiresAt = this.snapshot?.accountExpiresAt ?? null;
    this.vodCache.clear();
    this.seriesCache.clear();
    this.vodRequests.clear();
    this.seriesRequests.clear();
    this.epgCache.clear();
    if (next) {
      saveProfile(next);
      await this.refreshCatalog(false);
    }
  }

  async refreshCatalog(force = false): Promise<void> {
    const profile = this.profile;
    if (!profile) {
      this.status("Configura una lista in Le mie liste", true);
      return;
    }
    if (
      !force &&
      this.snapshot &&
      this.snapshot.profile.serverUrl === profile.serverUrl &&
      this.snapshot.profile.username === profile.username
    ) {
      this.status(`Catalogo in cache: ${this.liveChannels.length} canali`);
      if (!this.expiresAt) {
        void this.client.loadAccountExpiry(profile).then((expiresAt) => {
          this.expiresAt = expiresAt;
          if (this.snapshot) {
            this.snapshot.accountExpiresAt = expiresAt;
            saveCatalogCache(this.snapshot);
          }
          this.status(`Catalogo in cache: ${this.liveChannels.length} canali`);
        });
      }
      return;
    }
    if (force) {
      this.vodCache.clear();
      this.seriesCache.clear();
      this.vodRequests.clear();
      this.seriesRequests.clear();
      this.epgCache.clear();
    }
    this.status(force ? "Ricarica catalogo dal provider…" : "Caricamento catalogo…");
    try {
      const live = await this.client.loadLive(profile);
      this.expiresAt = live.expiresAt;
      const vodCategories = await this.client.loadVodCategories(profile);
      const seriesCategories = await this.client.loadSeriesCategories(profile);
      this.snapshot = {
        profile,
        accountExpiresAt: live.expiresAt,
        liveCategories: live.categories,
        liveChannels: live.channels,
        vodCategories,
        seriesCategories,
        savedAt: Date.now(),
      };
      saveCatalogCache(this.snapshot);
      this.status(`Pronto: ${live.channels.length} canali live`);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.status(`Errore catalogo: ${message}`, true);
      throw error;
    }
  }

  async loadEpg(channel: LiveChannel): Promise<EpgProgramme[]> {
    const profile = this.profile;
    if (!profile) return [];
    const cached = this.epgCache.get(channel.id);
    if (cached) return cached;
    try {
      const [shortEpg, fullEpg] = await Promise.all([
        this.client.loadShortEpg(profile, channel.id).catch(() => []),
        this.client.loadSimpleEpg(profile, channel.id).catch(() => []),
      ]);
      const programmes = mergeEpgProgrammes(fullEpg, shortEpg);
      this.epgCache.set(channel.id, programmes);
      return programmes;
    } catch {
      return [];
    }
  }

  async loadMovies(categoryId: string): Promise<VodMovie[]> {
    const profile = this.profile;
    if (!profile) return [];
    const key = categoryId || "__all__";
    const cached = this.vodCache.get(key);
    if (cached) return cached;
    const pending = this.vodRequests.get(key);
    if (pending) return pending;
    const persisted = await loadMediaCache<VodMovie>("vod", profile, categoryId);
    if (persisted) {
      this.vodCache.set(key, persisted);
      this.status(`${persisted.length} film dalla cache`);
      return persisted;
    }
    this.status(categoryId ? "Caricamento categoria film…" : "Caricamento film…");
    const request = this.client.loadVodMovies(profile, categoryId || undefined)
      .then((movies) => {
        this.vodCache.set(key, movies);
        void saveMediaCache("vod", profile, categoryId, movies);
        this.status(`${movies.length} film caricati`);
        return movies;
      })
      .finally(() => this.vodRequests.delete(key));
    this.vodRequests.set(key, request);
    return request;
  }

  async loadMovieInfo(movie: VodMovie): Promise<VodMovie> {
    const profile = this.profile;
    if (!profile) return movie;
    try {
      return await this.client.loadVodInfo(profile, movie.id, movie);
    } catch {
      return movie;
    }
  }

  async loadSeries(categoryId: string): Promise<SeriesShow[]> {
    const profile = this.profile;
    if (!profile) return [];
    const key = categoryId || "__all__";
    const cached = this.seriesCache.get(key);
    if (cached) return cached;
    const pending = this.seriesRequests.get(key);
    if (pending) return pending;
    const persisted = await loadMediaCache<SeriesShow>("series", profile, categoryId);
    if (persisted) {
      this.seriesCache.set(key, persisted);
      this.status(`${persisted.length} serie dalla cache`);
      return persisted;
    }
    this.status(categoryId ? "Caricamento categoria serie…" : "Caricamento serie…");
    const request = this.client.loadSeries(profile, categoryId || undefined)
      .then((shows) => {
        this.seriesCache.set(key, shows);
        void saveMediaCache("series", profile, categoryId, shows);
        this.status(`${shows.length} serie caricate`);
        return shows;
      })
      .finally(() => this.seriesRequests.delete(key));
    this.seriesRequests.set(key, request);
    return request;
  }

  async loadSeriesInfo(seriesId: number): Promise<SeriesInfo> {
    const profile = this.profile;
    if (!profile) throw new Error("Nessuna lista attiva");
    this.status("Caricamento episodi…");
    const info = await this.client.loadSeriesInfo(profile, seriesId);
    this.status(`${info.episodes.length} episodi caricati`);
    return info;
  }
}
