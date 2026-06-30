import { ensureWebapisLoaded } from "../polyfills";

type AvplayListener = {
  onbufferingstart?: () => void;
  onbufferingcomplete?: () => void;
  oncurrentplaytime?: (ms: number) => void;
  onerror?: (event: unknown) => void;
  onstreamcompleted?: () => void;
};

type AvplayApi = {
  open: (url: string) => void;
  close: () => void;
  prepareAsync: (success: () => void, error: (e: unknown) => void) => void;
  play: () => void;
  pause: () => void;
  stop: () => void;
  seekTo: (ms: number, success?: () => void, error?: (e: unknown) => void) => void;
  getState: () => string;
  setDisplayRect: (x: number, y: number, w: number, h: number) => void;
  setDisplayMethod?: (method: string) => void;
  setListener: (listener: AvplayListener) => void;
  getTotalTrackInfo?: () => { index: number; type: string; extra_info?: string }[];
  setSelectTrack?: (type: string, index: number) => void;
};

function avplay(): AvplayApi | null {
  const api = (globalThis as { webapis?: { avplay?: AvplayApi } }).webapis?.avplay;
  return api ?? null;
}

export type PlayerState = "idle" | "opening" | "buffering" | "playing" | "paused" | "error";

export class AvplayPlayer {
  private state: PlayerState = "idle";
  private url = "";
  private title = "";
  private onState?: (state: PlayerState, title: string) => void;

  setStateListener(listener: (state: PlayerState, title: string) => void): void {
    this.onState = listener;
  }

  get currentState(): PlayerState {
    return this.state;
  }

  get currentTitle(): string {
    return this.title;
  }

  isAvailable(): boolean {
    return avplay() !== null;
  }

  open(url: string, title: string, rect?: { x: number; y: number; w: number; h: number }): void {
    void ensureWebapisLoaded()
      .then(() => this.openWithAvplay(url, title, rect))
      .catch(() => {
        this.setState("error", title);
        throw new Error("AVPlay non disponibile su questo dispositivo");
      });
  }

  private openWithAvplay(
    url: string,
    title: string,
    rect?: { x: number; y: number; w: number; h: number },
  ): void {
    const player = avplay();
    if (!player) {
      this.setState("error", title);
      throw new Error("AVPlay non disponibile su questo dispositivo");
    }
    this.url = url;
    this.title = title;
    this.setState("opening", title);
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
      onbufferingstart: () => this.setState("buffering", title),
      onbufferingcomplete: () => this.setState("playing", title),
      onerror: () => this.setState("error", title),
      onstreamcompleted: () => this.setState("paused", title),
    });

    player.open(url);
    if (rect) {
      player.setDisplayRect(rect.x, rect.y, rect.w, rect.h);
    }
    player.setDisplayMethod?.("PLAYER_DISPLAY_MODE_LETTER_BOX");

    player.prepareAsync(
      () => {
        player.play();
        this.setState("playing", title);
      },
      () => this.setState("error", title),
    );
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

  stop(): void {
    const player = avplay();
    if (!player) return;
    try {
      player.stop();
      player.close();
    } catch {
      // ignore
    }
    this.setState("idle", "");
  }

  setFullscreen(): void {
    avplay()?.setDisplayRect(0, 0, 1920, 1080);
  }

  setPreviewRect(container: HTMLElement): void {
    const rect = container.getBoundingClientRect();
    avplay()?.setDisplayRect(
      Math.round(rect.left),
      Math.round(rect.top),
      Math.round(rect.width),
      Math.round(rect.height),
    );
  }

  private setState(state: PlayerState, title: string): void {
    this.state = state;
    this.onState?.(state, title);
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

  open(url: string): void {
    if (!this.video) return;
    this.video.src = url;
    void this.video.play().catch(() => undefined);
  }

  stop(): void {
    if (!this.video) return;
    this.video.pause();
    this.video.removeAttribute("src");
    this.video.load();
  }
}
