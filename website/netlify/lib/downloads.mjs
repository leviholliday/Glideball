// What the download numbers are made of, for the Statistics page and its
// daily snapshot (functions/stats-snapshot.mjs). Everything comes from
// GitHub's own counts of the release files; nothing is counted by this site.
// GitHub only gives running totals, so a snapshot of them is kept once a day
// and the change per day is the difference between two of them.
//
// Kept in one store (glide-stats), by key:
//
//   daily/<YYYY-MM-DD>   one snapshot a day (UTC): { v, at, totals, releases }, never changed or deleted
//   status/snapshot      how the last attempt went: { at, ok, error?, lastOkAt }
//   cache/github         GitHub's answer, for an hour, so the page never asks more often
//   cache/storage        how many blobs each store holds (stats.mjs), for an hour
//
// Nothing about visitors is involved: no addresses, no IDs, only counts.
// (functions/downloads.mjs, the public /api/downloads, leaves out the same
// two update files; the tests keep the two in step.)

import { getStore } from "@netlify/blobs";
import { dayOf } from "./usage.mjs";

export const statsStore = () => getStore({ name: "glide-stats", consistency: "strong" });

export const REPO = "leviholliday/glideball";
export const FRESH_FOR = 60 * 60 * 1000;
export const DAY_MS = 86400e3;

// Where each file goes. "new" is someone downloading the Mac app (what
// Glideball.zip is); "updates" is the app fetching its own update
// (Glideball-update.zip is what the in-app updater downloads, Glide.zip is what
// Glide 2.7.1 and older update from); the Linux and Windows previews are
// theirs. Anything else (a checksum file, say) is "other".
export const BUCKETS = ["new", "updates", "linux", "windows", "other"];
export function bucketOf(name) {
  const n = String(name ?? "");
  if (/^Glideball\.zip$/i.test(n)) return "new";
  if (/^(Glideball-update|Glide)\.zip$/i.test(n)) return "updates";
  if (/linux/i.test(n)) return "linux";
  if (/windows/i.test(n)) return "windows";
  return "other";
}

export const zeroes = () => Object.fromEntries(BUCKETS.map((b) => [b, 0]));
/** `counts` without its zeroes: what a snapshot keeps, to stay small. */
const compact = (counts) => Object.fromEntries(Object.entries(counts).filter(([, n]) => n > 0));

/** GitHub's counts for every release: the totals, and the same per release
 * (newest first). Unauthenticated, one request for up to 100 releases.
 * `get` is fetch, or a stand-in for tests. Throws if GitHub can't be reached. */
export async function fetchReleases(get = fetch, now = Date.now()) {
  const headers = { accept: "application/vnd.github+json", "user-agent": "glideball-website" };
  const totals = zeroes();
  const releases = [];
  for (let page = 1; page <= 3; page++) {
    const r = await get(`https://api.github.com/repos/${REPO}/releases?per_page=100&page=${page}`, { headers, signal: AbortSignal.timeout(8000) });
    if (!r.ok) throw new Error(`GitHub ${r.status}`);
    const list = await r.json();
    if (!Array.isArray(list)) throw new Error("GitHub sent something unexpected");
    for (const rel of list) {
      if (rel.draft) continue;
      const counts = zeroes();
      for (const a of rel.assets ?? []) {
        const n = Number.isFinite(a.download_count) && a.download_count > 0 ? a.download_count : 0;
        counts[bucketOf(a.name)] += n;
      }
      for (const b of BUCKETS) totals[b] += counts[b];
      releases.push({
        tag: String(rel.tag_name ?? ""), name: String(rel.name || rel.tag_name || ""),
        publishedAt: rel.published_at ?? null, prerelease: !!rel.prerelease, counts,
      });
    }
    if (list.length < 100) break;
  }
  releases.sort((a, b) => String(b.publishedAt).localeCompare(String(a.publishedAt)));
  return { updatedAt: new Date(now).toISOString(), totals, releases };
}

/** GitHub's counts, kept an hour in cache/github. If GitHub can't be reached,
 * the last answer (marked stale); if there never was one, throws. */
export async function releaseCounts(store, { now = Date.now(), get } = {}) {
  const cached = await store.get("cache/github", { type: "json" }).catch(() => null);
  if (cached?.updatedAt && now - Date.parse(cached.updatedAt) < FRESH_FOR && now >= Date.parse(cached.updatedAt)) return cached;
  try {
    const fresh = await fetchReleases(get, now);
    await store.setJSON("cache/github", fresh).catch(() => {});
    return fresh;
  } catch (e) {
    console.error("stats: GitHub:", e?.message);
    if (cached?.releases) return { ...cached, stale: true };
    throw e;
  }
}

// ------------------------------------------------------------ the snapshot

/** What one day's snapshot keeps of GitHub's answer. */
export function snapshotOf(detail, now = Date.now()) {
  return {
    v: 1, at: new Date(now).toISOString(), totals: compact(detail.totals),
    releases: Object.fromEntries(detail.releases.filter((r) => r.tag).map((r) => [r.tag, compact(r.counts)])),
  };
}

/** Takes today's snapshot (UTC day) unless there is one: so it can run as
 * often as it likes and only the first success of a day writes. Asks GitHub
 * for fresh counts, never the cached ones. Records how the attempt went
 * (status/snapshot); never throws, since the next run is the retry.
 * Returns { wrote, skipped?, error? }. */
export async function takeSnapshot(store, { now = Date.now(), get } = {}) {
  const key = `daily/${dayOf(now)}`;
  if (await store.get(key, { type: "json" })) return { wrote: false, skipped: "already have today's" };
  const was = await store.get("status/snapshot", { type: "json" }).catch(() => null);
  try {
    const detail = await fetchReleases(get, now);
    const w = await store.setJSON(key, snapshotOf(detail, now), { onlyIfNew: true });
    await store.setJSON("cache/github", detail).catch(() => {});
    await store.setJSON("status/snapshot", { at: new Date(now).toISOString(), ok: true, lastOkAt: new Date(now).toISOString() });
    return { wrote: !!w.modified, ...(w.modified ? {} : { skipped: "another run wrote it first" }) };
  } catch (e) {
    console.error("stats: snapshot:", e?.message);
    // Only a short reason is kept (it's shown on the page), never the raw error.
    const error = /^GitHub \d{3}$/.test(e?.message ?? "") ? e.message : "couldn't reach GitHub";
    await store.setJSON("status/snapshot", { at: new Date(now).toISOString(), ok: false, error, lastOkAt: was?.lastOkAt ?? null }).catch(() => {});
    return { wrote: false, error };
  }
}

/** The kept snapshots, oldest first, for the last `window` days of changes,
 * and the change between neighbours. A snapshot is taken at about the start of
 * its UTC day, so the change from the one on day A to the one on day B (B
 * after A) is what was downloaded on days A through B-1; `days` is B-A, more
 * than 1 if the schedule missed a day or more (the change is then over the whole
 * stretch). */
export async function history(store, { window = 30 } = {}) {
  const { blobs } = await store.list({ prefix: "daily/" });
  const keys = blobs.map((b) => b.key).filter((k) => /^daily\/\d{4}-\d{2}-\d{2}$/.test(k)).sort();
  const snaps = (await Promise.all(keys.slice(-(window + 1)).map((k) =>
    store.get(k, { type: "json" }).then((v) => v && { date: k.slice(-10), ...v }).catch(() => null)))).filter(Boolean);
  const changes = [];
  for (let i = 1; i < snaps.length; i++) {
    const a = snaps[i - 1], b = snaps[i];
    const days = Math.max(1, Math.round((Date.parse(b.date) - Date.parse(a.date)) / DAY_MS));
    const change = {};
    // (Never below 0: a release taken down lowers the running total.)
    for (const k of BUCKETS) change[k] = Math.max(0, (b.totals?.[k] ?? 0) - (a.totals?.[k] ?? 0));
    changes.push({ from: a.date, to: b.date, days, change });
  }
  return { snapshots: keys.length, first: keys[0]?.slice(-10) ?? null, latest: snaps.at(-1) ?? null, changes };
}

/** One entry per calendar day for the change list: the day's downloads by
 * bucket. A stretch of several days is spread evenly (estimated: true). */
export function perDay(changes, window = 30) {
  const out = [];
  for (const c of changes) {
    for (let i = 0; i < c.days; i++) {
      const day = dayOf(Date.parse(c.from) + i * DAY_MS);
      const e = { date: day, estimated: c.days > 1 };
      for (const k of BUCKETS) e[k] = c.days > 1 ? Math.round((c.change[k] / c.days) * 10) / 10 : c.change[k];
      out.push(e);
    }
  }
  return out.slice(-window);
}

/** Downloads page numbers: totals now, and the change over a few stretches
 * (null where there isn't enough history yet: the page says "collecting"). */
export function downloadsReport(detail, hist) {
  const days = perDay(hist.changes);
  const sum = (list) => Object.fromEntries(BUCKETS.map((k) => [k, Math.round(list.reduce((s, d) => s + d[k], 0) * 10) / 10]));
  const last = days.at(-1) ?? null;
  const week = days.slice(-7);
  const latest = hist.latest;
  const sinceSnapshot = latest
    ? { at: latest.at, values: Object.fromEntries(BUCKETS.map((k) => [k, Math.max(0, detail.totals[k] - (latest.totals?.[k] ?? 0))])) }
    : null;
  return {
    updatedAt: detail.updatedAt, stale: !!detail.stale,
    totals: detail.totals,
    all: BUCKETS.reduce((s, k) => s + detail.totals[k], 0),
    collecting: days.length === 0,
    sinceSnapshot,
    yesterday: last ? { date: last.date, estimated: last.estimated, values: sum([last]) } : null,
    last7: week.length ? { days: week.length, estimated: week.some((d) => d.estimated), values: sum(week) } : null,
    perDay: days,
    snapshots: hist.snapshots, first: hist.first,
    releases: detail.releases.map((r) => ({
      tag: r.tag, name: r.name, publishedAt: r.publishedAt, prerelease: r.prerelease, counts: r.counts,
    })),
  };
}
