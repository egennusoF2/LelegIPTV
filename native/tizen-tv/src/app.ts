import {
  FocusManager,
  mapKeyFromEvent,
  registerTvKeys,
  type FocusableElement,
} from "./app/focusManager";
import { NAV_ITEMS, Router, type TvRoute } from "./app/router";
import { profileFromForm, resolvePreset } from "./data/profilePresets";
import type {
  EpgProgramme,
  LiveChannel,
  SeriesEpisode,
  SeriesShow,
  VodMovie,
} from "./data/models";
import {
  canReplayProgramme,
  catchupStreamUrls,
  currentProgrammeIndex,
  isPlayableChannel,
  liveStreamUrls,
  movieUrl,
  profileBaseUrl,
  seriesUrl,
} from "./data/models";
import { AvplayPlayer, Html5PreviewPlayer } from "./player/avplay";
import { LiveScreen } from "./screens/liveScreen";
import { CatalogState } from "./state/catalogState";
import {
  CATALOG_SORT_OPTIONS,
  sortCatalog,
  type CatalogSort,
} from "./data/catalogSort";
import {
  canResume,
  clearProgress,
  continueWatching,
  loadProgress,
  progressFraction,
  progressKey,
  saveProgress,
  type PlaybackResume,
} from "./state/playbackProgress";
import { ensureWebapisLoaded, setVisible } from "./polyfills";
import {
  clearElement,
  el,
  pageHeader,
  playbackUrlForMovie,
  renderPosterRow,
  renderSeriesPosterRow,
  setElementChildren,
} from "./ui/renderUtils";

type Zone = "nav" | "content";
type ProgressMetadata = Omit<
  PlaybackResume,
  "positionMs" | "durationMs" | "updatedAt"
>;
type PlaybackOptions = {
  metadata: ProgressMetadata;
  startPositionMs: number;
  onClose?: () => void;
};

function loadFavoriteMovieIds(): Set<number> {
  try {
    const value = JSON.parse(
      localStorage.getItem("leleg.tizen.favorite.movies") ?? "[]",
    ) as unknown;
    return new Set(
      Array.isArray(value)
        ? value.filter((item): item is number => Number.isInteger(item))
        : [],
    );
  } catch {
    return new Set();
  }
}

export class LelegTvApp {
  private root = document.getElementById("app")!;
  private playerLayer = document.getElementById("player-layer")!;
  private statusBar = el("div", "status-bar");
  private accountBar = el("div", "account-bar");
  private loadingOverlay = el("div", "catalog-loading");
  private router = new Router();
  private catalog = new CatalogState();
  private navFocus = new FocusManager();
  private contentFocus = new FocusManager();
  private liveScreen: LiveScreen | null = null;
  private zone: Zone = "nav";
  private avplay = new AvplayPlayer();
  private htmlPreview = new Html5PreviewPlayer();
  private fullscreen = false;
  private fullscreenControlsVisible = false;
  private fullscreenControlIndex = 0;
  private fullscreenAudioIndex = -1;
  private fullscreenSubtitleIndex = -1;
  private fullscreenSpeedIndex = 2;
  private fullscreenUiTimer: number | null = null;
  private fullscreenProgressTimer: number | null = null;
  private fullscreenChannel: LiveChannel | null = null;
  private fullscreenProgressMeta: ProgressMetadata | null = null;
  private lastProgressSaveAt = 0;
  private fullscreenOnClose: (() => void) | null = null;
  private avplayAvailable = false;
  private moviesCategoryId = "";
  private moviesCategoryInitialized = false;
  private movies: VodMovie[] = [];
  private moviesSort = (localStorage.getItem("leleg.tizen.sort.movies") ??
    "recent") as CatalogSort;
  private moviesRenderGen = 0;
  private seriesCategoryId = "";
  private seriesCategoryInitialized = false;
  private series: SeriesShow[] = [];
  private seriesSort = (localStorage.getItem("leleg.tizen.sort.series") ??
    "recent") as CatalogSort;
  private seriesRenderGen = 0;
  private guideCategoryId = "";
  private guideChannelId = 0;
  private guideDayOffset = 0;
  private guideLoadGeneration = 0;
  private contentBackAction: (() => void) | null = null;
  private favoriteMovieIds = loadFavoriteMovieIds();
  private exitDialog: HTMLElement | null = null;
  private exitDialogIndex = 1;

  private shell = el("div", "shell");
  private sidebar = el("nav", "sidebar");
  private content = el("main", "content");

  constructor() {
    registerTvKeys();
    this.loadingOverlay.append(
      el("div", "catalog-spinner"),
      el("div", "catalog-loading-text", "Caricamento libreria…"),
    );
    setVisible(this.loadingOverlay, false);
    document.body.append(this.loadingOverlay);
    this.root.append(this.shell);
    this.shell.append(this.sidebar, this.content);

    this.catalog.onStatus((message, isError) => {
      this.statusBar.textContent = message;
      this.statusBar.classList.toggle("error", !!isError);
      const loading = /caricamento|ricarica|preparazione/i.test(message) && !isError;
      const loadingText = this.loadingOverlay.querySelector<HTMLElement>(
        ".catalog-loading-text",
      );
      if (loadingText) loadingText.textContent = message;
      setVisible(this.loadingOverlay, loading);
      this.updateAccountBar();
    });

    this.avplay.setStateListener((state, _title, detail) => {
      if (state === "error" && detail) {
        this.statusBar.textContent = `Player: ${detail}`;
        this.statusBar.classList.add("error");
        const playerError = this.playerLayer.querySelector<HTMLElement>(".player-error");
        if (playerError) {
          playerError.textContent = `Riproduzione non riuscita: ${detail}`;
          playerError.classList.add("visible");
        }
      } else if (state === "playing") {
        this.statusBar.classList.remove("error");
        this.playerLayer.querySelector(".player-error")?.classList.remove("visible");
      }
    });

    this.router.subscribe((route) => this.renderRoute(route));
    document.addEventListener("keydown", (event) => this.onKeyDown(event), true);

    void this.bootstrap();
  }

  private useAvplay(): boolean {
    return this.avplayAvailable && this.avplay.isAvailable();
  }

  private async bootstrap(): Promise<void> {
    this.renderNav();
    try {
      await ensureWebapisLoaded();
      this.avplayAvailable = this.avplay.isAvailable();
    } catch {
      this.avplayAvailable = false;
    }
    if (this.catalog.activeProfile) {
      try {
      await this.catalog.refreshCatalog(false);
      this.catalog.warmInitialMediaCategories();
      } catch {
        // handled via status
      }
    } else {
      setVisible(this.loadingOverlay, false);
      this.statusBar.textContent = "Seleziona una lista in Le mie liste";
    }
    const initialRoute = this.catalog.activeProfile ? "home" : "settings";
    this.router.navigate(initialRoute, { force: true });
    this.zone = "nav";
    this.navFocus.focusIndex(NAV_ITEMS.findIndex((i) => i.route === initialRoute));
  }

  private renderNav(): void {
    setElementChildren(this.sidebar, [el("div", "brand", "LELEG IPTV")]);
    const items = NAV_ITEMS.map((item) => {
      const button = el("button", "nav-item");
      button.type = "button";
      button.textContent = item.label;
      button.dataset.route = item.route;
      if (this.router.current === item.route) button.classList.add("active");
      return {
        el: button,
        onActivate: () => {
          this.zone = "content";
          this.navFocus.clearFocus();
          this.router.navigate(item.route);
        },
      };
    });
    this.navFocus.setItems(items);
    this.sidebar.append(...items.map((i) => i.el), this.accountBar, this.statusBar);
    this.updateAccountBar();
  }

  private updateAccountBar(): void {
    const profile = this.catalog.activeProfile;
    if (!profile) {
      this.accountBar.textContent = "Nessuna lista attiva";
      return;
    }
    const expiresAt = this.catalog.accountExpiresAt;
    const expiry = expiresAt
      ? new Date(expiresAt).toLocaleDateString("it-IT")
      : "scadenza non disponibile";
    this.accountBar.textContent = `${profile.title || "Lista attiva"} · ${expiry}`;
  }

  private teardownLiveScreen(): void {
    this.liveScreen?.unmount();
    this.liveScreen = null;
  }

  private mountLiveScreen(): void {
    this.teardownLiveScreen();
    this.liveScreen = new LiveScreen({
      catalog: this.catalog,
      useAvplay: () => this.useAvplay(),
      avplay: this.avplay,
      htmlPreview: this.htmlPreview,
      onFullscreen: (channel) => this.openFullscreenChannel(channel),
      onProgramme: (channel, programme) =>
        this.playGuideProgramme(channel, programme),
      onStatus: (message, isError) => {
        this.statusBar.textContent = message;
        this.statusBar.classList.toggle("error", !!isError);
      },
    });
    this.liveScreen.mount(this.content);
    if (this.zone === "content") {
      this.liveScreen.focusColumn("categories");
    }
  }

  private renderRoute(route: TvRoute): void {
    this.contentBackAction = null;
    for (const button of Array.from(this.sidebar.querySelectorAll<HTMLElement>(".nav-item"))) {
      button.classList.toggle("active", button.dataset.route === route);
    }
    this.teardownLiveScreen();
    clearElement(this.content);
    switch (route) {
      case "home":
        this.renderHome();
        break;
      case "live":
        this.mountLiveScreen();
        break;
      case "movies":
        void this.renderMovies();
        break;
      case "series":
        void this.renderSeries();
        break;
      case "search":
        this.renderSearch();
        break;
      case "guide":
        void this.renderGuide();
        break;
      case "favorites":
        void this.renderFavorites();
        break;
      case "settings":
        this.renderSettings();
        break;
      default:
        this.renderPlaceholder(route);
        break;
    }
    if (this.zone === "nav") this.navFocus.focusIndex(NAV_ITEMS.findIndex((i) => i.route === route));
  }

  private renderHome(): void {
    const resumable = continueWatching();
    this.content.append(
      pageHeader("Benvenuto", "Leleg IPTV per Samsung TV"),
      el("p", "hero-copy", `Canali live: ${this.catalog.liveChannels.length}`),
    );
    const grid = el("div", "hub-grid");
    if (resumable.length) grid.classList.add("compact");
    const tiles = [
      { label: "Live TV", route: "live" as TvRoute },
      { label: "Film", route: "movies" as TvRoute },
      { label: "Serie", route: "series" as TvRoute },
    ].map((tile) => {
      const node = el("button", "hub-tile panel focusable", tile.label);
      node.type = "button";
      return {
        el: node,
        onActivate: () => {
          this.zone = "content";
          this.router.navigate(tile.route);
        },
      };
    });
    grid.append(...tiles.map((t) => t.el));
    this.content.append(grid);
    const continueItems: FocusableElement[] = [];
    if (resumable.length) {
      const section = el("section", "continue-section");
      section.append(el("h2", "section-title", "Continua a guardare"));
      const row = el("div", "continue-row");
      for (const progress of resumable) {
        const card = el("button", "continue-card focusable");
        card.type = "button";
        if (progress.logo) {
          const image = document.createElement("img");
          image.src = progress.logo;
          image.alt = "";
          card.append(image);
        }
        const copy = el("div", "continue-copy");
        copy.append(
          el("div", "title", progress.title),
          el(
            "div",
            "meta",
            `${progress.kind === "movie" ? "Film" : "Episodio"} · ${Math.floor(
              progressFraction(progress) * 100,
            )}%`,
          ),
        );
        const bar = el("div", "continue-progress");
        const fill = el("span");
        fill.style.width = `${progressFraction(progress) * 100}%`;
        bar.append(fill);
        copy.append(bar);
        card.append(copy);
        row.append(card);
        continueItems.push({
          el: card,
          onActivate: () => this.resumeStoredProgress(progress),
        });
      }
      section.append(row);
      this.content.append(section);
    }
    this.contentFocus.setItems([...tiles, ...continueItems]);
  }

  private resumeStoredProgress(progress: PlaybackResume): void {
    const profile = this.catalog.activeProfile;
    if (!profile || !canResume(progress)) return;
    const url =
      progress.kind === "movie"
        ? movieUrl(profile, progress.mediaId, progress.containerExtension)
        : seriesUrl(profile, progress.mediaId, progress.containerExtension);
    this.openFullscreenUrl(url, progress.title, null, {
      metadata: {
        key: progress.key,
        kind: progress.kind,
        mediaId: progress.mediaId,
        title: progress.title,
        logo: progress.logo,
        containerExtension: progress.containerExtension,
      },
      startPositionMs: progress.positionMs,
    });
  }

  private async renderMovies(): Promise<void> {
    const gen = ++this.moviesRenderGen;
    clearElement(this.content);
    const header = pageHeader("Film", "Catalogo on demand");
    const toolbar = el("div", "library-toolbar");
    const count = el("div", "library-count", "Caricamento titoli…");
    const sort = this.catalogSortControl("Film", this.moviesSort, (value) => {
      this.moviesSort = value;
      localStorage.setItem("leleg.tizen.sort.movies", value);
      void this.renderMovies();
    });
    toolbar.append(count, sort.el);
    const browser = el("div", "library-browser");
    const categoriesHost = el("div", "library-categories panel");
    const gridHost = el("div", "library-grid-host");
    browser.append(categoriesHost, gridHost);
    this.content.append(header, toolbar, browser);
    const categories = this.catalog.vodCategories;
    if (!this.moviesCategoryInitialized) {
      this.moviesCategoryId = categories.find((category) => category.id)?.id ?? "";
      this.moviesCategoryInitialized = true;
    }
    const catButtons = categories.map((category) => {
      const btn = el("button", "library-category focusable", category.name);
      btn.type = "button";
      if (category.id === this.moviesCategoryId) btn.classList.add("active");
      return {
        el: btn,
        onActivate: () => {
          this.moviesCategoryId = category.id;
          void this.renderMovies();
        },
      };
    });
    categoriesHost.append(...catButtons.map((c) => c.el));

    gridHost.append(el("div", "loading-panel", "Caricamento film…"));
    try {
      this.movies = sortCatalog(
        await this.catalog.loadMovies(this.moviesCategoryId),
        this.moviesSort,
        this.favoriteMovieIds,
      );
    } catch {
      this.movies = [];
    }
    if (gen !== this.moviesRenderGen) return;
    count.textContent = `${this.movies.length} titoli in questa categoria`;
    const posters: FocusableElement[] = renderPosterRow(
      gridHost,
      this.movies,
      (movie) => void this.renderMovieDetail(movie),
      (items, startIndex) => {
        this.wireLibraryNavigation(
          [sort, ...catButtons],
          items,
          Math.max(0, startIndex - 1),
        );
        this.contentFocus.setItems([sort, ...catButtons, ...items]);
      },
    );
    this.wireLibraryNavigation([sort, ...catButtons], posters);
    this.contentFocus.setItems([sort, ...catButtons, ...posters]);
  }

  private async renderMovieDetail(movie: VodMovie): Promise<void> {
    this.contentBackAction = () => {
      this.contentBackAction = null;
      void this.renderMovies();
    };
    clearElement(this.content);
    this.content.append(pageHeader("Film", movie.name));
    const loading = el("div", "loading-panel", "Caricamento dettagli…");
    this.content.append(loading);
    const detailedMovie = await this.catalog.loadMovieInfo(movie);
    if (!loading.isConnected) return;
    loading.remove();
    const detail = el("div", "media-detail panel");
    if (detailedMovie.logo) {
      const image = document.createElement("img");
      image.className = "detail-poster";
      image.src = detailedMovie.logo;
      image.alt = detailedMovie.name;
      detail.append(image);
    }
    const copy = el("div", "detail-copy");
    copy.append(
      el("h2", "detail-title", detailedMovie.name),
      el(
        "p",
        "hero-copy",
        [detailedMovie.year, detailedMovie.genre, detailedMovie.rating]
          .filter(Boolean)
          .join(" · "),
      ),
      el("p", "detail-plot", detailedMovie.plot || "Descrizione non disponibile."),
    );
    const actions = el("div", "detail-actions");
    const movieProgressKey = progressKey("movie", detailedMovie.id);
    const savedProgress = loadProgress(movieProgressKey);
    const resumable = canResume(savedProgress);
    const play = el(
      "button",
      "settings-btn focusable panel",
      resumable ? "Riprendi" : "Riproduci",
    );
    const restart = resumable
      ? el("button", "settings-btn focusable panel", "Ricomincia")
      : null;
    const favorite = el(
      "button",
      "settings-btn focusable panel",
      this.favoriteMovieIds.has(movie.id) ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
    );
    play.type = favorite.type = "button";
    if (restart) restart.type = "button";
    actions.append(play);
    if (restart) actions.append(restart);
    actions.append(favorite);
    copy.append(actions);
    detail.append(copy);
    this.content.append(detail);
    const progressMetadata: ProgressMetadata = {
      key: movieProgressKey,
      kind: "movie",
      mediaId: detailedMovie.id,
      title: detailedMovie.name,
      logo: detailedMovie.logo,
      containerExtension: detailedMovie.containerExtension,
    };
    const focusItems: FocusableElement[] = [
      {
        el: play,
        onActivate: () => {
          const url = playbackUrlForMovie(this.catalog, detailedMovie);
          if (url) {
            this.openFullscreenUrl(url, detailedMovie.name, null, {
              metadata: progressMetadata,
              startPositionMs: resumable ? savedProgress?.positionMs ?? 0 : 0,
              onClose: () => void this.renderMovieDetail(detailedMovie),
            });
          }
        },
      },
    ];
    if (restart) {
      focusItems.push({
        el: restart,
        onActivate: () => {
          clearProgress(movieProgressKey);
          const url = playbackUrlForMovie(this.catalog, detailedMovie);
          if (url) {
            this.openFullscreenUrl(url, detailedMovie.name, null, {
              metadata: progressMetadata,
              startPositionMs: 0,
              onClose: () => void this.renderMovieDetail(detailedMovie),
            });
          }
        },
      });
    }
    focusItems.push(
      {
        el: favorite,
        onActivate: () => {
          if (this.favoriteMovieIds.has(movie.id)) this.favoriteMovieIds.delete(movie.id);
          else this.favoriteMovieIds.add(movie.id);
          localStorage.setItem(
            "leleg.tizen.favorite.movies",
            JSON.stringify([...this.favoriteMovieIds]),
          );
          void this.renderMovieDetail(detailedMovie);
        },
      },
    );
    this.contentFocus.setItems(focusItems);
  }

  private async renderFavorites(): Promise<void> {
    clearElement(this.content);
    this.content.append(pageHeader("Preferiti", "La tua raccolta"));
    const loading = el("div", "loading-panel", "Caricamento preferiti…");
    const host = el("div");
    this.content.append(loading, host);
    const movies = await this.catalog.loadMovies("").catch(() => []);
    loading.remove();
    const favorites = movies.filter((movie) => this.favoriteMovieIds.has(movie.id));
    const posters = renderPosterRow(host, favorites, (movie) => {
      void this.renderMovieDetail(movie);
    });
    this.contentFocus.setItems(posters);
  }

  private async renderSeries(): Promise<void> {
    const gen = ++this.seriesRenderGen;
    clearElement(this.content);
    const header = pageHeader("Serie", "Catalogo e stagioni");
    const toolbar = el("div", "library-toolbar");
    const count = el("div", "library-count", "Caricamento titoli…");
    const sort = this.catalogSortControl("Serie", this.seriesSort, (value) => {
      this.seriesSort = value;
      localStorage.setItem("leleg.tizen.sort.series", value);
      void this.renderSeries();
    });
    toolbar.append(count, sort.el);
    const browser = el("div", "library-browser");
    const categoriesHost = el("div", "library-categories panel");
    const gridHost = el("div", "library-grid-host");
    browser.append(categoriesHost, gridHost);
    this.content.append(header, toolbar, browser);
    const categories = this.catalog.seriesCategories;
    if (!this.seriesCategoryInitialized) {
      this.seriesCategoryId = categories.find((category) => category.id)?.id ?? "";
      this.seriesCategoryInitialized = true;
    }
    const categoryButtons = categories.map((category) => {
      const button = el("button", "library-category focusable", category.name);
      button.type = "button";
      if (category.id === this.seriesCategoryId) button.classList.add("active");
      return {
        el: button,
        onActivate: () => {
          this.seriesCategoryId = category.id;
          void this.renderSeries();
        },
      };
    });
    categoriesHost.append(...categoryButtons.map((item) => item.el));

    gridHost.append(el("div", "loading-panel", "Caricamento serie…"));
    try {
      this.series = sortCatalog(
        await this.catalog.loadSeries(this.seriesCategoryId),
        this.seriesSort,
        this.favoriteMovieIds,
      );
    } catch {
      this.series = [];
    }
    if (gen !== this.seriesRenderGen) return;
    count.textContent = `${this.series.length} titoli in questa categoria`;
    const posters: FocusableElement[] = renderSeriesPosterRow(
      gridHost,
      this.series,
      (show) => void this.renderSeriesDetail(show),
      (items, startIndex) => {
        this.wireLibraryNavigation(
          [sort, ...categoryButtons],
          items,
          Math.max(0, startIndex - 1),
        );
        this.contentFocus.setItems([sort, ...categoryButtons, ...items]);
      },
    );
    this.wireLibraryNavigation([sort, ...categoryButtons], posters);
    this.contentFocus.setItems([sort, ...categoryButtons, ...posters]);
  }

  private catalogSortControl(
    kind: string,
    selected: CatalogSort,
    onChange: (value: CatalogSort) => void,
  ): FocusableElement {
    const button = el(
      "button",
      "catalog-sort focusable",
      `Ordina ${kind}: ${
        CATALOG_SORT_OPTIONS.find((option) => option.value === selected)?.label ??
        "Più recenti"
      }`,
    );
    button.type = "button";
    return {
      el: button,
      onActivate: () => {
        const current = CATALOG_SORT_OPTIONS.findIndex(
          (option) => option.value === selected,
        );
        const next = CATALOG_SORT_OPTIONS[(current + 1) % CATALOG_SORT_OPTIONS.length]!;
        onChange(next.value);
      },
    };
  }

  private wireLibraryNavigation(
    categories: FocusableElement[],
    posters: FocusableElement[],
    startPosterIndex = 0,
  ): void {
    const categoryCount = categories.length;
    const columns = 6;
    const activeCategoryIndex = Math.max(
      0,
      categories.findIndex((item) => item.el.classList.contains("active")),
    );
    categories.forEach((item, index) => {
      item.onUp = () => {
        if (index <= 0) return false;
        this.contentFocus.focusIndex(index - 1);
        return true;
      };
      item.onDown = () => {
        if (index >= categoryCount - 1) return false;
        this.contentFocus.focusIndex(index + 1);
        return true;
      };
      item.onRight = () => {
        if (!posters.length) return false;
        this.contentFocus.focusIndex(categoryCount);
        return true;
      };
    });
    for (let index = startPosterIndex; index < posters.length; index += 1) {
      const item = posters[index]!;
      item.onLeft = () => {
        if (index % columns === 0) {
          this.contentFocus.focusIndex(activeCategoryIndex);
          return true;
        }
        this.contentFocus.focusIndex(categoryCount + index - 1);
        return true;
      };
      item.onRight = () => {
        if (index % columns === columns - 1 || index >= posters.length - 1) return false;
        this.contentFocus.focusIndex(categoryCount + index + 1);
        return true;
      };
      item.onUp = () => {
        if (index < columns) return false;
        this.contentFocus.focusIndex(categoryCount + index - columns);
        return true;
      };
      item.onDown = () => {
        const next = index + columns;
        if (next >= posters.length) return false;
        this.contentFocus.focusIndex(categoryCount + next);
        return true;
      };
    }
  }

  private async renderSeriesDetail(show: SeriesShow): Promise<void> {
    this.contentBackAction = () => {
      this.contentBackAction = null;
      void this.renderSeries();
    };
    clearElement(this.content);
    this.content.append(pageHeader("Serie", show.name));
    const loading = el("div", "loading-panel", "Caricamento episodi…");
    this.content.append(loading);
    try {
      const info = await this.catalog.loadSeriesInfo(show.id);
      loading.remove();
      const detail = el("div", "media-detail");
      if (show.logo) {
        const image = document.createElement("img");
        image.className = "detail-poster";
        image.src = show.logo;
        image.alt = show.name;
        detail.append(image);
      }
      const copy = el("div", "detail-copy");
      copy.append(
        el("h2", "detail-title", show.name),
        el(
          "p",
          "hero-copy",
          [info.show.year || show.year, info.show.genre || show.genre, info.show.rating || show.rating]
            .filter(Boolean)
            .join(" · "),
        ),
        el("p", "hero-copy", info.show.plot || show.plot || "Descrizione non disponibile."),
      );
      detail.append(copy);
      this.content.append(detail);

      const episodeHost = el("div", "episode-list");
      const episodeItems = info.episodes.slice(0, 300).map((episode) => {
        const saved = loadProgress(progressKey("episode", episode.id));
        const resumeLabel = canResume(saved)
          ? ` · Riprendi ${Math.floor(progressFraction(saved) * 100)}%`
          : "";
        const button = el(
          "button",
          "episode-card focusable panel",
          `${episode.season > 0 ? `S${episode.season} ` : ""}${
            episode.episode > 0 ? `E${episode.episode} · ` : ""
          }${episode.title}${resumeLabel}`,
        );
        if (canResume(saved)) {
          const progress = el("span", "episode-progress");
          progress.style.width = `${progressFraction(saved) * 100}%`;
          button.append(progress);
        }
        button.type = "button";
        episodeHost.append(button);
        return {
          el: button,
          onActivate: () =>
            this.playSeriesEpisode(
              episode,
              show.name,
              show.logo,
            ),
        };
      });
      this.content.append(episodeHost);
      this.contentFocus.setItems(episodeItems);
    } catch (error) {
      loading.textContent = `Episodi non disponibili: ${
        error instanceof Error ? error.message : String(error)
      }`;
    }
  }

  private playSeriesEpisode(
    episode: SeriesEpisode,
    showName: string,
    showLogo = "",
  ): void {
    const profile = this.catalog.activeProfile;
    if (!profile) return;
    const key = progressKey("episode", episode.id);
    const saved = loadProgress(key);
    this.openFullscreenUrl(
      seriesUrl(profile, episode.id, episode.containerExtension),
      `${showName} · ${episode.title}`,
      null,
      {
        metadata: {
          key,
          kind: "episode",
          mediaId: episode.id,
          title: `${showName} · ${episode.title}`,
          logo: showLogo || episode.image,
          containerExtension: episode.containerExtension,
        },
        startPositionMs: canResume(saved) ? saved.positionMs : 0,
      },
    );
  }

  private renderSearch(): void {
    this.content.append(pageHeader("Cerca", "Canali, film e serie"));
    const searchRow = el("div", "search-row panel");
    const input = document.createElement("input");
    input.className = "search-input focusable";
    input.placeholder = "Scrivi cosa vuoi cercare";
    const searchButton = el("button", "settings-btn focusable panel", "Cerca");
    searchButton.type = "button";
    searchRow.append(input, searchButton);
    const results = el("div", "search-results");
    this.content.append(searchRow, results);

    const inputItem = {
      el: input,
      onActivate: () => input.focus(),
    };
    const buttonItem = {
      el: searchButton,
      onActivate: () => void this.runSearch(input.value, results, [inputItem, buttonItem]),
    };
    this.contentFocus.setItems([inputItem, buttonItem]);
  }

  private async runSearch(
    rawQuery: string,
    host: HTMLElement,
    fixedItems: Array<{ el: HTMLElement; onActivate?: () => void }>,
  ): Promise<void> {
    const query = rawQuery.trim().toLocaleLowerCase();
    clearElement(host);
    if (!query) {
      host.append(el("div", "empty", "Inserisci almeno una parola."));
      return;
    }
    host.append(el("div", "loading-panel", "Ricerca in corso…"));
    const [movies, series] = await Promise.all([
      this.catalog.loadMovies("").catch(() => []),
      this.catalog.loadSeries("").catch(() => []),
    ]);
    clearElement(host);
    const liveMatches = this.catalog.liveChannels
      .filter((item) => item.name.toLocaleLowerCase().includes(query))
      .slice(0, 24);
    const movieMatches = movies
      .filter((item) => item.name.toLocaleLowerCase().includes(query))
      .slice(0, 40);
    const seriesMatches = series
      .filter((item) => item.name.toLocaleLowerCase().includes(query))
      .slice(0, 40);
    const focusItems: Array<{ el: HTMLElement; onActivate?: () => void }> = [...fixedItems];

    if (liveMatches.length) {
      host.append(el("h2", "section-title", "Live TV"));
      const row = el("div", "result-row");
      for (const channel of liveMatches) {
        const button = el("button", "result-card focusable panel", channel.name);
        button.type = "button";
        row.append(button);
        focusItems.push({
          el: button,
          onActivate: () => this.openFullscreenChannel(channel),
        });
      }
      host.append(row);
    }
    if (movieMatches.length) {
      host.append(el("h2", "section-title", "Film"));
      const rowHost = el("div");
      host.append(rowHost);
      focusItems.push(
        ...renderPosterRow(rowHost, movieMatches, (movie) => {
          const url = playbackUrlForMovie(this.catalog, movie);
          if (url) this.openFullscreenUrl(url, movie.name);
        }),
      );
    }
    if (seriesMatches.length) {
      host.append(el("h2", "section-title", "Serie"));
      const rowHost = el("div");
      host.append(rowHost);
      focusItems.push(
        ...renderSeriesPosterRow(rowHost, seriesMatches, (show) => {
          void this.renderSeriesDetail(show);
        }),
      );
    }
    if (focusItems.length === fixedItems.length) {
      host.append(el("div", "empty", "Nessun risultato."));
    }
    this.contentFocus.setItems(focusItems);
  }

  private async renderGuide(): Promise<void> {
    clearElement(this.content);
    this.content.append(pageHeader("Guida TV", "Programmi e archivio"));
    const categories = this.catalog.liveCategories;
    if (!this.guideCategoryId) {
      this.guideCategoryId =
        categories.find((item) => item.name.toLocaleLowerCase().includes("italia"))?.id ??
        categories[0]?.id ??
        "";
    }
    const categoryHost = el("div", "preset-row category-strip");
    const categoryButtons = categories.slice(0, 40).map((category) => {
      const button = el("button", "preset-chip focusable panel", category.name);
      button.type = "button";
      if (category.id === this.guideCategoryId) button.classList.add("active");
      return {
        el: button,
        onActivate: () => {
          this.guideCategoryId = category.id;
          void this.renderGuide();
        },
      };
    });
    categoryHost.append(...categoryButtons.map((item) => item.el));
    const channels = this.catalog
      .channelsForCategory(this.guideCategoryId)
      .filter(isPlayableChannel)
      .slice(0, 160);
    if (!channels.some((channel) => channel.id === this.guideChannelId)) {
      this.guideChannelId = channels[0]?.id ?? 0;
    }
    const selectedChannel = () =>
      channels.find((channel) => channel.id === this.guideChannelId) ?? channels[0] ?? null;
    const lookbackDays = Math.min(
      14,
      Math.max(7, selectedChannel()?.catchupDays ?? 0),
    );
    if (this.guideDayOffset < -lookbackDays) this.guideDayOffset = -lookbackDays;

    const dayHost = el("div", "guide-day-strip panel");
    const dayOffsets = Array.from({ length: lookbackDays + 2 }, (_, index) =>
      index - lookbackDays,
    );
    const dayLabel = (offset: number): string => {
      if (offset === 0) return "Oggi";
      if (offset === -1) return "Ieri";
      if (offset === 1) return "Domani";
      const date = new Date();
      date.setDate(date.getDate() + offset);
      return date.toLocaleDateString("it-IT", { weekday: "short", day: "2-digit" });
    };
    const dayButtons: FocusableElement[] = dayOffsets.map((offset) => {
      const button = el("button", "preset-chip focusable panel", dayLabel(offset));
      button.type = "button";
      if (offset === this.guideDayOffset) button.classList.add("active");
      return {
        el: button,
        onActivate: () => {
          this.guideDayOffset = offset;
          dayButtons.forEach((item, index) => {
            item.el.classList.toggle("active", dayOffsets[index] === offset);
          });
          const channel = selectedChannel();
          if (channel) void renderProgrammes(channel);
        },
      };
    });
    dayHost.append(...dayButtons.map((item) => item.el));

    const body = el("div", "guide-layout");
    const channelsHost = el("div", "guide-channels panel");
    const programmesHost = el("div", "guide-programmes panel");
    body.append(channelsHost, programmesHost);
    this.content.append(categoryHost, dayHost, body);

    const fixedItems: FocusableElement[] = [
      ...categoryButtons,
      ...dayButtons,
    ];
    const channelItems: FocusableElement[] = [];
    const renderProgrammes = async (
      channel: LiveChannel,
      focusProgrammes = false,
    ): Promise<void> => {
      const generation = ++this.guideLoadGeneration;
      this.guideChannelId = channel.id;
      channelItems.forEach((item, index) => {
        item.el.classList.toggle("selected", channels[index]?.id === channel.id);
      });
      clearElement(programmesHost);
      programmesHost.append(el("div", "loading-panel", "Caricamento EPG…"));
      const programmes = await this.catalog.loadEpg(channel);
      if (generation !== this.guideLoadGeneration) return;
      clearElement(programmesHost);
      const now = Date.now();
      const dayStart = new Date(now);
      dayStart.setHours(0, 0, 0, 0);
      dayStart.setDate(dayStart.getDate() + this.guideDayOffset);
      const dayEnd = new Date(dayStart);
      dayEnd.setDate(dayEnd.getDate() + 1);
      const visibleProgrammes = programmes.filter(
        (programme) =>
          programme.endTimeMillis > dayStart.getTime() &&
          programme.startTimeMillis < dayEnd.getTime(),
      );
      programmesHost.append(
        el(
          "div",
          "guide-programme-heading",
          `${channel.name} · ${dayLabel(this.guideDayOffset)} · ${visibleProgrammes.length} programmi`,
        ),
      );
      if (!visibleProgrammes.length) {
        programmesHost.append(el("div", "empty", "Nessun programma per questo giorno"));
      }
      const currentIndex = currentProgrammeIndex(visibleProgrammes, now);
      const selectedChannelIndex = Math.max(
        0,
        channels.findIndex((item) => item.id === channel.id),
      );
      const programmeItems: FocusableElement[] = visibleProgrammes.map((programme, index) => {
        const live = index === currentIndex;
        const replay = canReplayProgramme(channel, programme, now);
        const past = programme.endTimeMillis <= now;
        const row = el(
          "button",
          `guide-programme focusable${live ? " epg-live" : ""}${replay ? " epg-replay" : ""}`,
        );
        row.type = "button";
        row.append(
          el(
            "span",
            "meta",
            `${new Date(programme.startTimeMillis).toLocaleTimeString("it-IT", {
              hour: "2-digit",
              minute: "2-digit",
            })} - ${new Date(programme.endTimeMillis).toLocaleTimeString("it-IT", {
              hour: "2-digit",
              minute: "2-digit",
            })}${live ? " · LIVE" : replay ? " · ARCHIVIO" : past ? " · TERMINATO" : ""}`,
          ),
          el("span", "name", programme.title),
          el("span", "description", programme.description),
        );
        programmesHost.append(row);
        return {
          el: row,
          onActivate: () => this.playGuideProgramme(channel, programme),
          onLeft: () => {
            this.contentFocus.focusIndex(
              fixedItems.length + selectedChannelIndex,
            );
            return true;
          },
        };
      });
      this.contentFocus.setItems([...fixedItems, ...channelItems, ...programmeItems]);
      if (focusProgrammes && programmeItems.length) {
        this.contentFocus.focusIndex(fixedItems.length + channelItems.length);
      }
      const liveRow = programmesHost.querySelector<HTMLElement>(".epg-live");
      if (liveRow && this.guideDayOffset === 0) {
        liveRow.scrollIntoView({ block: "center" });
      }
    };
    for (const channel of channels) {
      const button = el("button", "guide-channel focusable", channel.name);
      button.type = "button";
      if (channel.id === this.guideChannelId) button.classList.add("selected");
      channelsHost.append(button);
      const item: FocusableElement = {
        el: button,
        onActivate: () => void renderProgrammes(channel, true),
        onRight: () => {
          void renderProgrammes(channel, true);
          return true;
        },
        onFocus: () => {
          if (this.guideChannelId !== channel.id) void renderProgrammes(channel);
        },
      };
      channelItems.push(item);
    }
    this.contentFocus.setItems([...fixedItems, ...channelItems]);
    const initial = selectedChannel();
    if (initial) void renderProgrammes(initial);
  }

  private playGuideProgramme(channel: LiveChannel, programme: EpgProgramme): void {
    const now = Date.now();
    if (programme.startTimeMillis <= now && programme.endTimeMillis > now) {
      this.openFullscreenChannel(channel);
      return;
    }
    const profile = this.catalog.activeProfile;
    const catchupUrls = profile ? catchupStreamUrls(profile, channel, programme) : [];
    if (catchupUrls.length) {
      this.openFullscreenUrl(catchupUrls[0]!, `${channel.name} · ${programme.title}`);
      return;
    }
    this.statusBar.textContent =
      programme.endTimeMillis < now
        ? "Archivio: supporto catch-up in completamento"
        : "Il programma non è ancora iniziato";
  }

  private renderSettings(): void {
    this.content.append(pageHeader("Le mie liste", "Configura il provider Xtream"));
    const savedProfiles = this.catalog.profiles;
    const savedHost = el("div", "saved-profiles");
    const savedItems: FocusableElement[] = [];
    for (const saved of savedProfiles) {
      const row = el("div", "saved-profile panel");
      const copy = el("div", "saved-profile-copy");
      copy.append(
        el("div", "name", saved.title || saved.serverUrl),
        el(
          "div",
          "meta",
          saved.serverUrl.replace(/^https?:\/\//i, "").replace(/\/.*$/, ""),
        ),
      );
      const useButton = el("button", "focusable", "Usa");
      const reloadButton = el("button", "focusable", "Ricarica");
      const removeButton = el("button", "focusable danger", "Rimuovi");
      useButton.type = reloadButton.type = removeButton.type = "button";
      const isActive =
        this.catalog.activeProfile?.serverUrl === saved.serverUrl &&
        this.catalog.activeProfile.username === saved.username;
      if (isActive) row.classList.add("active");
      if (isActive && this.catalog.accountExpiresAt) {
        copy.append(
          el(
            "div",
            "expiry",
            `Scade il ${new Date(
              this.catalog.accountExpiresAt,
            ).toLocaleDateString("it-IT")}`,
          ),
        );
      }
      row.append(copy, useButton, reloadButton, removeButton);
      savedHost.append(row);
      savedItems.push(
        {
          el: useButton,
          onActivate: () => {
            void this.catalog
              .selectProfile(saved)
              .then(() => this.router.navigate("home"));
          },
        },
        {
          el: reloadButton,
          onActivate: () => {
            void this.catalog.selectProfile(saved).then(() => {
              void this.catalog
                .refreshCatalog(true)
                .then(() => this.router.navigate("home"));
            });
          },
        },
        {
          el: removeButton,
          onActivate: () => {
            void this.catalog.deleteProfile(saved).then(() => {
              this.router.navigate("settings", { force: true });
            });
          },
        },
      );
    }
    if (savedProfiles.length) {
      this.content.append(savedHost);
    }

    const form = el("div", "settings-form panel");
    form.style.padding = "28px";

    const profile = this.catalog.activeProfile;
    const titleInput = document.createElement("input");
    titleInput.placeholder = "Codice lista (es. ITALIA1)";

    const serverInput = document.createElement("input");
    serverInput.placeholder = "Server";

    const userInput = document.createElement("input");
    userInput.placeholder = "Username";

    const passInput = document.createElement("input");
    passInput.type = "password";
    passInput.placeholder = "Password";

    const applyTypedPreset = (): void => {
      const preset = resolvePreset(titleInput.value);
      if (!preset) return;
      serverInput.value = preset.serverUrl;
      userInput.value = preset.username;
      passInput.value = preset.password;
    };
    titleInput.addEventListener("input", applyTypedPreset);
    titleInput.addEventListener("change", applyTypedPreset);

    const connectBtn = el("button", "focusable panel settings-btn", "Connetti e carica catalogo");
    connectBtn.type = "button";

    const reloadBtn = el("button", "focusable panel settings-btn", "Ricarica dal provider");
    reloadBtn.type = "button";
    reloadBtn.hidden = !profile;

    const cacheHint = el(
      "p",
      "hero-copy",
      profile ? "Cache catalogo 24h. Ricarica forza un nuovo download dal provider." : "",
    );
    cacheHint.hidden = !profile;

    const fields: { label: string; input: HTMLInputElement }[] = [
      { label: "Titolo / codice lista", input: titleInput },
      { label: "Server", input: serverInput },
      { label: "Username", input: userInput },
      { label: "Password", input: passInput },
    ];
    for (const field of fields) {
      const block = el("div");
      block.append(el("label", "", field.label), field.input);
      form.append(block);
    }
    form.append(connectBtn, reloadBtn, cacheHint);
    this.content.append(form);

    const fieldItems = fields.map(({ input }) => ({
      el: input,
      onActivate: () => input.focus(),
    }));
    const items = [
      ...savedItems,
      ...fieldItems,
      {
        el: connectBtn,
        onActivate: () => {
          const next = profileFromForm(
            titleInput.value,
            serverInput.value,
            userInput.value,
            passInput.value,
          );
          if (!next) {
            this.statusBar.textContent = "Compila tutti i campi";
            this.statusBar.classList.add("error");
            return;
          }
          void this.catalog.connect(next).then(() => this.router.navigate("home"));
        },
      },
      {
        el: reloadBtn,
        onActivate: () => {
          if (!this.catalog.activeProfile) return;
          void this.catalog.refreshCatalog(true);
        },
      },
    ];
    this.contentFocus.setItems(items);
  }

  private renderPlaceholder(route: TvRoute): void {
    const label = NAV_ITEMS.find((i) => i.route === route)?.label ?? route;
    this.content.append(
      pageHeader("In arrivo", label),
      el("p", "hero-copy", "Questa sezione verrà allineata alla app Android TV nelle prossime iterazioni."),
    );
    this.contentFocus.setItems([]);
  }

  private openFullscreenChannel(channel: LiveChannel): void {
    const profile = this.catalog.activeProfile;
    if (!profile) return;
    this.liveScreen?.setFullscreenActive(true);
    const url = liveStreamUrls(profile, channel.id)[0];
    if (url) this.openFullscreenUrl(url, channel.name, channel);
  }

  private openFullscreenUrl(
    url: string,
    title: string,
    channel: LiveChannel | null = null,
    playback: PlaybackOptions | null = null,
  ): void {
    this.fullscreen = true;
    this.fullscreenChannel = channel;
    this.fullscreenProgressMeta = playback?.metadata ?? null;
    this.fullscreenOnClose = playback?.onClose ?? null;
    this.lastProgressSaveAt = 0;
    setVisible(this.root, false);
    setVisible(this.playerLayer, true);
    clearElement(this.playerLayer);
    const overlay = el("div", "player-overlay");
    const playerHint = channel
      ? "OK controlli · Su/Giù cambia canale · Back esce"
      : "OK controlli · Back esce";
    overlay.innerHTML = `
      <div class="player-error"></div>
      <div class="player-controls">
        <div class="player-context">
          <div>
            <div class="player-title"></div>
            <div class="player-epg">
              <span class="player-programme-title">Programma in caricamento…</span>
              <span class="player-programme-time"></span>
            </div>
          </div>
          <div class="player-hint"></div>
        </div>
        <div class="player-scrubber">
          <div class="player-progress"><span></span><i></i></div>
          <div class="player-time">00:00 / 00:00</div>
        </div>
        <div class="player-actions">
          <button>Play/Pausa</button><button>-10s</button><button>+10s</button>
          <button>Audio</button><button>Sottotitoli</button><button>Velocità 1x</button>
          <button>Chiudi</button>
        </div>
      </div>`;
    const titleNode = overlay.querySelector(".player-title");
    if (titleNode) titleNode.textContent = title;
    const hintNode = overlay.querySelector(".player-hint");
    if (hintNode) hintNode.textContent = playerHint;
    this.playerLayer.appendChild(overlay);
    this.fullscreenControlsVisible = false;
    this.fullscreenControlIndex = 1;
    this.fullscreenAudioIndex = -1;
    this.fullscreenSubtitleIndex = -1;
    this.fullscreenSpeedIndex = 2;
    this.updateFullscreenControls();
    if (channel) void this.updateFullscreenEpg(channel);
    this.showFullscreenControls();
    this.fullscreenProgressTimer = window.setInterval(
      () => this.updateFullscreenProgress(),
      500,
    );

    const profile = this.catalog.activeProfile;
    const referer = profile ? `${profileBaseUrl(profile)}/` : "";

    if (this.useAvplay()) {
      this.avplay.open(url, title, {
        referer,
        live: url.includes("/live/"),
        startPositionMs: playback?.startPositionMs ?? 0,
      });
      this.avplay.setFullscreen();
    } else {
      const box = el("div");
      box.style.width = "100%";
      box.style.height = "100%";
      this.playerLayer.insertBefore(box, this.playerLayer.firstChild);
      this.htmlPreview.mount(box);
      this.htmlPreview.open(url, playback?.startPositionMs ?? 0);
    }
  }

  private closeFullscreen(): void {
    if (!this.fullscreen) return;
    this.persistPlaybackProgress(true);
    const onClose = this.fullscreenOnClose;
    this.fullscreen = false;
    this.fullscreenChannel = null;
    this.fullscreenProgressMeta = null;
    this.fullscreenOnClose = null;
    this.liveScreen?.setFullscreenActive(false);
    setVisible(this.playerLayer, false);
    this.avplay.stop();
    this.htmlPreview.stop();
    if (this.fullscreenUiTimer !== null) window.clearTimeout(this.fullscreenUiTimer);
    if (this.fullscreenProgressTimer !== null) window.clearInterval(this.fullscreenProgressTimer);
    this.fullscreenUiTimer = null;
    this.fullscreenProgressTimer = null;
    clearElement(this.playerLayer);
    setVisible(this.root, true);
    if (onClose) onClose();
    else if (this.router.current === "home") {
      clearElement(this.content);
      this.renderHome();
    }
  }

  private showFullscreenControls(): void {
    this.fullscreenControlsVisible = true;
    this.updateFullscreenControls();
    if (this.fullscreenUiTimer !== null) window.clearTimeout(this.fullscreenUiTimer);
    this.fullscreenUiTimer = window.setTimeout(() => {
      this.fullscreenControlsVisible = false;
      this.updateFullscreenControls();
    }, 5000);
  }

  private updateFullscreenControls(): void {
    const controls = this.playerLayer.querySelector<HTMLElement>(".player-controls");
    if (!controls) return;
    controls.classList.toggle("visible", this.fullscreenControlsVisible);
    const scrubber = controls.querySelector<HTMLElement>(".player-scrubber");
    scrubber?.classList.toggle(
      "focused",
      this.fullscreenControlsVisible && this.fullscreenControlIndex === 0,
    );
    const actions = Array.from(controls.querySelectorAll<HTMLButtonElement>("button"));
    actions.forEach((button, index) => {
      button.classList.toggle(
        "focused",
        this.fullscreenControlsVisible && index + 1 === this.fullscreenControlIndex,
      );
    });
    this.updateFullscreenTrackLabels(actions);
  }

  private updateFullscreenTrackLabels(actions?: HTMLButtonElement[]): void {
    const buttons =
      actions ??
      Array.from(
        this.playerLayer.querySelectorAll<HTMLButtonElement>(".player-actions button"),
      );
    const audio = this.avplay.trackLabels("AUDIO");
    const subtitles = this.avplay.trackLabels("TEXT");
    if (buttons[3]) {
      buttons[3].textContent =
        this.fullscreenAudioIndex >= 0
          ? audio[this.fullscreenAudioIndex] ?? "Audio"
          : audio.length
            ? `Audio · ${audio.length} tracce`
            : "Audio —";
    }
    if (buttons[4]) {
      buttons[4].textContent =
        this.fullscreenSubtitleIndex >= 0
          ? subtitles[this.fullscreenSubtitleIndex] ?? "Sottotitoli"
          : subtitles.length
            ? `Sottotitoli off · ${subtitles.length}`
            : "Sottotitoli —";
    }
  }

  private updateFullscreenProgress(): void {
    const duration = this.avplay.getDuration();
    const position = this.avplay.getCurrentTime();
    const progress = this.playerLayer.querySelector<HTMLElement>(".player-progress span");
    const thumb = this.playerLayer.querySelector<HTMLElement>(".player-progress i");
    const time = this.playerLayer.querySelector<HTMLElement>(".player-time");
    const progressPercent =
      duration > 0 ? Math.min(100, (position / duration) * 100) : 0;
    if (progress) {
      progress.style.width = `${progressPercent}%`;
    }
    if (thumb) thumb.style.left = `${progressPercent}%`;
    if (time) time.textContent = `${this.formatTime(position)} / ${this.formatTime(duration)}`;
    this.updateFullscreenTrackLabels();
    this.persistPlaybackProgress();
  }

  private persistPlaybackProgress(force = false): void {
    const metadata = this.fullscreenProgressMeta;
    if (!metadata) return;
    const now = Date.now();
    if (!force && now - this.lastProgressSaveAt < 5_000) return;
    const duration = this.avplay.getDuration();
    const position = this.avplay.getCurrentTime();
    if (duration <= 0) return;
    saveProgress(metadata, position, duration);
    this.lastProgressSaveAt = now;
  }

  private async updateFullscreenEpg(channel: LiveChannel): Promise<void> {
    const programmes = await this.catalog.loadEpg(channel);
    if (!this.fullscreen || this.fullscreenChannel?.id !== channel.id) return;
    const now = Date.now();
    const currentIndex = currentProgrammeIndex(programmes, now);
    const current = currentIndex >= 0 ? programmes[currentIndex] : null;
    const titleNode =
      this.playerLayer.querySelector<HTMLElement>(".player-programme-title");
    const timeNode =
      this.playerLayer.querySelector<HTMLElement>(".player-programme-time");
    if (!titleNode || !timeNode) return;
    titleNode.textContent = current?.title || "Programmazione non disponibile";
    timeNode.textContent = current
      ? `${this.formatClock(current.startTimeMillis)}–${this.formatClock(
          current.endTimeMillis,
        )}`
      : "";
  }

  private formatClock(milliseconds: number): string {
    return new Date(milliseconds).toLocaleTimeString("it-IT", {
      hour: "2-digit",
      minute: "2-digit",
    });
  }

  private formatTime(milliseconds: number): string {
    const total = Math.max(0, Math.floor(milliseconds / 1000));
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor((total % 3600) / 60);
    const seconds = total % 60;
    const pad = (value: number): string => String(value).padStart(2, "0");
    return hours > 0
      ? `${hours}:${pad(minutes)}:${pad(seconds)}`
      : `${pad(minutes)}:${pad(seconds)}`;
  }

  private activateFullscreenControl(): void {
    switch (this.fullscreenControlIndex) {
      case 0:
        break;
      case 1:
        this.avplay.togglePlayPause();
        break;
      case 2:
        this.avplay.seekBy(-10_000);
        break;
      case 3:
        this.avplay.seekBy(10_000);
        break;
      case 4:
        this.fullscreenAudioIndex = this.avplay.cycleTrack(
          "AUDIO",
          this.fullscreenAudioIndex,
        );
        break;
      case 5:
        this.fullscreenSubtitleIndex = this.avplay.cycleTrack(
          "TEXT",
          this.fullscreenSubtitleIndex,
        );
        break;
      case 6: {
        const speeds = [0.5, 0.75, 1, 1.25, 1.5, 2];
        this.fullscreenSpeedIndex = (this.fullscreenSpeedIndex + 1) % speeds.length;
        const speed = speeds[this.fullscreenSpeedIndex]!;
        this.avplay.setSpeed(speed);
        const button = this.playerLayer.querySelectorAll<HTMLButtonElement>(
          ".player-actions button",
        )[5];
        if (button) button.textContent = `Velocità ${speed}x`;
        break;
      }
      case 7:
        this.closeFullscreen();
        return;
    }
    this.showFullscreenControls();
  }

  private showExitDialog(): void {
    if (this.exitDialog) return;
    this.exitDialogIndex = 1;
    const overlay = el("div", "exit-overlay");
    const dialog = el("div", "exit-dialog panel");
    dialog.append(
      el("h2", "", "Vuoi uscire dall’applicazione?"),
      el("p", "", "La riproduzione corrente verrà interrotta."),
    );
    const actions = el("div", "exit-actions");
    const exitButton = el("button", "focusable", "Esci");
    const cancelButton = el("button", "focusable", "Annulla");
    exitButton.type = cancelButton.type = "button";
    actions.append(exitButton, cancelButton);
    dialog.append(actions);
    overlay.append(dialog);
    document.body.append(overlay);
    this.exitDialog = overlay;
    this.paintExitDialog();
  }

  private paintExitDialog(): void {
    const buttons = this.exitDialog?.querySelectorAll<HTMLButtonElement>("button");
    if (!buttons) return;
    Array.from(buttons).forEach((button, index) => {
      button.classList.toggle("focused", index === this.exitDialogIndex);
    });
  }

  private closeExitDialog(): void {
    this.exitDialog?.remove();
    this.exitDialog = null;
    this.navFocus.focusCurrent();
  }

  private exitApplication(): void {
    const tizenApi = globalThis as {
      tizen?: {
        application?: {
          getCurrentApplication?: () => { exit?: () => void };
        };
      };
    };
    try {
      tizenApi.tizen?.application?.getCurrentApplication?.().exit?.();
    } catch {
      window.close();
    }
  }

  private onKeyDown(event: KeyboardEvent): void {
    const mapped = mapKeyFromEvent(event);
    if (!mapped) return;
    event.preventDefault();
    event.stopPropagation();

    if (this.exitDialog) {
      if (mapped === "left" || mapped === "right") {
        this.exitDialogIndex = this.exitDialogIndex === 0 ? 1 : 0;
        this.paintExitDialog();
      } else if (mapped === "back") {
        this.closeExitDialog();
      } else if (mapped === "activate") {
        if (this.exitDialogIndex === 0) this.exitApplication();
        else this.closeExitDialog();
      }
      return;
    }

    if (this.fullscreen) {
      if (mapped === "back") {
        if (this.fullscreenControlsVisible) {
          this.fullscreenControlsVisible = false;
          this.updateFullscreenControls();
          return;
        }
        this.closeFullscreen();
        return;
      }
      if (mapped === "play_pause") {
        this.avplay.togglePlayPause();
        return;
      }
      if (mapped === "activate") {
        if (!this.fullscreenControlsVisible) {
          this.showFullscreenControls();
        } else {
          this.activateFullscreenControl();
        }
        return;
      }
      if (this.fullscreenControlsVisible) {
        if (
          this.fullscreenControlIndex === 0 &&
          (mapped === "left" || mapped === "right")
        ) {
          if (!this.fullscreenChannel) {
            this.avplay.seekBy(mapped === "right" ? 30_000 : -30_000);
          }
          this.showFullscreenControls();
        } else if (
          this.fullscreenControlIndex > 0 &&
          (mapped === "left" || mapped === "right")
        ) {
          const delta = mapped === "right" ? 1 : -1;
          this.fullscreenControlIndex =
            1 + ((this.fullscreenControlIndex - 1 + delta + 7) % 7);
          this.showFullscreenControls();
        } else if (mapped === "up") {
          if (this.fullscreenControlIndex > 0) {
            this.fullscreenControlIndex = 0;
            this.showFullscreenControls();
          } else {
            this.fullscreenControlsVisible = false;
            this.updateFullscreenControls();
          }
        } else if (mapped === "down") {
          if (this.fullscreenControlIndex === 0) {
            this.fullscreenControlIndex = 1;
            this.showFullscreenControls();
          } else {
            this.fullscreenControlsVisible = false;
            this.updateFullscreenControls();
          }
        }
        return;
      }
      if (mapped === "up" || mapped === "down") {
        const channel = this.liveScreen?.stepChannel(mapped === "down" ? 1 : -1);
        if (channel) {
          this.fullscreenChannel = channel;
          const profile = this.catalog.activeProfile;
          const url = profile ? liveStreamUrls(profile, channel.id)[0] : null;
          if (url) {
            const referer = profile ? `${profileBaseUrl(profile)}/` : "";
            if (this.useAvplay()) {
              this.avplay.open(url, channel.name, { referer, live: true });
              this.avplay.setFullscreen();
            } else {
              this.htmlPreview.open(url);
            }
            const title = this.playerLayer.querySelector(".player-title");
            if (title) title.textContent = channel.name;
            void this.updateFullscreenEpg(channel);
            this.showFullscreenControls();
          }
        }
      }
      return;
    }

    if (mapped === "back") {
      if (this.zone === "content") {
        if (this.contentBackAction) {
          this.contentBackAction();
          return;
        }
        this.contentFocus.clearFocus();
        this.zone = "nav";
        this.navFocus.focusIndex(NAV_ITEMS.findIndex((i) => i.route === this.router.current));
      } else {
        this.navFocus.clearFocus();
        this.showExitDialog();
      }
      return;
    }

    if (this.zone === "content" && this.router.current === "live" && this.liveScreen) {
      if (mapped === "left" && this.liveScreen.getColumn() === "categories") {
        this.zone = "nav";
        this.navFocus.focusIndex(NAV_ITEMS.findIndex((i) => i.route === "live"));
        return;
      }
      if (mapped !== "play_pause") {
        this.liveScreen.handleKey(mapped);
      }
      return;
    }

    if (mapped === "right" && this.zone === "nav") {
      this.zone = "content";
      this.navFocus.clearFocus();
      if (this.router.current === "live") {
        this.liveScreen?.focusColumn("categories");
      } else if (this.contentFocus.current()) {
        this.contentFocus.focusCurrent();
      } else {
        this.contentFocus.focusIndex(0);
      }
      return;
    }

    const manager = this.zone === "nav" ? this.navFocus : this.contentFocus;
    if (mapped === "activate") {
      manager.activate();
      return;
    }
    if (mapped === "up" || mapped === "down" || mapped === "left" || mapped === "right") {
      const moved = manager.move(mapped);
      if (!moved && mapped === "left" && this.zone === "content") {
        this.contentFocus.clearFocus();
        this.zone = "nav";
        this.navFocus.focusIndex(
          NAV_ITEMS.findIndex((item) => item.route === this.router.current),
        );
      }
    }
  }
}
