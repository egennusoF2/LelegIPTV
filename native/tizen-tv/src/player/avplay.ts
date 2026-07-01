import { alternateLiveUrl } from "../data/models";
import { ensureWebapisLoaded } from "../polyfills";

type AvplayListener = {
  onbufferingstart?: () => void;
  onbufferingcomplete?: () => void;
  oncurrentplaytime?: (ms: number) => void;
  onerror?: (event: unknown) => void;
  onerrormsg?: (event: unknown, message: string) => void;
  onstreamcompleted?: () => void;
};

type AvplayApi = {
  open: (url: string) => void;
  close: () => void;
  prepareAsync: (success: () => void, error: (e: unknown) => void) => void;
  play: () => void;
  pause: () => void;
  stop: () => void;
  getState: () => string;
  setDisplayRect: (x: number, y: number, w: number, h: number) => void;
  setDisplayMethod?: (method: string) => void;
  setListener: (listener: AvplayListener) => void;
  setStreamingProperty?: (property: string, value: string) => void;
  setBufferingParam?: (option: string, unit: string, amount: number) => void;
  getDuration?: () => number;
  getCurrentTime?: () => number;
  jumpForward?: (milliseconds: number, success?: () => void, error?: () => void) => void;
  jumpBackward?: (milliseconds: number, success?: () => void, error?: () => void) => void;
  seekTo?: (milliseconds: number, success?: () => void, error?: () => void) => void;
  setSpeed?: (speed: number) => void;
  getTotalTrackInfo?: () => Array<{
    type: string;
    index: number;
    extra_info?: string;
  }>;
  setSelectTrack?: (type: string, index: number) => void;
  setSilentSubtitle?: (silent: boolean) => void;
};

const UA = "VLC/3.0.20 LibVLC/3.0.20";

function avplay(): AvplayApi | null {
  const api = (globalThis as { webapis?: { avplay?: AvplayApi } }).webapis?.avplay;
  return api ?? null;
}

function avplayObject(): HTMLElement | null {
  return document.getElementById("av-player");
}

function screenSize(): { w: number; h: number } {
  return { w: 1920, h: 1080 };
}

function formatAvplayError(error: unknown): string {
  if (error === null || error === undefined) return "prepareAsync fallito";
  if (typeof error === "string") return error;
  if (typeof error === "number") return `AVPlay errore ${error}`;
  if (typeof error === "object" && error !== null) {
    const obj = error as Record<string, unknown>;
    if (typeof obj.message === "string") return obj.message;
    if (typeof obj.name === "string") return obj.name;
  }
  return "Errore riproduzione";
}

export type PlayerState = "idle" | "opening" | "buffering" | "playing" | "paused" | "error";

export type AvplayOpenOptions = {
  rect?: { x: number; y: number; w: number; h: number };
  referer?: string;
  live?: boolean;
  startPositionMs?: number;
};

export class AvplayPlayer {
  private state: PlayerState = "idle";
  private title = "";
  private pendingRect: { x: number; y: number; w: number; h: number } | null = null;
  private referer = "";
  private isLive = false;
  private startPositionMs = 0;
  private onState?: (state: PlayerState, title: string, detail?: string) => void;
  private openGeneration = 0;

  setStateListener(listener: (state: PlayerState, title: string, detail?: string) => void): void {
    this.onState = listener;
  }

  isAvailable(): boolean {
    return avplay() !== null;
  }

  open(url: string, title: string, options: AvplayOpenOptions = {}): void {
    const urls = [url, alternateLiveUrl(url)].filter((u): u is string => !!u);
    this.pendingRect = options.rect ?? null;
    this.referer = options.referer ?? "";
    this.isLive = !!options.live;
    this.startPositionMs = Math.max(0, options.startPositionMs ?? 0);
    const generation = ++this.openGeneration;
    void ensureWebapisLoaded()
      .then(() => this.openUrls(urls, title, generation))
      .catch(() => {
        this.setState("error", title, "AVPlay non disponibile");
      });
  }

  private openUrls(urls: string[], title: string, generation: number, index = 0): void {
    if (generation !== this.openGeneration) return;
    if (index >= urls.length) {
      this.setState("error", title, "Stream non riproducibile");
      return;
    }
    this.openWithAvplay(urls[index]!, title, generation, (detail) => {
      const next = urls[index + 1];
      if (next) this.openUrls(urls, title, generation, index + 1);
      else this.setState("error", title, detail);
    });
  }

  private configureStreaming(player: AvplayApi): void {
    try {
      player.setStreamingProperty?.("USER_AGENT", UA);
    } catch {
      // ignore
    }
    if (this.isLive) {
      try {
        player.setStreamingProperty?.("ADAPTIVE_INFO", "STARTBITRATE=HIGHEST");
      } catch {
        // ignore
      }
    }
    try {
      player.setBufferingParam?.("PLAYER_BUFFER_FOR_PLAY", "PLAYER_BUFFER_SIZE_IN_SECOND", 3);
    } catch {
      // ignore
    }
  }

  private openWithAvplay(
    url: string,
    title: string,
    generation: number,
    onFail: (detail: string) => void,
  ): void {
    const player = avplay();
    if (!player) {
      this.setState("error", title, "AVPlay non disponibile");
      return;
    }
    this.title = title;
    this.setObjectVisible(true);
    this.setState("opening", title);
    let failed = false;
    const fail = (detail: string): void => {
      if (failed || generation !== this.openGeneration) return;
      failed = true;
      try {
        player.stop();
      } catch {
        // Best effort cleanup before trying the alternate container.
      }
      try {
        player.close();
      } catch {
        // Best effort cleanup before trying the alternate container.
      }
      this.setObjectVisible(false);
      onFail(detail);
    };

    try {
      player.stop();
    } catch {
      // ignore
    }
    try {
      player.close();
    } catch {
      // ignore
    }

    player.setListener({
      onbufferingstart: () => {
        if (generation === this.openGeneration) this.setState("buffering", title);
      },
      onbufferingcomplete: () => {
        if (generation === this.openGeneration) this.setState("playing", title);
      },
      onerror: (event) => {
        const detail = formatAvplayError(event);
        console.error("[AVPlay] onerror", detail, url);
        fail(detail);
      },
      onerrormsg: (event, message) => {
        const detail = message || formatAvplayError(event);
        console.error("[AVPlay] onerrormsg", detail, url);
        fail(detail);
      },
      onstreamcompleted: () => {
        if (generation !== this.openGeneration) return;
        if (this.isLive) {
          console.warn("[AVPlay] live stream completed; trying alternate container", url);
          fail("Diretta terminata prematuramente");
        } else {
          this.setState("paused", title);
        }
      },
    });

    try {
      player.open(url);
      this.configureStreaming(player);
      player.setDisplayMethod?.("PLAYER_DISPLAY_MODE_LETTER_BOX");
      this.applyPendingRect(player);

      player.prepareAsync(
        () => {
          if (generation !== this.openGeneration) return;
          this.applyPendingRect(player);
          const play = (): void => {
            if (generation !== this.openGeneration) return;
            player.play();
            this.setState("playing", title);
          };
          if (this.startPositionMs >= 15_000 && player.seekTo) {
            try {
              player.seekTo(this.startPositionMs, play, play);
            } catch {
              play();
            }
          } else {
            play();
          }
        },
        (error) => {
          const detail = formatAvplayError(error);
          console.error("[AVPlay] prepareAsync", detail, url);
          fail(detail);
        },
      );
    } catch (error) {
      fail(formatAvplayError(error));
    }
  }

  private applyPendingRect(player: AvplayApi): void {
    if (this.pendingRect) {
      const { x, y, w, h } = this.pendingRect;
      if (w > 0 && h > 0) {
        player.setDisplayRect(x, y, w, h);
        this.setObjectRect(x, y, w, h);
      }
      return;
    }
    const { w, h } = screenSize();
    player.setDisplayRect(0, 0, w, h);
    this.setObjectRect(0, 0, w, h);
  }

  private setObjectVisible(visible: boolean): void {
    const object = avplayObject();
    if (object) object.style.visibility = visible ? "visible" : "hidden";
  }

  private setObjectRect(x: number, y: number, w: number, h: number): void {
    const object = avplayObject();
    if (!object) return;
    object.style.left = `${x}px`;
    object.style.top = `${y}px`;
    object.style.width = `${w}px`;
    object.style.height = `${h}px`;
  }

  play(): void {
    avplay()?.play();
    this.setState("playing", this.title);
  }

  pause(): void {
    avplay()?.pause();
    this.setState("paused", this.title);
  }

  togglePlayPause(): void {
    if (this.state === "playing") this.pause();
    else this.play();
  }

  getState(): PlayerState {
    return this.state;
  }

  getDuration(): number {
    try {
      return Math.max(0, avplay()?.getDuration?.() ?? 0);
    } catch {
      return 0;
    }
  }

  getCurrentTime(): number {
    try {
      return Math.max(0, avplay()?.getCurrentTime?.() ?? 0);
    } catch {
      return 0;
    }
  }

  seekBy(milliseconds: number): void {
    const player = avplay();
    if (!player || !milliseconds) return;
    try {
      if (milliseconds > 0) player.jumpForward?.(milliseconds);
      else player.jumpBackward?.(Math.abs(milliseconds));
    } catch {
      // Some live streams do not support seeking.
    }
  }

  setSpeed(speed: number): void {
    try {
      avplay()?.setSpeed?.(speed);
    } catch {
      // Unsupported by some live/adaptive streams.
    }
  }

  trackLabels(type: "AUDIO" | "TEXT"): string[] {
    return this.tracks(type).map((track, index) => {
      let language = "";
      try {
        const extra = JSON.parse(track.extra_info || "{}") as Record<string, unknown>;
        language = String(
          extra.language ??
            extra.lang ??
            extra.track_lang ??
            extra.language_code ??
            "",
        ).trim();
      } catch {
        // Keep the generic label.
      }
      return language || `${type === "AUDIO" ? "Audio" : "Sottotitoli"} ${index + 1}`;
    });
  }

  cycleTrack(type: "AUDIO" | "TEXT", currentIndex: number): number {
    const tracks = this.tracks(type);
    if (!tracks.length) return -1;
    if (type === "TEXT" && currentIndex >= tracks.length - 1) {
      try {
        avplay()?.setSilentSubtitle?.(true);
        return -1;
      } catch {
        return currentIndex;
      }
    }
    const next = (Math.max(-1, currentIndex) + 1) % tracks.length;
    try {
      if (type === "TEXT") avplay()?.setSilentSubtitle?.(false);
      avplay()?.setSelectTrack?.(type, tracks[next]!.index);
      return next;
    } catch {
      return currentIndex;
    }
  }

  private tracks(type: "AUDIO" | "TEXT"): Array<{
    type: string;
    index: number;
    extra_info?: string;
  }> {
    try {
      return (avplay()?.getTotalTrackInfo?.() ?? []).filter((track) => {
        const normalized = track.type.toUpperCase();
        return type === "TEXT"
          ? normalized === "TEXT" || normalized === "SUBTITLE"
          : normalized === type;
      });
    } catch {
      return [];
    }
  }

  stop(): void {
    this.openGeneration += 1;
    const player = avplay();
    if (!player) return;
    try {
      player.stop();
      player.close();
    } catch {
      // ignore
    }
    this.pendingRect = null;
    this.setObjectVisible(false);
    this.setState("idle", "");
  }

  setFullscreen(): void {
    this.pendingRect = null;
    const { w, h } = screenSize();
    avplay()?.setDisplayRect(0, 0, w, h);
    this.setObjectRect(0, 0, w, h);
    this.setObjectVisible(true);
  }

  /** Samsung AVPlay usa sempre coordinate 1920×1080. */
  static rectForElement(node: HTMLElement): { x: number; y: number; w: number; h: number } {
    const rect = node.getBoundingClientRect();
    const scaleX = 1920 / Math.max(1, document.documentElement.clientWidth || 1920);
    const scaleY = 1080 / Math.max(1, document.documentElement.clientHeight || 1080);
    return {
      x: Math.round(rect.left * scaleX),
      y: Math.round(rect.top * scaleY),
      w: Math.max(64, Math.round(rect.width * scaleX)),
      h: Math.max(36, Math.round(rect.height * scaleY)),
    };
  }

  setPreviewRect(container: HTMLElement): void {
    this.pendingRect = AvplayPlayer.rectForElement(container);
    const player = avplay();
    if (player && this.pendingRect.w > 0 && this.pendingRect.h > 0) {
      player.setDisplayRect(
        this.pendingRect.x,
        this.pendingRect.y,
        this.pendingRect.w,
        this.pendingRect.h,
      );
    }
  }

  private setState(state: PlayerState, title: string, detail?: string): void {
    this.state = state;
    this.onState?.(state, title, detail);
  }
}

/** HTML5 fallback for browser dev without AVPlay. */
export class Html5PreviewPlayer {
  private video: HTMLVideoElement | null = null;

  mount(container: HTMLElement): void {
    if (this.video) return;
    const video = document.createElement("video");
    video.style.width = "100%";
    video.style.height = "100%";
    video.style.objectFit = "contain";
    video.playsInline = true;
    container.appendChild(video);
    this.video = video;
  }

  open(url: string, startPositionMs = 0): void {
    if (!this.video) return;
    this.video.src = url;
    if (startPositionMs > 0) {
      this.video.addEventListener(
        "loadedmetadata",
        () => {
          if (this.video) this.video.currentTime = startPositionMs / 1000;
        },
        { once: true },
      );
    }
    void this.video.play().catch(() => undefined);
  }

  stop(): void {
    if (!this.video) return;
    this.video.pause();
    this.video.removeAttribute("src");
    this.video.load();
  }
}
