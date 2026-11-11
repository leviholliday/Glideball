import { getApplications } from "@raycast/api";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

// How the extension talks to Glideball: glideball:// URLs to change things
// (opened in the background), and ~/Library/Application Support/Glide/status.json
// to read what it's doing. Both are described in Glideball's docs/DEVELOPING.md,
// "Controlling Glideball from other apps". Nothing here goes through a shell:
// `open` gets its arguments as an array, and URL values are percent-encoded.

const run = promisify(execFile);

export const BUNDLE_ID = "com.leviholliday.glide";
export const WEBSITE = "https://glideball.netlify.app";
/** The name of Glideball's executable (not "Glideball"), for noticing that it's running. */
const PROCESS_NAME = "Glide";
const STATUS_PATH = join(homedir(), "Library", "Application Support", "Glide", "status.json");

export type ScrollMode = "native" | "flywheel" | "follow";

/** What status.json holds (schemaVersion 1). */
export interface GlideStatus {
  schemaVersion: number;
  appVersion: string;
  pid: number;
  paused: boolean;
  trackballConnected: boolean;
  trackballs: string[];
  scrollMode: string;
  pointerSpeed: number;
  modes: { precision: boolean; ballScroll: boolean; dragLock: boolean };
  activeAppSetup?: { name: string; pinned: boolean } | null;
  today: { clicks: number; ballMeters: number; scrollMeters: number };
  updatedAt: string;
}

export type Glideball =
  | { kind: "not-installed" }
  | { kind: "not-running" }
  | { kind: "switch-off" }
  /** status.json is there but isn't a version this extension knows how to read. */
  | { kind: "unsupported" }
  | { kind: "ready"; status: GlideStatus };

export type Problem = Exclude<Glideball, { kind: "ready" }>["kind"];

/** The commands to run Glideball can't do yet: not installed, not running, or the switch is off. */
export function problemOf(g: Glideball): Problem | undefined {
  return g.kind === "ready" || g.kind === "unsupported" ? undefined : g.kind;
}

export function statusOf(g: Glideball): GlideStatus | undefined {
  return g.kind === "ready" ? g.status : undefined;
}

export async function isInstalled(): Promise<boolean> {
  const usual = ["/Applications/Glideball.app", join(homedir(), "Applications", "Glideball.app")];
  if (usual.some((path) => existsSync(path))) return true;
  try {
    return (await getApplications()).some((app) => app.bundleId === BUNDLE_ID);
  } catch {
    return false;
  }
}

function processIsAlive(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // EPERM means the process exists but belongs to someone else.
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

async function isRunning(): Promise<boolean> {
  try {
    await run("/usr/bin/pgrep", ["-x", PROCESS_NAME]);
    return true;
  } catch {
    return false; // pgrep exits 1 when nothing matches
  }
}

function isStatus(value: unknown): value is GlideStatus {
  if (typeof value !== "object" || value === null) return false;
  const s = value as Partial<GlideStatus>;
  return (
    s.schemaVersion === 1 &&
    typeof s.pid === "number" &&
    typeof s.paused === "boolean" &&
    typeof s.scrollMode === "string" &&
    typeof s.pointerSpeed === "number" &&
    typeof s.modes === "object" &&
    s.modes !== null &&
    typeof s.today === "object" &&
    s.today !== null &&
    Array.isArray(s.trackballs)
  );
}

/** status.json as it is now, or undefined if it isn't there. "unsupported" if it's there but unreadable. */
async function readStatusFile(): Promise<GlideStatus | "unsupported" | undefined> {
  let text: string;
  try {
    text = await readFile(STATUS_PATH, "utf8");
  } catch {
    return undefined;
  }
  try {
    const parsed: unknown = JSON.parse(text);
    return isStatus(parsed) ? parsed : "unsupported";
  } catch {
    return "unsupported";
  }
}

/** Where Glideball stands right now. */
export async function readGlideball(): Promise<Glideball> {
  const file = await readStatusFile();
  if (file === "unsupported") return { kind: "unsupported" };
  // A file whose process is gone was left by a crash: Glideball isn't running.
  if (file && processIsAlive(file.pid)) return { kind: "ready", status: file };
  if (!(await isInstalled())) return { kind: "not-installed" };
  // No file but the app is running: the switch is off, or this Glideball is older than 2.10.
  return (await isRunning()) ? { kind: "switch-off" } : { kind: "not-running" };
}

/** The current status.json, if Glideball is running with the switch on. */
export async function readStatus(): Promise<GlideStatus | undefined> {
  const g = await readGlideball();
  return statusOf(g);
}

/** Waits up to `timeout` ms for status.json to satisfy `done` (Glideball writes it about once a second). */
export async function waitForStatus(
  done: (s: GlideStatus) => boolean,
  timeout = 2500,
): Promise<GlideStatus | undefined> {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    await new Promise((resolve) => setTimeout(resolve, 150));
    const file = await readStatusFile();
    if (file && file !== "unsupported" && done(file)) return file;
  }
  return undefined;
}

// MARK: URLs

export type GlideURL =
  | { command: "pause" | "resume" | "toggle" | "check-for-updates" }
  | { command: "precision"; state: "on" | "off" | "toggle" }
  | { command: "scroll-mode"; mode: ScrollMode }
  | { command: "pointer-speed"; value: number }
  | { command: "open"; tab?: "overview" | "pointer" | "scrolling" | "buttons" | "apps" | "sync" }
  | { command: "settings"; tab?: "general" | "updates" | "privacy" | "shortcuts" };

export function urlFor(u: GlideURL): string {
  const query = (key: string, value: string) => `?${key}=${encodeURIComponent(value)}`;
  switch (u.command) {
    case "precision":
      return `glideball://precision${query("state", u.state)}`;
    case "scroll-mode":
      return `glideball://scroll-mode${query("mode", u.mode)}`;
    case "pointer-speed":
      return `glideball://pointer-speed${query("value", String(u.value))}`;
    case "open":
    case "settings":
      return `glideball://${u.command}${u.tab ? query("tab", u.tab) : ""}`;
    default:
      return `glideball://${u.command}`;
  }
}

/** `open -g`, so Glideball stays in the background. No shell: the URL is one argument. */
export async function send(u: GlideURL): Promise<void> {
  await run("/usr/bin/open", ["-g", urlFor(u)]);
}

/** Starts Glideball (it opens quietly, like Open at Login). */
export async function launchGlideball(): Promise<void> {
  await run("/usr/bin/open", ["-g", "-b", BUNDLE_ID]);
}

// MARK: Wording

export const SCROLL_MODES: { id: ScrollMode; title: string; description: string }[] = [
  // The one-line descriptions are the ones on Glideball's Scrolling tab.
  { id: "native", title: "Native", description: "macOS does the scrolling" },
  { id: "flywheel", title: "Flywheel", description: "Push and glide — Kensington's feel" },
  { id: "follow", title: "Follow", description: "Page tracks the ring exactly" },
];

export function scrollModeTitle(id: string): string {
  return SCROLL_MODES.find((m) => m.id === id)?.title ?? id;
}

export const POINTER_SPEED_RANGE = { min: 0.5, max: 80, step: 0.5 };

/** The speed Glideball would use for what was typed: a plain decimal, rounded to 0.5 and kept in range. */
export function parsePointerSpeed(text: string): number | undefined {
  const raw = text.trim();
  if (raw.length === 0 || raw.length > 10 || !/^[0-9]*\.?[0-9]*$/.test(raw) || !/[0-9]/.test(raw)) return undefined;
  const value = Number(raw);
  if (!Number.isFinite(value)) return undefined;
  const { min, max, step } = POINTER_SPEED_RANGE;
  return Math.min(Math.max(Math.round(value / step) * step, min), max);
}

export function speedText(speed: number): string {
  return Number.isInteger(speed) ? String(speed) : speed.toFixed(1).replace(/\.0$/, "");
}

/** Distances the way Glideball's Overview shows them. */
export function distanceText(meters: number): string {
  if (meters < 1) return `${Math.round(meters * 100)} cm`;
  if (meters < 1000) return `${meters.toFixed(1)} m`;
  return `${(meters / 1000).toFixed(2)} km`;
}
