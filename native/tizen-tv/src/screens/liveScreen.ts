import { debounce } from "../app/debounce";
import type { FocusDirection } from "../app/focusManager";
import type { CatalogState } from "../state/catalogState";
import type { EpgProgramme, LiveCategory, LiveChannel } from "../data/models";
import {
  canReplayProgramme,
  isPlayableChannel,
  liveStreamUrls,
  profileBaseUrl,
} from "../data/models";
import type { AvplayPlayer, Html5PreviewPlayer } from "../player/avplay";
import { AvplayPlayer as AvplayPlayerClass } from "../player/avplay";
import { clearElement, el, formatEpgTime, pageHeader } from "../ui/renderUtils";
import { VirtualList } from "../ui/virtualList";

const CHANNEL_LIMIT = 400;
const EPG_DEBOUNCE_MS = 450;
const PREVIEW_DEBOUNCE_MS = 550;

export type LiveColumn = "categories" | "channels" | "epg";

export interface LiveScreenDeps {
  catalog: CatalogState;
  useAvplay: () => boolean;
  avplay: AvplayPlayer;
  htmlPreview: Html5PreviewPlayer;
  onFullscreen: (channel: LiveChannel) => void;
  onProgramme: (channel: LiveChannel, programme: EpgProgramme) => void;
  onStatus: (message: string, isError?: boolean) => void;
}

export class LiveScreen {
  private root = el("div", "live-screen");
  private previewPanel = el("div", "panel preview-box");
  private previewLabel = el("div", "placeholder", "Anteprima canale");
  private epgPanel = el("div", "panel list epg-panel");
  private fullscreenBtn = el("button", "focusable panel live-action-btn", "Schermo intero");
  private categoryList: VirtualList<LiveCategory>;
  private channelList: VirtualList<LiveChannel>;
  private column: LiveColumn = "categories";
  private categoryId = "";
  private selectedChannel: LiveChannel | null = null;
  private previewGeneration = 0;
  private epgGeneration = 0;
  private epgProgrammes: EpgProgramme[] = [];
  private epgIndex = 0;
  private mounted = false;

  private debouncedPreview: (channel: LiveChannel) => void;
  private debouncedEpg: (channel: LiveChannel) => void;

  constructor(private deps: LiveScreenDeps) {
    this.categoryList = new VirtualList<LiveCategory>(
      (c) => c.name,
      { rowHeight: 58, visibleRows: 13, emptyLabel: "Nessuna categoria" },
      undefined,
      (c) => c.id === this.categoryId,
    );
    this.channelList = new VirtualList<LiveChannel>(
      (c) => c.name,
      { rowHeight: 58, visibleRows: 13, emptyLabel: "Nessun canale" },
      (c) => c.logo || undefined,
    );

    const previewDebounced = debounce((channel: LiveChannel) => {
      void this.startPreview(channel);
    }, PREVIEW_DEBOUNCE_MS);
    this.debouncedPreview = previewDebounced;
    this.debouncedEpg = debounce((channel: LiveChannel) => {
      void this.loadEpg(channel);
    }, EPG_DEBOUNCE_MS);

    this.categoryList.setHandlers({
      onActivate: (category) => {
        if (this.categoryId !== category.id) {
          this.categoryId = category.id;
          this.reloadChannels(0);
        }
        this.focusColumn("channels");
      },
    });

    this.channelList.setHandlers({
      onFocusChange: (channel) => {
        this.selectedChannel = channel;
        this.debouncedPreview(channel);
        this.debouncedEpg(channel);
      },
      onActivate: (channel) => {
        this.selectedChannel = channel;
        this.deps.onFullscreen(channel);
      },
    });

    this.fullscreenBtn.type = "button";
    this.fullscreenBtn.addEventListener("click", () => {
      if (this.selectedChannel) this.deps.onFullscreen(this.selectedChannel);
    });
  }

  mount(parent: HTMLElement): void {
    if (this.mounted) this.unmount();
    this.mounted = true;
    clearElement(this.root);

    const count = this.deps.catalog.liveChannels.length;
    this.root.append(pageHeader("Live TV", `${count} canali`));

    const layout = el("div", "live-layout");
    layout.append(this.categoryList.element, this.channelList.element);

    this.previewPanel.append(this.previewLabel);
    const rightCol = el("div", "live-right-col");
    rightCol.append(this.previewPanel, this.epgPanel, this.fullscreenBtn);
    layout.append(rightCol);
    this.root.append(layout);
    parent.append(this.root);

    if (!this.categoryId) {
      this.categoryId = this.defaultCategoryId();
    }
    this.reloadCategories();
    this.reloadChannels(0);
    const channels = this.channels();
    if (channels[0]) {
      this.selectedChannel = channels[0];
      void this.startPreview(channels[0]);
      void this.loadEpg(channels[0]);
    }
    this.focusColumn("categories");
  }

  unmount(): void {
    this.previewGeneration += 1;
    this.epgGeneration += 1;
    this.deps.avplay.stop();
    this.deps.htmlPreview.stop();
    this.root.remove();
    this.mounted = false;
  }

  getSelectedChannel(): LiveChannel | null {
    return this.selectedChannel;
  }

  stepChannel(delta: -1 | 1): LiveChannel | null {
    if (!this.channelList.move(delta)) return null;
    return this.selectedChannel;
  }

  focusColumn(column: LiveColumn): void {
    this.column = column;
    this.categoryList.setActive(column === "categories");
    this.channelList.setActive(column === "channels");
    this.fullscreenBtn.classList.remove("focused");
    this.paintEpgFocus();
  }

  getColumn(): LiveColumn {
    return this.column;
  }

  handleKey(direction: FocusDirection | "activate"): boolean {
    if (direction === "left") {
      if (this.column === "channels") {
        this.focusColumn("categories");
        return true;
      }
      if (this.column === "epg") {
        this.focusColumn("channels");
        return true;
      }
      return false;
    }
    if (direction === "right") {
      if (this.column === "categories") {
        this.focusColumn("channels");
        return true;
      }
      if (this.column === "channels") {
        this.focusColumn("epg");
        return true;
      }
      return false;
    }
    if (direction === "activate") {
      if (this.column === "categories") return this.categoryList.activate();
      if (this.column === "channels") return this.channelList.activate();
      if (this.column === "epg" && this.selectedChannel) {
        const programme = this.epgProgrammes[this.epgIndex];
        if (programme) this.deps.onProgramme(this.selectedChannel, programme);
        else this.deps.onFullscreen(this.selectedChannel);
        return true;
      }
      return false;
    }
    const delta = direction === "up" ? -1 : 1;
    if (this.column === "categories") return this.categoryList.move(delta);
    if (this.column === "channels") return this.channelList.move(delta);
    if (this.column === "epg" && this.epgProgrammes.length) {
      const next = Math.max(
        0,
        Math.min(this.epgProgrammes.length - 1, this.epgIndex + delta),
      );
      if (next === this.epgIndex) return false;
      this.epgIndex = next;
      this.paintEpgFocus();
      return true;
    }
    return false;
  }

  private categories(): LiveCategory[] {
    return this.deps.catalog.liveCategories;
  }

  private channels(): LiveChannel[] {
    const all = this.deps.catalog
      .channelsForCategory(this.categoryId)
      .filter(isPlayableChannel);
    return all.slice(0, CHANNEL_LIMIT);
  }

  private defaultCategoryId(): string {
    const cats = this.categories();
    const italia = cats.find((c) => c.name.toLowerCase().includes("italia"));
    return italia?.id ?? cats.find((c) => c.id)?.id ?? "";
  }

  private reloadCategories(): void {
    const cats = this.categories();
    const index = Math.max(0, cats.findIndex((c) => c.id === this.categoryId));
    this.categoryList.setItems(cats, index >= 0 ? index : 0);
    if (cats[index]) this.categoryId = cats[index]!.id;
  }

  private reloadChannels(focusIndex: number): void {
    const channels = this.channels();
    const selectedIdx = this.selectedChannel
      ? channels.findIndex((c) => c.id === this.selectedChannel!.id)
      : -1;
    const index = selectedIdx >= 0 ? selectedIdx : focusIndex;
    this.channelList.setItems(channels, index, this.column === "channels");
    const channel = channels[index];
    if (channel) {
      this.selectedChannel = channel;
      if (this.column === "channels") {
        this.debouncedPreview(channel);
        this.debouncedEpg(channel);
      }
    } else {
      this.selectedChannel = null;
      this.previewLabel.textContent = "Nessun canale";
      clearElement(this.epgPanel);
      this.epgPanel.append(el("div", "empty", "EPG non disponibile"));
    }
  }

  private async startPreview(channel: LiveChannel): Promise<void> {
    const gen = ++this.previewGeneration;
    const profile = this.deps.catalog.activeProfile;
    if (!profile) return;
    const url = liveStreamUrls(profile, channel.id)[0];
    if (!url) return;

    this.previewLabel.textContent = channel.name;
    this.previewLabel.style.display = "";
    const rect = AvplayPlayerClass.rectForElement(this.previewPanel);
    const referer = `${profileBaseUrl(profile)}/`;

    if (this.deps.useAvplay()) {
      this.deps.avplay.open(url, channel.name, { rect, referer, live: true });
      window.setTimeout(() => {
        if (gen !== this.previewGeneration) return;
        this.deps.avplay.setPreviewRect(this.previewPanel);
        this.previewLabel.style.display = "none";
      }, 120);
    } else {
      this.deps.htmlPreview.mount(this.previewPanel);
      this.deps.htmlPreview.open(url);
    }
  }

  private async loadEpg(channel: LiveChannel): Promise<void> {
    const gen = ++this.epgGeneration;
    clearElement(this.epgPanel);
    this.epgPanel.append(el("div", "empty", "Caricamento EPG…"));
    const programmes = await this.deps.catalog.loadEpg(channel);
    if (gen !== this.epgGeneration) return;
    this.renderEpg(programmes);
  }

  private renderEpg(programmes: EpgProgramme[]): void {
    clearElement(this.epgPanel);
    if (!programmes.length) {
      this.epgProgrammes = [];
      this.epgIndex = 0;
      this.epgPanel.append(el("div", "empty", "EPG non disponibile"));
      return;
    }
    const now = Date.now();
    const sorted = [...programmes].sort(
      (a, b) => a.startTimeMillis - b.startTimeMillis,
    );
    const current = sorted.findIndex(
      (item) => now >= item.startTimeMillis && now < item.endTimeMillis,
    );
    const future = sorted.findIndex((item) => item.startTimeMillis > now);
    const anchor = current >= 0 ? current : future >= 0 ? future : sorted.length - 1;
    const start = Math.max(0, anchor - 3);
    this.epgProgrammes = sorted.slice(start, anchor + 4);
    this.epgIndex = Math.max(0, anchor - start);
    for (const item of this.epgProgrammes) {
      const row = el("div", "list-item epg-row");
      const live = now >= item.startTimeMillis && now < item.endTimeMillis;
      const replay = !!this.selectedChannel && canReplayProgramme(this.selectedChannel, item, now);
      if (live) row.classList.add("epg-live");
      if (replay) row.classList.add("epg-replay");
      const wrap = el("div");
      wrap.append(
        el("div", "name", item.title),
        el(
          "div",
          "meta",
          `${formatEpgTime(item.startTimeMillis)}${live ? " · LIVE" : replay ? " · ARCHIVIO" : ""}`,
        ),
      );
      row.append(wrap);
      this.epgPanel.append(row);
    }
    this.paintEpgFocus();
    const rows = Array.from(this.epgPanel.querySelectorAll<HTMLElement>(".epg-row"));
    rows[this.epgIndex]?.scrollIntoView({ block: "center" });
  }

  private paintEpgFocus(): void {
    const rows = Array.from(this.epgPanel.querySelectorAll<HTMLElement>(".epg-row"));
    rows.forEach((row, index) => {
      row.classList.toggle("focused", this.column === "epg" && index === this.epgIndex);
    });
    const current = rows[this.epgIndex];
    if (current && this.column === "epg") {
      current.scrollIntoView({ block: "nearest" });
    }
  }
}
