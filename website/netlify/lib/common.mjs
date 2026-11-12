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
// What the website's feedback page can attach (feedback/feedback.js keeps
// to the same): up to 4 pictures. The app's limits are the ones above.
export const WEB_TYPES = { "image/png": 12e6, "image/jpeg": 12e6 };
export const WEB_MAX_FILES = 4;
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

/** The admin site (admin-site/, docs/ADMIN-SITE.md), without a slash at the end.
 * ADMIN_URL only if it ended up with another name. */
export const adminURL = () => (env("ADMIN_URL") || "https://admin-glideball.netlify.app").replace(/\/+$/, "");

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

/** An IPv6 address's /64 ("2001:db8:1:2::/64"), which is what one home,
 * phone or server is usually given, so stepping through its addresses
 * doesn't get round the limits. IPv4 (also written ::ffff:1.2.3.4) as is. */
export function ipGroup(ip) {
  let a = String(ip ?? "").trim().replace(/^\[|\]$/g, "").replace(/%.*$/, "").toLowerCase();
  if (!a.includes(":")) return a || "unknown";
  // A dotted IPv4 tail counts as two groups.
  const tail = /:(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(a);
  if (tail) {
    const [b0, b1, b2, b3] = tail.slice(1).map(Number);
    a = a.slice(0, tail.index + 1) + ((b0 << 8) | b1).toString(16) + ":" + ((b2 << 8) | b3).toString(16);
  }
  const halves = a.split("::");
  if (halves.length > 2) return a;
  const part = (h) => (h ? h.split(":") : []);
  const head = part(halves[0]);
  const rest = halves.length === 2 ? part(halves[1]) : [];
  const fill = 8 - head.length - rest.length;
  if (halves.length === 2 ? fill < 1 : fill !== 0) return a;
  const groups = [...head, ...Array(halves.length === 2 ? fill : 0).fill("0"), ...rest];
  if (!groups.every((g) => /^[0-9a-f]{1,4}$/.test(g))) return a;
  const n = groups.map((g) => parseInt(g, 16));
  if (n.slice(0, 5).every((x) => x === 0) && n[5] === 0xffff) {
    return [n[6] >> 8, n[6] & 255, n[7] >> 8, n[7] & 255].join(".");   // IPv4, written as IPv6
  }
  return groups.slice(0, 4).map((g) => g.replace(/^0+(?=.)/, "")).join(":") + "::/64";
}

/** Who's asking, for the limits: the address, or its /64 (see ipGroup).
 * Used for nothing else, and never kept with the feedback. */
export const clientIP = (req, context) =>
  ipGroup(context?.ip || req.headers.get("x-nf-client-connection-ip") || "unknown");

/** A counter's record: one per key per window, named with when the window
 * ends (in seconds), so the hourly cleanup can drop old ones by name alone. */
export function rateKey(key, windowSec, now = Date.now()) {
  const ends = (Math.floor(now / 1000 / windowSec) + 1) * windowSec;
  return `rate/${ends}-${sha256(key).toString("hex").slice(0, 24)}`;
}
/** Over (a minute after its window ended), or an older kind of counter
 * that never ended: either way, it can go. */
export function rateExpired(blobKey, now = Date.now()) {
  const m = /^rate\/(\d+)-[0-9a-f]{24}$/.exec(blobKey);
  return !m || Number(m[1]) * 1000 + 60e3 <= now;
}

/** Counts one for this key, unless it's had `limit` this window. Returns
 * the counter's record if this one's allowed (for giveBack()), or null.
 * Counted with a conditional write, so requests sent all at once can't all
 * read the same count (any that keep losing are turned away). */
export async function take(key, limit, windowSec, now = Date.now()) {
  const k = rateKey(key, windowSec, now);
  const s = misc();
  for (let tries = 0; tries < 5; tries++) {
    const cur = await s.getWithMetadata(k, { type: "json" });
    const n = cur?.data?.n ?? 0;
    if (n >= limit) return null;
    const w = await s.setJSON(k, { n: n + 1 }, cur ? { onlyIfMatch: cur.etag } : { onlyIfNew: true });
    if (w.modified) return k;
  }
  return null;
}
/** At most `limit` of these per `windowSec` for this key; true if this one's allowed. */
export const allow = async (key, limit, windowSec) => !!(await take(key, limit, windowSec));
/** Takes back one that take() counted, when it turned out not to count. */
export async function giveBack(k) {
  if (!k) return;
  const s = misc();
  for (let tries = 0; tries < 5; tries++) {
    const cur = await s.getWithMetadata(k, { type: "json" });
    if (!(cur?.data?.n > 0)) return;
    const w = await s.setJSON(k, { n: cur.data.n - 1 }, { onlyIfMatch: cur.etag });
    if (w.modified) return;
  }
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

/** An item as the admin page gets it: never the upload token (nor the
 * scrambled IP address items sent before 2026-11 were kept with). */
export function forAdmin(item) {
  const { uploadTokenHash, ipHash, ...rest } = item;
  return rest;
}

const PLATFORM_NAMES = { macos: "Mac", web: "Website" };
const NTFY_PRIORITY = { low: 2, normal: 3, high: 4, blocking: 5 };
const NTFY_TAGS = { low: "speech_balloon", normal: "speech_balloon", high: "warning", blocking: "rotating_light" };

// However much arrives, Levi's phone gets at most this many pushes an hour,
// and at most this many urgent ones (the kind that gets through Do Not
// Disturb) a day; past that, urgent ones come as normal ones. Items past the
// hourly budget are kept as always, just counted, and the hourly cleanup
// sends one push saying how many there were (pushDigest()).
export const PUSHES_PER_HOUR = 20;
export const URGENT_PER_DAY = 3;
const MISSED = "push/missed";

/** What a push for this item says. `urgentOK` false: not as an urgent one. */
export function pushFor(item, urgentOK = true) {
  const site = env("URL") || "https://glideball.netlify.app";
  const priority = item.priority[0].toUpperCase() + item.priority.slice(1);
  const lost = (item.files ?? []).filter((f) => !f.done).length;
  const version = [item.app?.version, item.app?.build ? `(build ${item.app.build})` : ""].filter(Boolean).join(" ");
  const level = NTFY_PRIORITY[item.priority] ?? 3;
  return {
    title: `Glideball feedback: ${item.title}`.slice(0, 150),
    message: `${priority} · ${PLATFORM_NAMES[item.platform] ?? item.platform}` +
      (item.platform === "web" ? "" : ` · ${version || "unknown version"}`) +
      ((item.tags ?? []).length ? ` · ${item.tags.join(", ")}` : "") +
      (item.files?.length ? ` · ${item.files.length} attachment${item.files.length > 1 ? "s" : ""}` : "") +
      (lost ? ` (${lost} didn't arrive)` : ""),
    priority: level >= 5 && !urgentOK ? 3 : level,
    tags: [NTFY_TAGS[item.priority] ?? "speech_balloon"],
    click: `${site}/admin/feedback/?id=${encodeURIComponent(item.id)}`,
  };
}

/** Tells Levi's phone: the title, priority and version, and tapping it
 * opens the item on the admin page; or, past the budget, only counts it.
 * Gives up after a few seconds (and is started with later()), so it
 * doesn't hold up the reply to the sender: a reply that times out gets the
 * feedback sent again. */
export async function notify(item) {
  if (!env("NTFY_TOPIC")) return;
  if (!(await allow("push/everyone", PUSHES_PER_HOUR, 3600))) return missed();
  const urgentOK = (NTFY_PRIORITY[item.priority] ?? 3) < 5 || (await allow("push/urgent", URGENT_PER_DAY, 86400));
  await send(pushFor(item, urgentOK));
}

/** One more that wasn't pushed. */
async function missed() {
  const s = misc();
  for (let tries = 0; tries < 5; tries++) {
    const cur = await s.getWithMetadata(MISSED, { type: "json" });
    const w = await s.setJSON(MISSED, { n: (cur?.data?.n ?? 0) + 1 }, cur ? { onlyIfMatch: cur.etag } : { onlyIfNew: true });
    if (w.modified) return;
  }
}

/** If any weren't pushed since the last time, one push saying how many. */
export async function pushDigest() {
  if (!env("NTFY_TOPIC")) return;
  const s = misc();
  const cur = await s.getWithMetadata(MISSED, { type: "json" });
  const n = cur?.data?.n ?? 0;
  if (!(n > 0)) return;
  // Cleared first, so two runs at once can't both send it.
  const w = await s.setJSON(MISSED, { n: 0 }, { onlyIfMatch: cur.etag });
  if (!w.modified) return;
  const site = env("URL") || "https://glideball.netlify.app";
  await send({
    title: `Glideball feedback: ${n} more`,
    message: `${n} more feedback item${n > 1 ? "s" : ""} came in without a notification (too many at once). They're in the inbox.`,
    priority: 3,
    tags: ["inbox_tray"],
    click: `${site}/admin/feedback/`,
  });
}

async function send(push) {
  const body = { topic: env("NTFY_TOPIC"), ...push };
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
