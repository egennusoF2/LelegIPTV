import { FocusManager, mapKeyToDirection, registerTvKeys } from "./app/focusManager";
import { NAV_ITEMS, Router, type TvRoute } from "./app/router";
import { profileFromForm, presetCodes } from "./data/profilePresets";
import type { LiveChannel, VodMovie } from "./data/models";
import { AvplayPlayer, Html5PreviewPlayer } from "./player/avplay";
import { CatalogState } from "./state/catalogState";
import { ensureWebapisLoaded, setVisible } from "./polyfills";
import {
  clearElement,
  el,
  formatEpgTime,
  pageHeader,
  playbackUrlForChannel,
  playbackUrlForMovie,
  renderChannelList,
  renderEpgList,
  renderPosterRow,
  setElementChildren,
} from "./ui/renderUtils";

type Zone = "nav" | "content";

export class LelegTvApp {
  private root = document.getElementById("app")!;
  private playerLayer = document.getElementById("player-layer")!;
  private statusBar = el("div", "status-bar");
  private router = new Router();
  private catalog = new CatalogState();
  private navFocus = new FocusManager();
  private contentFocus = new FocusManager();
  private zone: Zone = "nav";
  private avplay = new AvplayPlayer();
  private htmlPreview = new Html5PreviewPlayer();
  private fullscreen = false;
  private selectedChannel: LiveChannel | null = null;
  private liveCategoryId = "";
  private moviesCategoryId = "";
  private movies: VodMovie[] = [];

  private shell = el("div", "shell");
  private sidebar = el("nav", "sidebar");
  private content = el("main", "content");

  constructor() {
    registerTvKeys();
    document.body.append(this.statusBar);
    this.root.append(this.shell);
    this.shell.append(this.sidebar, this.content);

    this.catalog.onStatus((message, isError) => {
      this.statusBar.textContent = message;
      this.statusBar.classList.toggle("error", !!isError);
    });

    this.router.subscribe((route) => this.renderRoute(route));
    document.addEventListener("keydown", (event) => this.onKeyDown(event));

    void this.bootstrap();
  }

  private async bootstrap(): Promise<void> {
    this.renderNav();
    if (this.catalog.activeProfile) {
      try {
        await this.catalog.refreshCatalog(false);
      } catch {
        // handled via status
      }
    } else {
      this.statusBar.textContent = "Seleziona una lista in Le mie liste";
    }
    this.router.navigate(this.catalog.activeProfile ? "home" : "settings");
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
          this.router.navigate(item.route);
        },
      };
    });
    this.navFocus.setItems(items);
    this.sidebar.append(...items.map((i) => i.el));
  }

  private renderRoute(route: TvRoute): void {
    for (const button of Array.from(this.sidebar.querySelectorAll<HTMLElement>(".nav-item"))) {
      button.classList.toggle("active", button.dataset.route === route);
    }
    clearElement(this.content);
    switch (route) {
      case "home":
        this.renderHome();
        break;
      case "live":
        void this.renderLive();
        break;
      case "movies":
        void this.renderMovies();
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
    this.content.append(
      pageHeader("Benvenuto", "Leleg IPTV per Samsung TV"),
      el("p", "", `Canali live: ${this.catalog.liveChannels.length}`),
    );
    const grid = el("div", "hub-grid");
    const tiles = [
      { label: "Live TV", route: "live" as TvRoute },
      { label: "Film", route: "movies" as TvRoute },
      { label: "Le mie liste", route: "settings" as TvRoute },
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
    this.contentFocus.setItems(tiles);
  }

  private async renderLive(): Promise<void> {
    this.content.append(pageHeader("Live TV", `${this.catalog.liveChannels.length} canali`));
    const layout = el("div", "live-layout");
    layout.style.gridTemplateColumns = "240px 380px 1fr 360px";

    const categoriesPanel = el("div", "panel list");
    const channelsPanel = el("div", "panel list");
    const previewPanel = el("div", "panel preview-box");
    const epgPanel = el("div", "panel list");
    previewPanel.append(el("div", "placeholder", "Anteprima canale"));
    layout.append(categoriesPanel, channelsPanel, previewPanel, epgPanel);
    this.content.append(layout);

    const categories = this.catalog.liveCategories;
    const categoryButtons = categories.map((category, index) => {
      const btn = el("button", "list-item focusable", category.name);
      btn.type = "button";
      if (category.id === this.liveCategoryId) btn.classList.add("active");
      return {
        el: btn,
        onActivate: () => {
          this.liveCategoryId = category.id;
          void this.renderLive();
        },
        onUp: () => index > 0,
        onDown: () => index < categories.length - 1,
      };
    });
    categoriesPanel.append(...categoryButtons.map((c) => c.el));

    const channels = this.catalog.channelsForCategory(this.liveCategoryId);

    const onSelectChannel = async (channel: LiveChannel) => {
      this.selectedChannel = channel;
      const url = playbackUrlForChannel(this.catalog, channel);
      if (!url) return;
      if (this.avplay.isAvailable()) {
        this.avplay.open(url, channel.name);
        this.avplay.setPreviewRect(previewPanel);
      } else {
        this.htmlPreview.mount(previewPanel);
        this.htmlPreview.open(url);
      }
      const programmes = await this.catalog.loadEpg(channel);
      renderEpgList(
        epgPanel,
        programmes.slice(-12).map((p) => ({
          title: p.title,
          start: formatEpgTime(p.startTimeMillis),
        })),
      );
    };

    const channelItems = renderChannelList(channelsPanel, channels, this.selectedChannel?.id ?? null, (channel) => {
      void onSelectChannel(channel);
    });
    setElementChildren(channelsPanel, channelItems.map((i) => i.el));

    this.contentFocus.setItems([...categoryButtons, ...channelItems]);
    if (!this.selectedChannel && channels[0]) void onSelectChannel(channels[0]);
  }

  private async renderMovies(): Promise<void> {
    this.content.append(pageHeader("Film", "Catalogo on demand"));
    const top = el("div", "preset-row");
    const categories = this.catalog.vodCategories;
    const catButtons = categories.slice(0, 24).map((category, index) => {
      const btn = el("button", "preset-chip focusable panel", category.name);
      btn.type = "button";
      if (category.id === this.moviesCategoryId) btn.classList.add("active");
      return {
        el: btn,
        onActivate: () => {
          this.moviesCategoryId = category.id;
          void this.renderMovies();
        },
        onLeft: () => index > 0,
        onRight: () => index < Math.min(categories.length, 24) - 1,
      };
    });
    top.append(...catButtons.map((c) => c.el));
    this.content.append(top);

    const rowHost = el("div");
    this.content.append(rowHost);
    try {
      this.movies = await this.catalog.loadMovies(this.moviesCategoryId);
    } catch {
      this.movies = [];
    }
    const posters = renderPosterRow(rowHost, this.movies, (movie) => {
      const url = playbackUrlForMovie(this.catalog, movie);
      if (url) this.openFullscreen(url, movie.name);
    });
    this.contentFocus.setItems([...catButtons, ...posters]);
  }

  private renderSettings(): void {
    this.content.append(pageHeader("Le mie liste", "Configura il provider Xtream"));
    const form = el("div", "settings-form panel");
    form.style.padding = "24px";

    const profile = this.catalog.activeProfile;
    const titleInput = document.createElement("input");
    titleInput.value = profile?.title ?? "";
    titleInput.placeholder = "Codice lista (es. ITALIA1)";

    const serverInput = document.createElement("input");
    serverInput.value = profile?.serverUrl ?? "";
    serverInput.placeholder = "Server";

    const userInput = document.createElement("input");
    userInput.value = profile?.username ?? "";
    userInput.placeholder = "Username";

    const passInput = document.createElement("input");
    passInput.type = "password";
    passInput.value = profile?.password ?? "";
    passInput.placeholder = "Password";

    const presetRow = el("div", "preset-row");
    const presets = presetCodes().map((code, index) => {
      const chip = el("button", "preset-chip focusable panel", code);
      chip.type = "button";
      return {
        el: chip,
        onActivate: () => {
          titleInput.value = code;
        },
        onLeft: () => index > 0,
        onRight: () => index < presetCodes().length - 1,
      };
    });
    presetRow.append(...presets.map((p) => p.el));

    const connectBtn = el("button", "focusable panel", "Connetti e carica catalogo");
    connectBtn.type = "button";
    connectBtn.style.padding = "14px 18px";
    connectBtn.style.fontWeight = "800";

    const reloadBtn = el("button", "focusable panel", "Ricarica dal provider");
    reloadBtn.type = "button";
    reloadBtn.style.padding = "14px 18px";
    reloadBtn.style.fontWeight = "800";
    reloadBtn.hidden = !profile;

    const cacheHint = el(
      "p",
      "",
      profile
        ? "Cache catalogo 24h. Ricarica forza un nuovo download dal provider."
        : "",
    );
    cacheHint.style.color = "var(--muted)";
    cacheHint.style.fontSize = "14px";
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
    form.append(el("label", "", "Preset rapidi"), presetRow, connectBtn, reloadBtn, cacheHint);
    this.content.append(form);

    const items = [
      ...presets,
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
      el("p", "", "Questa sezione verrà allineata alla app Android TV nelle prossime iterazioni."),
    );
    this.contentFocus.setItems([]);
  }

  private openFullscreen(url: string, title: string): void {
    this.fullscreen = true;
    setVisible(this.playerLayer, true);
    clearElement(this.playerLayer);
    const overlay = el("div", "player-overlay");
    overlay.innerHTML = `
      <div class="top-bar">
        <div class="player-title"></div>
        <div class="player-hint">Back per uscire · Play/Pausa · ← → canale (live)</div>
      </div>`;
    const titleNode = overlay.querySelector(".player-title");
    if (titleNode) titleNode.textContent = title;
    this.playerLayer.appendChild(overlay);

    const useHtmlPreview = (): void => {
      const box = el("div");
      box.style.width = "100%";
      box.style.height = "100%";
      this.playerLayer.insertBefore(box, this.playerLayer.firstChild);
      this.htmlPreview.mount(box);
      this.htmlPreview.open(url);
    };

    void ensureWebapisLoaded()
      .then(() => {
        if (this.avplay.isAvailable()) {
          this.avplay.open(url, title);
          this.avplay.setFullscreen();
        } else {
          useHtmlPreview();
        }
      })
      .catch(() => useHtmlPreview());
  }

  private closeFullscreen(): void {
    if (!this.fullscreen) return;
    this.fullscreen = false;
    setVisible(this.playerLayer, false);
    this.avplay.stop();
    this.htmlPreview.stop();
    clearElement(this.playerLayer);
  }

  private onKeyDown(event: KeyboardEvent): void {
    const mapped = mapKeyToDirection(event.key);
    if (!mapped) return;
    event.preventDefault();

    if (this.fullscreen) {
      if (mapped === "back") {
        this.closeFullscreen();
        return;
      }
      if (mapped === "activate") {
        this.avplay.togglePlayPause();
        return;
      }
      if (mapped === "left" || mapped === "right") {
        this.switchChannel(mapped === "right" ? 1 : -1);
      }
      return;
    }

    if (mapped === "back") {
      if (this.zone === "content") {
        this.zone = "nav";
        this.navFocus.focusIndex(NAV_ITEMS.findIndex((i) => i.route === this.router.current));
      }
      return;
    }

    if (mapped === "left" && this.zone === "content") {
      this.zone = "nav";
      this.navFocus.focusIndex(NAV_ITEMS.findIndex((i) => i.route === this.router.current));
      return;
    }
    if (mapped === "right" && this.zone === "nav") {
      this.zone = "content";
      if (!this.contentFocus.current()) this.contentFocus.focusIndex(0);
      return;
    }

    const manager = this.zone === "nav" ? this.navFocus : this.contentFocus;
    if (mapped === "activate") {
      manager.activate();
      return;
    }
    if (mapped === "up" || mapped === "down" || mapped === "left" || mapped === "right") {
      manager.move(mapped);
    }
  }

  private switchChannel(direction: 1 | -1): void {
    if (!this.selectedChannel || this.router.current !== "live") return;
    const channels = this.catalog.channelsForCategory(this.liveCategoryId);
    const index = channels.findIndex((c) => c.id === this.selectedChannel!.id);
    if (index < 0) return;
    const next = channels[Math.max(0, Math.min(channels.length - 1, index + direction))];
    if (!next || next.id === this.selectedChannel.id) return;
    const url = playbackUrlForChannel(this.catalog, next);
    if (!url) return;
    this.selectedChannel = next;
    if (this.avplay.isAvailable()) {
      this.avplay.open(url, next.name);
      this.avplay.setFullscreen();
    } else {
      this.htmlPreview.open(url);
    }
    const title = this.playerLayer.querySelector(".player-title");
    if (title) title.textContent = next.name;
  }
}
