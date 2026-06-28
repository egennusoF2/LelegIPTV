export type TvRoute =
  | "home"
  | "live"
  | "movies"
  | "series"
  | "favorites"
  | "search"
  | "guide"
  | "settings";

export const NAV_ITEMS: { route: TvRoute; label: string }[] = [
  { route: "home", label: "Home" },
  { route: "live", label: "Live TV" },
  { route: "movies", label: "Film" },
  { route: "series", label: "Serie" },
  { route: "favorites", label: "Preferiti" },
  { route: "search", label: "Cerca" },
  { route: "guide", label: "Guida TV" },
  { route: "settings", label: "Le mie liste" },
];

export type RouteListener = (route: TvRoute) => void;

export class Router {
  private route: TvRoute = "home";
  private listeners = new Set<RouteListener>();

  get current(): TvRoute {
    return this.route;
  }

  subscribe(listener: RouteListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  navigate(route: TvRoute): void {
    if (this.route === route) return;
    this.route = route;
    for (const listener of this.listeners) listener(route);
  }
}
