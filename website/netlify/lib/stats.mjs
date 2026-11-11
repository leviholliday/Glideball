// The Statistics page's data (GET /api/admin/stats): downloads from the daily
// snapshots (downloads.mjs), feedback counted from what the Feedback page
// lists (summaries.mjs), and the site's own health. Counts only: no feedback
// text, titles, names, IDs, hashes or addresses are read out, and nothing is
// collected from visitors. Read-only: opening the page writes only its own
// short-lived caches.
//
// Each part is made on its own, so one failing is one section's error and
// never blanks the page (and the reply never carries the error itself).

import { items, files, misc } from "./common.mjs";
import { usage, dayOf, weekOf } from "./usage.mjs";
import { statsStore, releaseCounts, history, downloadsReport, FRESH_FOR, DAY_MS } from "./downloads.mjs";
import { feedbackSummaries } from "./summaries.mjs";

// ---------------------------------------------------------------- feedback

export const KINDS = ["bug", "idea", "question", "other"];
/** What kind an item is: the app and the website's form both send it as the
 * first tag ("Bug", "Idea", "Question"); anything else is "other". */
export function kindOf(item) {
  const t = String(item.tags?.[0] ?? "").toLowerCase();
  return KINDS.includes(t) ? t : "other";
}
const kinds = () => Object.fromEntries(KINDS.map((k) => [k, 0]));

/** Counts from the item summaries: how many came in each day (last 30) and
 * week (last 12) by kind, and how many are open (not marked done yet). */
export function feedbackCounts(all, now = Date.now(), { dayCount = 30, weekCount = 12 } = {}) {
  const today = dayOf(now);
  const days = Array.from({ length: dayCount }, (_, i) => ({ date: dayOf(Date.parse(today) - (dayCount - 1 - i) * DAY_MS), ...kinds() }));
  const thisWeek = weekOf(today);
  const weeks = Array.from({ length: weekCount }, (_, i) => ({ week: dayOf(Date.parse(thisWeek) - (weekCount - 1 - i) * 7 * DAY_MS), ...kinds() }));
  const dayAt = new Map(days.map((d) => [d.date, d]));
  const weekAt = new Map(weeks.map((w) => [w.week, w]));
  const out = { total: 0, open: 0, byKind: kinds(), openByKind: kinds(), last7Days: 0, last30Days: 0, days, weeks };
  for (const it of all) {
    const t = Date.parse(it.createdAt);
    if (!Number.isFinite(t)) continue;
    const kind = kindOf(it);
    const day = dayOf(t);
    out.total++;
    out.byKind[kind]++;
    if (it.status !== "done") { out.open++; out.openByKind[kind]++; }
    if (now - t < 7 * DAY_MS) out.last7Days++;
    if (now - t < 30 * DAY_MS) out.last30Days++;
    const d = dayAt.get(day);
    if (d) d[kind]++;
    const w = weekAt.get(weekOf(day));
    if (w) w[kind]++;
  }
  return out;
}

// ------------------------------------------------------------- site health

// What the storage counts cover. Each store is listed once and counted (a
// list is the only cheap way to count), at most CAP blobs, and the numbers
// are kept an hour.
const STORES = () => [
  { label: "Feedback messages", store: items(), prefix: "items/" },
  { label: "Feedback attachment pieces", store: files() },
  { label: "Admin sign-in and rate limits", store: misc() },
  { label: "App stats and crash reports", store: usage() },
  { label: "Download history and caches", store: statsStore() },
];
const CAP = 20000;

/** How many blobs a store holds under `prefix`: [count, partial], where
 * partial means it stopped at `cap` with more left (so "at least"). */
export async function countBlobs(store, prefix, cap = CAP) {
  const it = store.list({ prefix, paginate: true })[Symbol.asyncIterator]();
  let n = 0;
  for (;;) {
    const { value, done } = await it.next();
    if (done) return [n, false];
    n += value.blobs.length;
    if (n >= cap) return [n, !(await it.next()).done];
  }
}

async function storageCounts(store, { now, stores, cap }) {
  const cached = await store.get("cache/storage", { type: "json" }).catch(() => null);
  if (cached?.updatedAt && now >= Date.parse(cached.updatedAt) && now - Date.parse(cached.updatedAt) < FRESH_FOR) return cached;
  const out = { updatedAt: new Date(now).toISOString(), stores: [] };
  for (const s of stores) {
    try {
      const [count, partial] = await countBlobs(s.store, s.prefix, cap);
      out.stores.push({ label: s.label, count, partial });
    } catch (e) {
      console.error("stats: counting", s.label, e?.message);
      out.stores.push({ label: s.label, count: null, partial: false });
    }
  }
  await store.setJSON("cache/storage", out).catch(() => {});
  return out;
}

/** Snapshots kept, the newest one's time, and how the last attempt went. */
async function snapshotHealth(store, now) {
  const { blobs } = await store.list({ prefix: "daily/" });
  const keys = blobs.map((b) => b.key).filter((k) => /^daily\/\d{4}-\d{2}-\d{2}$/.test(k)).sort();
  const newest = keys.length ? await store.get(keys.at(-1), { type: "json" }).catch(() => null) : null;
  const run = await store.get("status/snapshot", { type: "json" }).catch(() => null);
  return {
    count: keys.length,
    first: keys[0]?.slice(-10) ?? null,
    lastAt: newest?.at ?? null,
    haveToday: keys.at(-1)?.slice(-10) === dayOf(now),
    lastRun: run ? { at: run.at, ok: !!run.ok, error: run.ok ? null : String(run.error ?? "").slice(0, 80), lastOkAt: run.lastOkAt ?? null } : null,
  };
}

export const LINKS = {
  netlify: "https://app.netlify.com/projects/glideball",
  github: "https://github.com/leviholliday/glideball/releases",
};

// ------------------------------------------------------------ the whole reply

/** Each part on its own: { ok: true, data } or { ok: false, error }. */
export async function part(fn) {
  try { return { ok: true, data: await fn() }; } catch (e) {
    console.error("stats:", e);
    return { ok: false, error: "Couldn't load this one right now." };
  }
}

/** The whole reply. Everything is injectable for the tests:
 * store (glide-stats), get (GitHub), summaries(), stores (what to count), now, cap. */
export async function statsReport({ now = Date.now(), get, store = statsStore(), summaries = feedbackSummaries, stores, cap = CAP } = {}) {
  const [downloads, feedback, health] = await Promise.all([
    part(async () => downloadsReport(await releaseCounts(store, { now, get }), await history(store))),
    part(async () => feedbackCounts(await summaries(), now)),
    part(async () => ({
      snapshots: await snapshotHealth(store, now),
      storage: await storageCounts(store, { now, stores: stores ?? STORES(), cap }),
      links: LINKS,
    })),
  ]);
  return { generatedAt: new Date(now).toISOString(), downloads, feedback, health };
}
