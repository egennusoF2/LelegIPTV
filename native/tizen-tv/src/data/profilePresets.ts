import type { XtreamProfile } from "./models";

const PRESETS: Record<string, Omit<XtreamProfile, "title"> & { title: string }> = {
  LELEG: {
    title: "LELEG",
    serverUrl: "http://muti14.fonsecatemp.com",
    username: "notv_w7cehc",
    password: "ffhuax4a",
  },
  JOLLY: {
    title: "JOLLY",
    serverUrl: "http://muti14.fonsecatemp.com",
    username: "notv_71d762",
    password: "qgjjhnty",
  },
  AMICO: {
    title: "AMICO",
    serverUrl: "http://muti14.fonsecatemp.com",
    username: "notv_93me22",
    password: "x7g35zhh",
  },
  ALESSANDRO: {
    title: "ALESSANDRO",
    serverUrl: "http://watchtivo-4k.com",
    username: "S8eLtOiTtE",
    password: "ut6YxwMG6X",
  },
  GIORDANO: {
    title: "GIORDANO",
    serverUrl: "http://watchtivo-4k.com",
    username: "bSFZGHX1Gr",
    password: "zHwiKBmB1O",
  },
};

export function resolvePreset(code: string): XtreamProfile | null {
  return PRESETS[code.trim().toUpperCase()] ?? null;
}

export function presetCodes(): string[] {
  return Object.keys(PRESETS).sort();
}

export function profileFromForm(
  rawTitle: string,
  rawServer: string,
  rawUsername: string,
  rawPassword: string,
): XtreamProfile | null {
  const preset = resolvePreset(rawTitle);
  const server = (preset?.serverUrl ?? rawServer).trim();
  const username = (preset?.username ?? rawUsername).trim();
  const password = preset?.password ?? rawPassword;
  if (!server || !username || !password) return null;
  const title = rawTitle.trim() || preset?.title || "La mia lista";
  return {
    title: preset?.title ?? title,
    serverUrl: server,
    username,
    password,
  };
}
