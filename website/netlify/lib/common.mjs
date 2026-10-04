// What the feedback functions share: the stores, limits, replies, and the
// notification that tells Levi something arrived (ntfy).

import { getStore } from "@netlify/blobs";
import crypto from "node:crypto";

// Attachments come in pieces: a function takes at most ~6 MB a request, and
// binary bodies grow a third on the way in.
export const CHUNK = 3 * 1024 * 1024;       // what the app and the site send
export const MAX_CHUNK = 4 * 1024 * 1024;   // what's accepted

// What can be attached, and how big each may be.
export const TYPES = {
  "image/png": 12e6,
  "image/jpeg": 12e6,
  "video/mp4": 60e6,
  "video/quicktime": 60e6,
  "text/plain": 5e6,
  "application/json": 2e6,
  "application/octet-stream": 5e6,
};
export const PRIORITIES = ["low", "normal", "high", "blocking"];
// How long the sender has to send an item's attachments. (The admin page's
// unfinished() in admin/feedback/app.js goes by the same.)
export const UPLOAD_WINDOW = 6 * 3600e3;
export const PLATFORMS = ["macos", "web"];
export const STATUSES = ["new", "seen", "done"];

// Feedback items (JSON) (and uploading/<id> for each one still waiting for
// its attachments), their attachments' pieces, and everything else (the
// admin password, rate counters, the admin list's summaries).
export const items = () => getStore({ name: "glide-feedback", consistency: "strong" });
export const files = () => getStore({ name: "glide-feedback-files", consistency: "strong" });
export const misc = () => getStore({ name: "glide-feedback-misc", consistency: "strong" });

export const env = (k) => globalThis.Netlify?.env?.get(k) ?? process.env[k];

export function json(data, status = 200, headers = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
  });
}
export const fail = (status, error) => json({ error }, status);

export const sha256 = (s) => crypto.createHash("sha256").update(String(s)).digest();
/** Equal, in time that doesn't say how much of it matched. */
export function sameSecret(a, b) {
  return crypto.timingSafeEqual(sha256(a ?? ""), sha256(b ?? ""));
}
export const randomToken = (bytes = 24) => crypto.randomBytes(bytes).toString("base64url");

/** Sorts by time: 20260929-231502-a1b2c3d4. */
export function newID() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}-` +
    `${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}-${crypto.randomBytes(4).toString("hex")}`;
}

export const clientIP = (req, context) => context?.ip || req.headers.get("x-nf-client-connection-ip") || "unknown";

/** At most `limit` of these per `windowSec` for this key; true if this one's allowed.
 * One counter per key, counted with a conditional write, so requests sent all
 * at once can't all read the same count (any that keep losing are turned away). */
export async function allow(key, limit, windowSec) {
  const bucket = Math.floor(Date.now() / 1000 / windowSec);
  const k = `rate/${sha256(key).toString("hex").slice(0, 24)}`;
  const s = misc();
  for (let tries = 0; tries < 5; tries++) {
    const cur = await s.getWithMetadata(k, { type: "json" });
    const n = cur?.data?.bucket === bucket ? cur.data.n : 0;
    if (n >= limit) return false;
    const w = await s.setJSON(k, { bucket, n: n + 1 }, cur ? { onlyIfMatch: cur.etag } : { onlyIfNew: true });
    if (w.modified) return true;
  }
  return false;
}

/** Changes an item and writes it back, but only if nothing else wrote it in
 * between (pieces of an upload can land at the same time); if something did,
 * starts again from the fresh copy. `edit` may return a reply to stop with.
 * Returns [item, null] or [null, reply]. */
export async function changeItem(id, edit) {
  for (let tries = 0; tries < 5; tries++) {
    const cur = await items().getWithMetadata(`items/${id}`, { type: "json" });
    if (!cur) return [null, fail(404, "No such feedback.")];
    const stop = edit(cur.data);
    if (stop) return [null, stop];
    const w = await items().setJSON(`items/${id}`, cur.data, { onlyIfMatch: cur.etag });
    if (w.modified) return [cur.data, null];
  }
  return [null, fail(503, "It's busy. Try again.")];
}

/** Every piece of an attachment arrived, and they add up to the size it was
 * sent as (which create() checked against the limits). */
export function whole(f) {
  const sizes = [...(f.chunks ?? [])];
  return !!f.total && sizes.length === f.total && sizes.every((n) => n > 0) &&
    sizes.reduce((a, n) => a + n, 0) === f.size;
}

/** Runs `work` after the reply has gone, where the platform can (Functions
 * v2's context.waitUntil); otherwise waits for it first. */
export const later = (context, work) => (context?.waitUntil ? context.waitUntil(work) : work);

/** An item as the admin page gets it: never the upload token. */
export function forAdmin(item) {
  const { uploadTokenHash, ipHash, ...rest } = item;
  return rest;
}

const PLATFORM_NAMES = { macos: "Mac", web: "Website" };
const NTFY_PRIORITY = { low: 2, normal: 3, high: 4, blocking: 5 };
const NTFY_TAGS = { low: "speech_balloon", normal: "speech_balloon", high: "warning", blocking: "rotating_light" };

/** Tells Levi's phone: the title, priority and version, and tapping it
 * opens the item on the admin page. Gives up after a few seconds (and is
 * started with later()), so it doesn't hold up the reply to the sender: a
 * reply that times out gets the feedback sent again. */
export async function notify(item) {
  const topic = env("NTFY_TOPIC");
  if (!topic) return;
  const site = env("URL") || "https://glideball.netlify.app";
  const priority = item.priority[0].toUpperCase() + item.priority.slice(1);
  const lost = (item.files ?? []).filter((f) => !f.done).length;
  const version = [item.app?.version, item.app?.build ? `(build ${item.app.build})` : ""].filter(Boolean).join(" ");
  const body = {
    topic,
    title: `Glide feedback: ${item.title}`.slice(0, 150),
    message: `${priority} · ${PLATFORM_NAMES[item.platform] ?? item.platform}` +
      (item.platform === "web" ? "" : ` · ${version || "unknown version"}`) +
      ((item.tags ?? []).length ? ` · ${item.tags.join(", ")}` : "") +
      (item.files?.length ? ` · ${item.files.length} attachment${item.files.length > 1 ? "s" : ""}` : "") +
      (lost ? ` (${lost} didn't arrive)` : ""),
    priority: NTFY_PRIORITY[item.priority] ?? 3,
    tags: [NTFY_TAGS[item.priority] ?? "speech_balloon"],
    click: `${site}/admin/feedback/?id=${encodeURIComponent(item.id)}`,
  };
  const headers = { "content-type": "application/json" };
  if (env("NTFY_TOKEN")) headers.authorization = `Bearer ${env("NTFY_TOKEN")}`;
  try {
    const r = await fetch(env("NTFY_SERVER") || "https://ntfy.sh/", {
      method: "POST", headers, body: JSON.stringify(body), signal: AbortSignal.timeout(4000),
    });
    if (!r.ok) console.error("ntfy:", r.status, await r.text());
  } catch (e) {
    console.error("ntfy:", e);
  }
}
