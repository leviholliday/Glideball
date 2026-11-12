// Opt-in crash reports and settings stats from the Mac app (Settings ›
// Privacy › Crash reports and stats, off unless the person says yes): what
// /api/usage, /api/crash and the admin's Usage page share.
//
// Kept in one store, by key, so most questions are answered from the key
// names alone and deleting an install or a stretch of days needs no index:
//
//   pings/<YYYY-MM-DD>/<install>                           one a day per install (the last one sent that day)
//   crashes/<signature>/<YYYYMMDD-HHMMSS>-<rand>.<install>  one per crash
//   cache/latest, cache/crashes                            the admin page's copies of what it read last time
//
// <install> is SHA-256 of the install ID (hex), never the ID itself. The ID
// ("GB-" and 160 random bits in Crockford base32, made by the app for this
// feature only) is shown only to the person in the app, so nobody here can
// tell whose data is whose; it only arrives raw (over HTTPS) to be hashed when
// the app sends something, or when the person asks for their data to be
// deleted (from the app, or by giving Levi their ID). Nothing returns an ID or
// a hash: the admin page shows totals and crash groups only.
//
// No IP address is kept anywhere: rate limits use the hashed counters in
// common.mjs (an IPv6 address counts by its /64), which the hourly cleanup
// drops. Nothing expires by itself; the admin deletes by install or by dates.

import { getStore } from "@netlify/blobs";
import crypto from "node:crypto";

export const usage = () => getStore({ name: "glide-usage", consistency: "strong" });

// "GB-" then 32 Crockford base32 characters (160 bits) in groups of four.
export const INSTALL_ID = /^GB(-[0-9A-HJKMNP-TV-Z]{4}){8}$/;
const HASH = "[0-9a-f]{64}";

/** An ID as the person might paste or type it: any case, spaces or dashes
 * anywhere, Crockford's look-alikes (O for 0, I or L for 1). The ID in its
 * one written form, or null if it isn't one. */
export function normalizeID(raw) {
  if (typeof raw !== "string" || raw.length > 80) return null;
  let s = raw.toUpperCase().replace(/[\s-]/g, "");
  if (!s.startsWith("GB")) return null;
  s = s.slice(2).replace(/O/g, "0").replace(/[IL]/g, "1");
  if (!/^[0-9A-HJKMNP-TV-Z]{32}$/.test(s)) return null;
  return "GB-" + s.match(/.{4}/g).join("-");
}
/** What an install is kept under: SHA-256 of its ID, in hex. */
export const installKey = (id) => crypto.createHash("sha256").update(id).digest("hex");
export const DAY = /^\d{4}-\d{2}-\d{2}$/;

// What the app sends (Sources/Glide/ShareData.swift keeps to the same lists).
export const SCROLL_MODES = ["native", "flywheel", "follow"];
export const PERFORMANCE = ["smooth", "efficient", "minimal"];
export const POINTER_SPEEDS = ["<2", "2-4", "4-8", "8-16", "16-32", "32+"];
export const ACTION_TYPES = [
  "system", "leftClick", "rightClick", "middleClick", "back", "forward", "shortcut", "holdShortcut",
  "modifiedClick", "disabled", "precisionHold", "precisionToggle", "ballScrollHold", "dragLock", "media", "openApp",
];
export const ARCHES = ["arm64", "x86_64"];

export const MAX_PING_BYTES = 4 * 1024;
export const MAX_CRASH_BYTES = 32 * 1024;

/** "2026-11-10" for a time (UTC). */
export const dayOf = (ms) => new Date(ms).toISOString().slice(0, 10);

/** Anything that might name a person or their files, taken out of a string
 * from a crash report: home folders, other volumes, email addresses. (The app
 * does this too; this is in case an older or a modified one doesn't.) */
export function scrub(s, max) {
  return String(s ?? "")
    // Invisible characters first (control, zero-width, right-to-left marks),
    // so none can split a path or an address to slip it past what follows.
    .replace(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f\p{Cf}]/gu, "")
    // (macOS folders match in any case: /users/jane is /Users/jane.)
    .replace(/\/(Users|home)\/[^/\s:")]+/gi, "/$1/~")
    // A drive's name can have spaces in it ("Jane's Passport"): all of it, up to the next folder.
    .replace(/\/Volumes\/[^/\n]+/gi, "/Volumes/~")
    .replace(/[^\s@'"<>()]+@[^\s@'"<>()]+\.[a-z]{2,}/gi, "(email)")
    .trim()
    .slice(0, max);
}

const isObj = (v) => !!v && typeof v === "object" && !Array.isArray(v);
const pick = (v, list) => (list.includes(v) ? v : null);
const word = (v, re, max) => (typeof v === "string" && v.length <= max && re.test(v) ? v : null);
const count = (v, max) => (Number.isInteger(v) && v >= 0 && v <= max ? v : null);

const VERSION = /^[0-9A-Za-z][0-9A-Za-z.+-]*$/;
const OS = /^\d{1,3}(\.\d{1,3}){0,2}$/;
const LANG = /^[a-z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$/;
// A trackball's product name as macOS reports it, without anything odd in it.
const PRODUCT = /^[A-Za-z0-9][A-Za-z0-9 ()+.,/&'-]*$/;

/** The JSON object in a request body no bigger than `max`, or an error reply's words. */
export async function readBody(req, max) {
  const text = await req.text();
  if (text.length > max) return [null, "That's too big."];
  let b;
  try { b = JSON.parse(text); } catch { return [null, "That wasn't JSON."]; }
  if (!isObj(b)) return [null, "That wasn't JSON."];
  return [b, null];
}

/** A day's stats ping as it's kept, or [null, why it was turned down].
 * Anything not on the list is dropped; anything on it that doesn't look
 * right turns the whole ping down, so what's kept is always what the app
 * says it sends. */
export function cleanPing(b, now = Date.now()) {
  const id = normalizeID(b.installId);
  if (!id) return [null, "No install ID."];
  const out = {
    at: new Date(now).toISOString(),
    version: word(b.version, VERSION, 32),
    build: word(b.build, /^\d+$/, 10),
    os: word(b.os, OS, 12),
    lang: word(b.lang, LANG, 20),
    arch: pick(b.arch, ARCHES),
    scrollMode: pick(b.scrollMode, SCROLL_MODES),
    performance: pick(b.performance, PERFORMANCE),
    pointerSpeed: pick(b.pointerSpeed, POINTER_SPEEDS),
    beta: typeof b.beta === "boolean" ? b.beta : null,
    appProfiles: count(b.appProfiles, 1000),
    combos: count(b.combos, 1000),
  };
  for (const [k, v] of Object.entries(out)) if (v === null) return [null, `${k} doesn't look right.`];
  // Added when the Beta switch split in two; optional so older pings still count.
  if (b.earlyUpdates !== undefined && typeof b.earlyUpdates !== "boolean") return [null, "earlyUpdates doesn't look right."];
  out.earlyUpdates = b.earlyUpdates === true;

  if (!Array.isArray(b.trackballs) || b.trackballs.length > 8) return [null, "trackballs doesn't look right."];
  out.trackballs = [];
  for (const t of b.trackballs) {
    const name = isObj(t) ? word(t.name, PRODUCT, 60) : null;
    const product = isObj(t) ? count(t.product, 0xffff) : null;
    if (name === null || product === null) return [null, "trackballs doesn't look right."];
    out.trackballs.push({ name, product });
  }

  if (!isObj(b.buttons)) return [null, "buttons doesn't look right."];
  out.buttons = {};
  for (const [k, v] of Object.entries(b.buttons)) {
    if (!ACTION_TYPES.includes(k) || count(v, 100) === null) return [null, "buttons doesn't look right."];
    if (v > 0) out.buttons[k] = v;
  }
  return [{ install: installKey(id), ping: out }, null];
}

/** A crash report as it's kept, or [null, why it was turned down]. */
export function cleanCrash(b, now = Date.now()) {
  const id = normalizeID(b.installId);
  if (!id) return [null, "No install ID."];
  const crashedAt = Date.parse(b.crashedAt ?? "");
  // From the last few months, and not from the future (give or take a clock that's off).
  if (!Number.isFinite(crashedAt) || crashedAt > now + 86400e3 || crashedAt < now - 90 * 86400e3) {
    return [null, "crashedAt doesn't look right."];
  }
  const out = {
    crashedAt: new Date(crashedAt).toISOString(),
    receivedAt: new Date(now).toISOString(),
    version: word(b.version, VERSION, 32),
    build: word(b.build, /^\d+$/, 10),
    os: word(b.os, OS, 12),
    arch: pick(b.arch, ARCHES),
    exception: word(b.exception, /^[A-Z][A-Z0-9_]*$/, 40),
    signal: b.signal === undefined || b.signal === "" ? "" : word(b.signal, /^SIG[A-Z0-9]+$/, 16),
  };
  for (const [k, v] of Object.entries(out)) if (v === null) return [null, `${k} doesn't look right.`];
  out.termination = scrub(b.termination, 120);
  out.reason = scrub(b.reason, 600);

  if (!Array.isArray(b.frames) || !b.frames.length || b.frames.length > 40) return [null, "frames doesn't look right."];
  out.frames = [];
  for (const f of b.frames) {
    const image = isObj(f) ? word(f.image, /^[A-Za-z0-9._+ -]+$/, 64) : null;
    const offset = isObj(f) ? count(f.offset, 2 ** 40) : null;
    if (image === null || offset === null) return [null, "frames doesn't look right."];
    const symbol = typeof f.symbol === "string" ? scrub(f.symbol, 200) : "";
    out.frames.push(symbol ? { image, symbol, offset } : { image, offset });
  }
  out.ownImage = word(b.ownImage, /^[A-Za-z0-9._+ -]+$/, 64) ?? "Glide";
  out.signature = signature(out);
  out.title = title(out);
  return [{ install: installKey(id), crash: out }, null];
}

/** The frames that are Glideball's own (or, if none are, the first few). */
function topFrames(c) {
  const own = c.frames.filter((f) => f.image === c.ownImage);
  return (own.length ? own : c.frames).slice(0, 5);
}
const frameName = (f) => f.symbol || `${f.image}+${f.offset}`;

/** Crashes that are the same bug: the kind of crash and where in
 * Glideball's own code it happened (by name where the report has names). */
export function signature(c) {
  const parts = [c.exception, c.signal, ...topFrames(c).map(frameName)];
  return crypto.createHash("sha256").update(parts.join("\n")).digest("hex").slice(0, 16);
}
function title(c) {
  const where = topFrames(c)[0];
  return `${c.exception}${c.signal ? ` (${c.signal})` : ""}${where ? ` in ${frameName(where)}` : ""}`.slice(0, 200);
}

/** Sorts by time, ends with which install (hashed) sent it: 20261110-214832-a1b2c3d4.<install>. */
export function crashKey(sig, install, now = Date.now()) {
  const d = new Date(now);
  const p = (n) => String(n).padStart(2, "0");
  const stamp = `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}-` +
    `${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}`;
  return `crashes/${sig}/${stamp}-${crypto.randomBytes(4).toString("hex")}.${install}`;
}

/** What a key says: { kind, day, install, sig? }, or null for anything else. */
export function parseKey(key) {
  let m = new RegExp(`^pings/(\\d{4}-\\d{2}-\\d{2})/(${HASH})$`).exec(key);
  if (m) return { kind: "ping", day: m[1], install: m[2] };
  m = new RegExp(`^crashes/([0-9a-f]{16})/(\\d{4})(\\d{2})(\\d{2})-(\\d{2})(\\d{2})(\\d{2})-[0-9a-f]{8}\\.(${HASH})$`).exec(key);
  if (m) {
    return {
      kind: "crash", sig: m[1], day: `${m[2]}-${m[3]}-${m[4]}`,
      at: `${m[2]}-${m[3]}-${m[4]}T${m[5]}:${m[6]}:${m[7]}Z`, install: m[8],
    };
  }
  return null;
}

/** Deletes blobs 50 at a time. */
export async function deleteKeys(keys) {
  const s = usage();
  for (let i = 0; i < keys.length; i += 50) await Promise.all(keys.slice(i, i + 50).map((k) => s.delete(k)));
}

/** The admin page's copies are made again on its next visit. */
export async function dropCaches() {
  await deleteKeys(["cache/latest", "cache/crashes"]);
}

/** The keys of everything one install (by its hash) sent. */
async function keysOf(install) {
  const s = usage();
  const [pings, crashes] = await Promise.all([s.list({ prefix: "pings/" }), s.list({ prefix: "crashes/" })]);
  return [...pings.blobs, ...crashes.blobs].map((b) => b.key).filter((k) => parseKey(k)?.install === install);
}

/** Everything one install sent, given its ID (raw, as the person has it).
 * Returns how many records went. */
export async function deleteInstall(id) {
  const keys = await keysOf(installKey(id));
  await deleteKeys(keys);
  if (keys.length) await dropCaches();
  return keys.length;
}

/** One install's own data, given its ID (the admin's "look up an ID", for
 * when someone asks): its days, its most recent stats and its crashes. No
 * ID or hash in it. */
export async function lookUpInstall(id) {
  const keys = await keysOf(installKey(id));
  const s = usage();
  const days = keys.filter((k) => k.startsWith("pings/")).map((k) => parseKey(k).day).sort();
  const latest = days.length ? await s.get(keys.find((k) => k.startsWith(`pings/${days.at(-1)}/`)), { type: "json" }) : null;
  const crashKeys = keys.filter((k) => k.startsWith("crashes/")).sort((a, b) => (parseKey(a).at < parseKey(b).at ? 1 : -1));
  const crashes = await Promise.all(crashKeys.slice(0, 50).map(async (k) => {
    const c = await s.get(k, { type: "json" });
    return c && { at: parseKey(k).at, title: c.title, signature: c.signature, version: c.version, os: c.os };
  }));
  return { found: keys.length > 0, days, latest, crashCount: crashKeys.length, crashes: crashes.filter(Boolean) };
}

/** Everything sent between `from` and `to` (days, both included, UTC). Returns how many records went. */
export async function deleteDays(from, to) {
  const s = usage();
  const [pings, crashes] = await Promise.all([s.list({ prefix: "pings/" }), s.list({ prefix: "crashes/" })]);
  const keys = [...pings.blobs, ...crashes.blobs].map((b) => b.key).filter((k) => {
    const p = parseKey(k);
    return p && p.day >= from && p.day <= to;
  });
  await deleteKeys(keys);
  if (keys.length) await dropCaches();
  return keys.length;
}

// ---------------------------------------------------------------- the admin's Usage page

/** The Monday of a day's week ("2026-11-09" for any day from then to the 15th). */
export function weekOf(day) {
  const t = Date.parse(`${day}T00:00:00Z`);
  const back = (new Date(t).getUTCDay() + 6) % 7;
  return dayOf(t - back * 86400e3);
}

// (Own keys only: a version sent as "constructor" or "toString" would
// otherwise start from the function every object has, not from 0.)
const bump = (o, k, n = 1) => { o[k] = (Object.hasOwn(o, k) ? o[k] : 0) + n; };
/** A count in a few groups: with edges [0, 1, 2, 5], "0", "1", "2–4" or "5+". */
function bucket(n, edges) {
  for (let i = edges.length - 1; i >= 0; i--) {
    if (n < edges[i]) continue;
    if (i === edges.length - 1) return `${edges[i]}+`;
    return edges[i + 1] - edges[i] === 1 ? String(edges[i]) : `${edges[i]}–${edges[i + 1] - 1}`;
  }
  return String(n);
}
const osName = (os) => `macOS ${os.split(".").slice(0, 2).join(".")}`;

/** Reads `wanted` ([{key, etag}]) through a kept copy at `cacheKey`, so a
 * visit reads only what changed since the last one. `keep` makes what's kept
 * of a record. Returns key -> kept. */
async function readThrough(cacheKey, wanted, keep) {
  const s = usage();
  const saved = await s.getWithMetadata(cacheKey, { type: "json" });
  const was = saved?.data?.v === 1 ? saved.data.entries : {};
  const now = {};
  const changed = [];
  for (const w of wanted) {
    if (was[w.key] && was[w.key].etag === w.etag) now[w.key] = was[w.key];
    else changed.push(w);
  }
  for (let i = 0; i < changed.length; i += 50) {
    await Promise.all(changed.slice(i, i + 50).map(async (w) => {
      const v = await s.get(w.key, { type: "json" });
      if (v) now[w.key] = { etag: w.etag, value: keep(v) };
    }));
  }
  if (changed.length || Object.keys(now).length !== Object.keys(was).length || !saved) {
    // If another visit saved it meanwhile, this copy is dropped: the next one catches up.
    await s.setJSON(cacheKey, { v: 1, entries: now }, saved ? { onlyIfMatch: saved.etag } : { onlyIfNew: true });
  }
  return Object.fromEntries(Object.entries(now).map(([k, e]) => [k, e.value]));
}

/** Everything the Usage page shows, for the last `days` days (UTC, today included). */
export async function usageReport(days, now = Date.now()) {
  const s = usage();
  const today = dayOf(now);
  const since = dayOf(now - (days - 1) * 86400e3);
  const [pings, crashes] = await Promise.all([s.list({ prefix: "pings/" }), s.list({ prefix: "crashes/" })]);

  // Active installs a day and a week, and who's new, from the keys alone.
  const perDay = {};
  const perWeek = {};
  const firstSeen = {};
  const latest = {};   // install (hashed) -> { key, etag, day }; never leaves this function
  for (const b of pings.blobs) {
    const p = parseKey(b.key);
    if (p?.kind !== "ping") continue;
    if (!firstSeen[p.install] || p.day < firstSeen[p.install]) firstSeen[p.install] = p.day;
    if (p.day < since || p.day > today) continue;
    bump(perDay, p.day);
    (perWeek[weekOf(p.day)] ??= new Set()).add(p.install);
    if (!latest[p.install] || p.day > latest[p.install].day) latest[p.install] = { key: b.key, etag: b.etag, day: p.day };
  }
  const newPerDay = {};
  for (const d of Object.values(firstSeen)) if (d >= since && d <= today) bump(newPerDay, d);
  const dayList = [];
  for (let t = Date.parse(`${since}T00:00:00Z`); dayOf(t) <= today; t += 86400e3) {
    const d = dayOf(t);
    dayList.push({ day: d, active: perDay[d] ?? 0, new: newPerDay[d] ?? 0 });
  }
  const weekList = Object.entries(perWeek).sort(([a], [b]) => (a < b ? -1 : 1)).map(([week, ids]) => ({ week, active: ids.size }));

  // Each install's most recent ping in the window: what it runs and how it's set up.
  const snaps = await readThrough("cache/latest", Object.values(latest), (v) => v);
  const b = {
    version: {}, os: {}, lang: {}, arch: {}, trackball: {}, scrollMode: {}, performance: {},
    pointerSpeed: {}, beta: {}, earlyUpdates: {}, appProfiles: {}, combos: {}, buttons: {},
  };
  let installs = 0;
  for (const l of Object.values(latest)) {
    const p = snaps[l.key];
    if (!p) continue;
    bump(b.version, p.version);
    bump(b.os, osName(p.os));
    bump(b.lang, p.lang);
    bump(b.arch, p.arch);
    if (!p.trackballs.length) bump(b.trackball, "None connected");
    for (const t of p.trackballs) bump(b.trackball, `${t.name} (0x${t.product.toString(16).padStart(4, "0")})`);
    bump(b.scrollMode, p.scrollMode);
    bump(b.performance, p.performance);
    bump(b.pointerSpeed, p.pointerSpeed);
    bump(b.beta, p.beta ? "On" : "Off");
    bump(b.earlyUpdates, p.earlyUpdates ? "On" : "Off");
    bump(b.appProfiles, bucket(p.appProfiles, [0, 1, 2, 5]));
    bump(b.combos, bucket(p.combos, [0, 1, 2, 5]));
    for (const [type, n] of Object.entries(p.buttons)) {
      b.buttons[type] ??= { installs: 0, buttons: 0 };
      b.buttons[type].installs++;
      b.buttons[type].buttons += n;
    }
    installs++;
  }

  // Crashes in the window, grouped by signature.
  const inWindow = crashes.blobs.map((c) => ({ key: c.key, etag: c.etag, p: parseKey(c.key) }))
    .filter((c) => c.p?.kind === "crash" && c.p.day >= since && c.p.day <= today);
  const small = await readThrough("cache/crashes", inWindow, (v) => ({ version: v.version, os: v.os }));
  const groups = {};
  for (const c of inWindow) {
    const g = (groups[c.p.sig] ??= { signature: c.p.sig, count: 0, ids: new Set(), firstAt: c.p.at, lastAt: c.p.at, newest: c.key, versions: {}, os: {} });
    g.count++;
    g.ids.add(c.p.install);
    if (c.p.at < g.firstAt) g.firstAt = c.p.at;
    if (c.p.at >= g.lastAt) { g.lastAt = c.p.at; g.newest = c.key; }
    const v = small[c.key];
    if (v) { bump(g.versions, v.version); bump(g.os, osName(v.os)); }
  }
  const crashList = await Promise.all(Object.values(groups).map(async ({ newest, ids, ...g }) => {
    const sample = await s.get(newest, { type: "json" });
    return { ...g, installs: ids.size, title: sample?.title ?? g.signature, sample };   // (a crash record holds no install)
  }));
  crashList.sort((x, y) => y.count - x.count || (x.lastAt < y.lastAt ? 1 : -1));

  return {
    days, since, today,
    totals: { installs, everSeen: Object.keys(firstSeen).length, crashes: inWindow.length },
    perDay: dayList, perWeek: weekList, breakdowns: b, crashes: crashList,
  };
}
