// The admin Statistics page: the daily download snapshot (functions/stats-snapshot.mjs
// and lib/downloads.mjs), the numbers made from it and from the feedback
// (lib/stats.mjs), GET /api/admin/stats, and the page's own rules (counts only,
// everything escaped, nothing the site's CSP forbids). The Blobs library is
// replaced with the in-memory stand-in and GitHub with a stub, so nothing here
// ever reaches the real site or the real GitHub. Needs
// --experimental-test-module-mocks:
//
//   npm run test:stats

import test, { mock } from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { readFile } from "node:fs/promises";
import { createMemoryStore } from "./memory-blobs.mjs";

const stores = {};
mock.module("@netlify/blobs", { namedExports: { getStore: ({ name }) => (stores[name] ??= createMemoryStore()) } });
process.env.SESSION_SECRET = "test-secret-test-secret";
process.env.SETUP_CODE = "test-setup-code";
delete process.env.NTFY_TOPIC;
let githubCalls = 0;
globalThis.fetch = async () => { githubCalls++; throw new Error("no network in tests"); };
const realNow = Date.now;
let clock = null;
Date.now = () => clock ?? realNow();

const { default: adminFn } = await import("../netlify/functions/admin.mjs");
const { default: snapshotFn, config: snapshotConfig } = await import("../netlify/functions/stats-snapshot.mjs");
const { default: publicDownloads } = await import("../netlify/functions/downloads.mjs");
const D = await import("../netlify/lib/downloads.mjs");
const S = await import("../netlify/lib/stats.mjs");

const T0 = Date.UTC(2026, 10, 10, 15, 0, 0);   // Tuesday 10 November 2026, 15:00 UTC
const DAY = 86400e3;
const at = (day, hh = 0, mm = 5) => Date.parse(`${day}T00:00:00Z`) + (hh * 60 + mm) * 60e3;

function fresh() {
  for (const k of Object.keys(stores)) delete stores[k];
  clock = T0;
  githubCalls = 0;
}

// ------------------------------------------------------------------ GitHub

const asset = (name, n) => ({ name, download_count: n });
const RELEASES = () => [
  { tag_name: "v2.10-beta.7", name: "Glideball 2.10 beta 7", published_at: "2026-11-11T05:35:36Z", prerelease: true, assets: [
    asset("Glideball.zip", 300), asset("Glideball-update.zip", 120), asset("Glide.zip", 5),
    asset("Glideball-Linux-Preview.deb", 20), asset("Glideball-Linux-Preview.tar.gz", 10),
    asset("Glideball-Windows-Preview-Setup-x64.exe", 30), asset("Glideball-Windows-Preview-x64.zip", 4),
    asset("SHA256SUMS.txt", 2),
  ] },
  { tag_name: "v2.2", name: "Glide 2.2", published_at: "2026-10-04T02:25:21Z", prerelease: false, assets: [asset("Glide.zip", 3)] },
  { tag_name: "v9.9-draft", draft: true, published_at: null, assets: [asset("Glideball.zip", 999)] },
];
/** A stand-in for fetch (or for `get`): `bump` changes the releases before each answer. */
function github({ status = 200, bump, boom } = {}) {
  const calls = [];
  const get = async (url, opts) => {
    calls.push({ url, opts });
    if (boom) throw new Error(boom);
    const rels = RELEASES();
    bump?.(rels, calls.length);
    return { ok: status === 200, status, json: async () => (status === 200 ? rels : { message: "rate limited" }) };
  };
  get.calls = calls;
  return get;
}
// Another day's worth of downloads of the main file, on the nth call.
const growing = (per) => github({ bump: (rels, n) => { rels[0].assets[0].download_count += per * (n - 1); } });

// ------------------------------------------------------------ the files

test("every release file lands in one bucket", () => {
  const b = D.bucketOf;
  assert.equal(b("Glideball.zip"), "new");
  assert.equal(b("Glideball-update.zip"), "updates");
  assert.equal(b("Glide.zip"), "updates");
  assert.equal(b("Glideball-Linux-Preview.deb"), "linux");
  assert.equal(b("Glideball-Linux-Preview.tar.gz"), "linux");
  assert.equal(b("Glideball-Windows-Preview-Setup-arm64.exe"), "windows");
  assert.equal(b("Glideball-Windows-Preview-x64.zip"), "windows");
  assert.equal(b("SHA256SUMS.txt"), "other");
  assert.equal(b("glideball.zip.sig"), "other");
  assert.equal(b(undefined), "other");
});

test("GitHub's counts: per bucket and per release, drafts left out, newest first", async () => {
  const get = github();
  const d = await D.fetchReleases(get, T0);
  assert.deepEqual(d.totals, { new: 300, updates: 128, linux: 30, windows: 34, other: 2 });
  assert.deepEqual(d.releases.map((r) => r.tag), ["v2.10-beta.7", "v2.2"]);
  assert.deepEqual(d.releases[0].counts, { new: 300, updates: 125, linux: 30, windows: 34, other: 2 });
  assert.equal(get.calls.length, 1);
  assert.match(get.calls[0].url, /api\.github\.com\/repos\/leviholliday\/glideball\/releases/);
  assert.ok(!get.calls[0].opts.headers.authorization, "unauthenticated");
});

test("the public count and the page leave out the same files", async () => {
  fresh();
  const big = github({ bump: (rels) => { rels[0].assets[0].download_count = 5000; rels.pop(); } });   // (GitHub never lists a draft to anyone not signed in)
  const real = globalThis.fetch;
  globalThis.fetch = big;
  try {
    const pub = await (await publicDownloads()).json();
    const mine = await D.fetchReleases(big, T0);
    const all = Object.values(mine.totals).reduce((s, n) => s + n, 0);
    assert.equal(pub.downloads, all - mine.totals.updates);
  } finally { globalThis.fetch = real; }
});

test("more than 100 releases are read, a page at a time, and a bad answer is an error", async () => {
  const page = (n) => Array.from({ length: n }, (_, i) => ({ tag_name: `v${i}`, published_at: "2026-01-01T00:00:00Z", assets: [asset("Glideball.zip", 1)] }));
  const get = async (url) => ({ ok: true, status: 200, json: async () => (url.includes("&page=1") ? page(100) : page(30)) });
  assert.equal((await D.fetchReleases(get, T0)).totals.new, 130);
  await assert.rejects(D.fetchReleases(async () => ({ ok: true, status: 200, json: async () => ({ message: "x" }) }), T0));
});

// ------------------------------------------------------------ the snapshot

test("one snapshot a UTC day: the first success writes, the rest only look", async () => {
  fresh();
  const store = createMemoryStore();
  const get = github();
  assert.deepEqual(await D.takeSnapshot(store, { now: at("2026-11-10"), get }), { wrote: true });
  assert.equal(get.calls.length, 1);
  // later the same day (the schedule runs four times): no GitHub request, nothing written
  store.clearStats();
  const again = await D.takeSnapshot(store, { now: at("2026-11-10", 6), get });
  assert.equal(again.wrote, false);
  assert.equal(get.calls.length, 1);
  assert.equal(store.stats().writes, 0);
  // the next day is a new one
  assert.equal((await D.takeSnapshot(store, { now: at("2026-11-11"), get })).wrote, true);
  assert.deepEqual(store.keys().filter((k) => k.startsWith("daily/")), ["daily/2026-11-10", "daily/2026-11-11"]);
  const snap = JSON.parse(store.peek("daily/2026-11-10"));
  assert.deepEqual(snap.totals, { new: 300, updates: 128, linux: 30, windows: 34, other: 2 });
  assert.deepEqual(snap.releases["v2.2"], { updates: 3 }, "zeroes are left out, to stay small");
  assert.equal(snap.at, "2026-11-10T00:05:00.000Z");
});

test("two runs at once write one snapshot", async () => {
  const store = createMemoryStore();
  const rs = await Promise.all([D.takeSnapshot(store, { now: at("2026-11-10"), get: github() }), D.takeSnapshot(store, { now: at("2026-11-10"), get: github() })]);
  assert.equal(rs.filter((r) => r.wrote).length, 1);
  assert.equal(store.keys().filter((k) => k.startsWith("daily/")).length, 1);
});

test("GitHub failing is soft: nothing written, the reason kept, the next run is the retry", async () => {
  const store = createMemoryStore();
  await D.takeSnapshot(store, { now: at("2026-11-09"), get: github() });
  const bad = await D.takeSnapshot(store, { now: at("2026-11-10"), get: github({ status: 403 }) });
  assert.deepEqual(bad, { wrote: false, error: "GitHub 403" });
  assert.ok(!store.keys().includes("daily/2026-11-10"));
  let status = JSON.parse(store.peek("status/snapshot"));
  assert.equal(status.ok, false);
  assert.equal(status.error, "GitHub 403");
  assert.equal(status.lastOkAt, "2026-11-09T00:05:00.000Z");
  // a network error's own words (they can carry a URL or a stack) are never kept
  await D.takeSnapshot(store, { now: at("2026-11-10", 6), get: github({ boom: "connect ECONNRESET https://secret.example/token=abc" }) });
  status = JSON.parse(store.peek("status/snapshot"));
  assert.equal(status.error, "couldn't reach GitHub");
  assert.ok(!store.peek("status/snapshot").includes("secret"));
  // six hours later it works
  assert.equal((await D.takeSnapshot(store, { now: at("2026-11-10", 12), get: github() })).wrote, true);
  status = JSON.parse(store.peek("status/snapshot"));
  assert.equal(status.ok, true);
  assert.equal(status.lastOkAt, "2026-11-10T12:05:00.000Z");
});

test("the scheduled function is on a valid schedule and takes the snapshot into glide-stats", async () => {
  fresh();
  assert.match(snapshotConfig.schedule, /^[0-9,*/]+ [0-9,*/]+ \* \* \*$/);
  const real = globalThis.fetch;
  globalThis.fetch = github();
  try { await snapshotFn(); } finally { globalThis.fetch = real; }
  assert.deepEqual(stores["glide-stats"].keys().filter((k) => k.startsWith("daily/")), ["daily/2026-11-10"]);
  // nothing of the feedback or usage stores was touched
  assert.deepEqual(Object.keys(stores).sort(), ["glide-stats"]);
});

test("a snapshot stays small: 40 releases in under 3 KB", async () => {
  const store = createMemoryStore();
  const rels = Array.from({ length: 40 }, (_, i) => ({ tag_name: `v2.${i}`, name: `Glideball 2.${i}`, published_at: "2026-01-01T00:00:00Z", assets: [asset("Glideball.zip", i + 1), asset("Glideball-update.zip", i), asset("Glideball-Linux-Preview.deb", 3)] }));
  await D.takeSnapshot(store, { now: at("2026-11-10"), get: async () => ({ ok: true, status: 200, json: async () => rels }) });
  const bytes = store.entries().find((e) => e.key === "daily/2026-11-10").bytes;
  assert.ok(bytes < 3000, `${bytes} bytes for 40 releases`);
});

// ------------------------------------------------------------ the history

const snap = (store, date, totals, extra = {}) =>
  store.setJSON(`daily/${date}`, { v: 1, at: `${date}T00:05:00.000Z`, totals, releases: {}, ...extra });
const live = (n = {}) => ({ updatedAt: new Date(T0).toISOString(), totals: { new: 0, updates: 0, linux: 0, windows: 0, other: 0, ...n }, releases: [] });

test("no snapshot yet: collecting, with no made-up numbers", async () => {
  const store = createMemoryStore();
  const h = await D.history(store);
  assert.deepEqual(h, { snapshots: 0, first: null, latest: null, changes: [] });
  const r = D.downloadsReport(live({ new: 40 }), h);
  assert.equal(r.collecting, true);
  assert.equal(r.yesterday, null);
  assert.equal(r.last7, null);
  assert.equal(r.sinceSnapshot, null);
  assert.deepEqual(r.perDay, []);
  assert.equal(r.totals.new, 40);
});

test("the first snapshot has no day to compare: still collecting, but 'since the snapshot' is real", async () => {
  const store = createMemoryStore();
  await snap(store, "2026-11-10", { new: 30, updates: 5 });
  const r = D.downloadsReport(live({ new: 41, updates: 5 }), await D.history(store));
  assert.equal(r.collecting, true);
  assert.equal(r.yesterday, null);
  assert.deepEqual(r.sinceSnapshot.values, { new: 11, updates: 0, linux: 0, windows: 0, other: 0 });
  assert.equal(r.sinceSnapshot.at, "2026-11-10T00:05:00.000Z");
});

test("the change per day is the difference between two mornings, covering the day before the later one", async () => {
  const store = createMemoryStore();
  await snap(store, "2026-11-01", { new: 10, updates: 100 });
  await snap(store, "2026-11-02", { new: 15, updates: 130 });
  await snap(store, "2026-11-03", { new: 15, updates: 130 });
  const r = D.downloadsReport(live({ new: 15, updates: 130 }), await D.history(store));
  assert.equal(r.collecting, false);
  assert.deepEqual(r.perDay.map((d) => [d.date, d.new, d.updates, d.estimated]), [["2026-11-01", 5, 30, false], ["2026-11-02", 0, 0, false]]);
  assert.equal(r.yesterday.date, "2026-11-02");
  assert.equal(r.yesterday.values.new, 0);
  assert.equal(r.last7.days, 2);
  assert.equal(r.last7.values.new, 5);
  assert.equal(r.snapshots, 3);
  assert.equal(r.first, "2026-11-01");
});

test("a missed day or more: the change is spread over the gap and marked as estimated", async () => {
  const store = createMemoryStore();
  await snap(store, "2026-11-01", { new: 10 });
  await snap(store, "2026-11-02", { new: 15 });
  await snap(store, "2026-11-05", { new: 24 });
  const r = D.downloadsReport(live({ new: 24 }), await D.history(store));
  assert.deepEqual(r.perDay.map((d) => [d.date, d.new, d.estimated]), [
    ["2026-11-01", 5, false], ["2026-11-02", 3, true], ["2026-11-03", 3, true], ["2026-11-04", 3, true],
  ]);
  assert.equal(r.last7.estimated, true);
  assert.equal(r.last7.values.new, 14);
});

test("a total that went down (a release taken down) is never a negative", async () => {
  const store = createMemoryStore();
  await snap(store, "2026-11-01", { new: 50, updates: 9 });
  await snap(store, "2026-11-02", { new: 20, updates: 12 });
  const r = D.downloadsReport(live({ new: 10, updates: 12 }), await D.history(store));
  assert.deepEqual(r.perDay[0].new, 0);
  assert.equal(r.perDay[0].updates, 3);
  assert.equal(r.sinceSnapshot.values.new, 0);
});

test("only the last 30 days are read, but all of them are counted as kept", async () => {
  const store = createMemoryStore();
  for (let i = 0; i < 45; i++) await snap(store, new Date(Date.UTC(2026, 8, 1) + i * DAY).toISOString().slice(0, 10), { new: i });
  store.clearStats();
  const h = await D.history(store);
  assert.equal(h.snapshots, 45);
  assert.equal(h.first, "2026-09-01");
  assert.equal(h.changes.length, 30);
  assert.equal(store.stats().reads, 31);
  assert.equal(D.perDay(h.changes).length, 30);
});

// ------------------------------------------------------------ the cache

test("GitHub is asked at most once an hour, and the last answer stands in when it can't be reached", async () => {
  const store = createMemoryStore();
  const get = growing(1);
  const a = await D.releaseCounts(store, { now: T0, get });
  await D.releaseCounts(store, { now: T0 + 59 * 60e3, get });
  assert.equal(get.calls.length, 1);
  const b = await D.releaseCounts(store, { now: T0 + 61 * 60e3, get });
  assert.equal(get.calls.length, 2);
  assert.ok(b.totals.new >= a.totals.new);
  const down = await D.releaseCounts(store, { now: T0 + 3 * 3600e3, get: github({ status: 503 }) });
  assert.equal(down.stale, true);
  assert.equal(down.totals.new, b.totals.new);
  // never answered at all: an error (the page says so, in that section only)
  await assert.rejects(D.releaseCounts(createMemoryStore(), { now: T0, get: github({ status: 503 }) }));
});

// ------------------------------------------------------------ feedback

const item = (createdAt, status, tags, extra = {}) => ({ id: createdAt, createdAt, status, tags, ...extra });

test("feedback by kind, per day and per week, and how many are open", () => {
  const all = [
    item("2026-11-10T09:00:00Z", "new", ["Bug"]),
    item("2026-11-10T01:00:00Z", "seen", ["Idea"]),
    item("2026-11-09T23:59:00Z", "done", ["Bug"]),
    item("2026-11-08T12:00:00Z", "new", ["Question"]),       // the Sunday before
    item("2026-11-02T12:00:00Z", "uploading", ["question"]),
    item("2026-10-01T12:00:00Z", "new", []),                 // no kind: other
    item("2026-10-01T12:00:00Z", "done", undefined),
    item("2025-01-01T00:00:00Z", "done", ["Bug"]),           // old: counted in all, in no chart
    item("not a date", "new", ["Bug"]),                      // skipped
  ];
  const f = S.feedbackCounts(all, T0);
  assert.equal(f.total, 8);
  assert.equal(f.open, 5);
  assert.deepEqual(f.byKind, { bug: 3, idea: 1, question: 2, other: 2 });
  assert.deepEqual(f.openByKind, { bug: 1, idea: 1, question: 2, other: 1 });
  assert.equal(f.last7Days, 4);
  assert.equal(f.last30Days, 5);
  assert.equal(f.days.length, 30);
  assert.equal(f.days.at(-1).date, "2026-11-10");
  assert.deepEqual(f.days.at(-1), { date: "2026-11-10", bug: 1, idea: 1, question: 0, other: 0 });
  assert.deepEqual(f.days.find((d) => d.date === "2026-11-09"), { date: "2026-11-09", bug: 1, idea: 0, question: 0, other: 0 });
  assert.equal(f.weeks.length, 12);
  assert.deepEqual(f.weeks.at(-1), { week: "2026-11-09", bug: 2, idea: 1, question: 0, other: 0 });
  assert.deepEqual(f.weeks.at(-2), { week: "2026-11-02", bug: 0, idea: 0, question: 2, other: 0 });
});

test("no feedback at all is fine", () => {
  const f = S.feedbackCounts([], T0);
  assert.equal(f.total, 0);
  assert.equal(f.open, 0);
  assert.ok(f.days.every((d) => d.bug + d.idea + d.question + d.other === 0));
});

// ------------------------------------------------------------ storage counts

test("blobs are counted a page at a time, and a huge store stops at the limit", async () => {
  const s = createMemoryStore();
  s.setPageSize(2);
  assert.deepEqual(await S.countBlobs(s, undefined, 10), [0, false]);
  for (const k of ["a/1", "a/2", "a/3", "a/4", "a/5", "b/1"]) await s.set(k, "x");
  assert.deepEqual(await S.countBlobs(s, "a/", 10), [5, false]);
  assert.deepEqual(await S.countBlobs(s, undefined, 10), [6, false]);
  assert.deepEqual(await S.countBlobs(s, "a/", 5), [5, false], "exactly at the limit, with none left");
  assert.deepEqual(await S.countBlobs(s, "a/", 3), [4, true], "stopped early: at least 4");
});

// ------------------------------------------------------------ the whole reply

const ID = (d, n) => `${d.replaceAll("-", "")}-120000-${String(n).padStart(8, "0").replace(/\d/g, "a")}`;

async function seedFeedback() {
  const s = (stores["glide-feedback"] ??= createMemoryStore());
  await s.setJSON(`items/${ID("2026-11-10", 1)}`, { id: ID("2026-11-10", 1), createdAt: "2026-11-10T12:00:00.000Z", status: "new", title: "SECRET TITLE", details: "SECRET DETAILS", tags: ["Bug"], priority: "high", platform: "macos", name: "Jane Secret", email: "jane@example.com", files: [] });
  await s.setJSON(`items/${ID("2026-11-09", 2)}`, { id: ID("2026-11-09", 2), createdAt: "2026-11-09T12:00:00.000Z", status: "done", title: "Another", tags: ["Idea"], priority: "normal", platform: "web", files: [] });
}

test("the whole reply: every section has data, and nothing names a person, an ID or an address", async () => {
  fresh();
  await seedFeedback();
  const store = createMemoryStore();
  await snap(store, "2026-11-08", { new: 280 });
  await snap(store, "2026-11-09", { new: 290 });
  const r = await S.statsReport({ now: T0, get: github(), store });
  assert.deepEqual(Object.keys(r).sort(), ["downloads", "feedback", "generatedAt", "health"]);
  for (const k of ["downloads", "feedback", "health"]) assert.equal(r[k].ok, true, k);
  const d = r.downloads.data;
  assert.equal(d.totals.new, 300);
  assert.equal(d.collecting, false);
  assert.equal(d.yesterday.date, "2026-11-08", "the change between the mornings of the 8th and 9th is the 8th");
  assert.equal(d.yesterday.values.new, 10);
  assert.equal(d.releases[0].tag, "v2.10-beta.7");
  assert.equal(r.feedback.data.total, 2);
  assert.equal(r.feedback.data.open, 1);
  const h = r.health.data;
  assert.equal(h.snapshots.count, 2);
  assert.equal(h.snapshots.haveToday, false);
  assert.equal(h.snapshots.lastAt, "2026-11-09T00:05:00.000Z");
  assert.deepEqual(h.storage.stores.map((s) => s.label), ["Feedback messages", "Feedback attachment pieces", "Admin sign-in and rate limits", "App stats and crash reports", "Download history and caches"]);
  assert.equal(h.storage.stores[0].count, 2);
  const body = JSON.stringify(r);
  assert.ok(!/SECRET|Jane|jane@|example\.com|"id"|"email"|"title"/i.test(body), "no feedback text, names or ids");
  assert.ok(!/[0-9a-f]{32}|\b\d{1,3}(\.\d{1,3}){3}\b|GB-/.test(body), "no hashes, addresses or install IDs");
  assert.ok(!body.includes(ID("2026-11-10", 1)));
});

test("a section that fails is its own error; the rest still load, and the error itself never leaves", async () => {
  fresh();
  const store = createMemoryStore();
  const r = await S.statsReport({ now: T0, get: github({ status: 403 }), store, summaries: async () => { throw new Error("boom with /secret/path"); } });
  assert.equal(r.downloads.ok, false);
  assert.equal(r.feedback.ok, false);
  assert.equal(r.health.ok, true);
  assert.ok(!JSON.stringify(r).includes("boom") && !JSON.stringify(r).includes("secret"));
  assert.equal(typeof r.feedback.error, "string");
});

test("a store that can't be counted is one 'couldn't count', not a failed section", async () => {
  fresh();
  const broken = { list: () => { throw new Error("nope"); } };
  const r = await S.statsReport({ now: T0, get: github(), store: createMemoryStore(), summaries: async () => [], stores: [{ label: "Broken", store: broken }, { label: "Fine", store: createMemoryStore() }] });
  assert.equal(r.health.ok, true);
  assert.deepEqual(r.health.data.storage.stores, [{ label: "Broken", count: null, partial: false }, { label: "Fine", count: 0, partial: false }]);
});

test("how the last snapshot run went shows in site health", async () => {
  fresh();
  const store = createMemoryStore();
  await D.takeSnapshot(store, { now: at("2026-11-10"), get: github({ status: 503 }) });
  const r = await S.statsReport({ now: T0, get: github(), store, summaries: async () => [], stores: [] });
  assert.deepEqual(r.health.data.snapshots.lastRun, { at: "2026-11-10T00:05:00.000Z", ok: false, error: "GitHub 503", lastOkAt: null });
  assert.equal(r.health.data.snapshots.count, 0);
});

test("opening the page asks GitHub once an hour and counts the stores once an hour", async () => {
  fresh();
  const store = createMemoryStore();
  const get = github();
  await S.statsReport({ now: T0, get, store, summaries: async () => [] });
  await S.statsReport({ now: T0 + 600e3, get, store, summaries: async () => [] });
  assert.equal(get.calls.length, 1);
  const lists = stores["glide-feedback-files"].stats().lists;
  await S.statsReport({ now: T0 + 600e3, get, store, summaries: async () => [] });
  assert.equal(stores["glide-feedback-files"].stats().lists, lists);
  await S.statsReport({ now: T0 + 2 * 3600e3, get, store, summaries: async () => [] });
  assert.equal(get.calls.length, 2);
  assert.ok(stores["glide-feedback-files"].stats().lists > lists);
});

// ------------------------------------------------------------ the endpoint

const A = (path, init = {}, cookie = "") =>
  adminFn(new Request(`https://glideball.netlify.app/api/admin/${path}`, {
    ...init, headers: { ...(init.method && init.method !== "GET" ? { "x-glide-admin": "1" } : {}), ...(cookie ? { cookie } : {}), ...(init.headers ?? {}) },
  }), { ip: "192.0.2.10" });
async function signIn() {
  const r = await A("setup", { method: "POST", body: JSON.stringify({ code: "test-setup-code", password: "a long test password" }) });
  assert.equal(r.status, 200);
  return r.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");
}

test("GET /api/admin/stats needs signing in, exactly like the other admin routes", async () => {
  fresh();
  assert.equal((await A("stats")).status, 401);
  assert.equal((await A("stats", {}, `glide_admin=${Date.now() + 1e9}.abc.def`)).status, 401, "a forged cookie");
  const cookie = await signIn();
  // a cookie from before a password change stops working here too
  const stale = cookie.replace(/glide_admin=[^;]*/, (m) => m.replace(/\.[^.]+\.([^.]+)$/, ".oldversion.$1"));
  assert.equal((await A("stats", {}, stale)).status, 401);
  assert.equal(githubCalls, 0, "nothing was fetched for a request that wasn't signed in");
  // the device cookie is not a session
  const device = cookie.split("; ").find((c) => c.startsWith("glide_device="));
  assert.equal((await A("stats", {}, device)).status, 401);
});

test("GET /api/admin/stats: the data, uncached, and it only reads", async () => {
  fresh();
  await seedFeedback();
  const cookie = await signIn();
  const real = globalThis.fetch;
  globalThis.fetch = github();
  try {
    const r = await A("stats", {}, cookie);
    assert.equal(r.status, 200);
    assert.equal(r.headers.get("cache-control"), "no-store");
    const s = await r.json();
    assert.equal(s.downloads.ok, true);
    assert.equal(s.downloads.data.totals.new, 300);
    assert.equal(s.feedback.data.total, 2);
    assert.equal(s.feedback.data.byKind.bug, 1);
    assert.equal(s.health.data.storage.stores[0].count, 2);
    assert.ok(!/SECRET|Jane|jane@|"id"/.test(JSON.stringify(s)));
    // anything but GET is not a thing (with the admin header, or without it)
    for (const method of ["POST", "PUT", "PATCH", "DELETE"]) {
      assert.equal((await A("stats", { method }, cookie)).status, 404, method);
    }
    assert.equal((await adminFn(new Request("https://glideball.netlify.app/api/admin/stats", { method: "DELETE", headers: { cookie } }), { ip: "192.0.2.10" })).status, 403);
    assert.equal((await A("stats/anything", {}, cookie)).status, 404);
    // the feedback itself is untouched: only the caches this page keeps were written
    assert.equal(stores["glide-feedback"].keys().length, 2);
    assert.deepEqual(stores["glide-stats"].keys(), ["cache/github", "cache/storage"]);
  } finally { globalThis.fetch = real; }
});

test("the Feedback page's list still works after its code moved to lib/summaries.mjs", async () => {
  fresh();
  await seedFeedback();
  const cookie = await signIn();
  const list = await (await A("feedback", {}, cookie)).json();
  assert.deepEqual(list.items.map((i) => i.title), ["SECRET TITLE", "Another"]);
  assert.ok(stores["glide-feedback-misc"].keys().includes("admin/list"));
  assert.equal(list.items[0].hasEmail, true);
  assert.ok(!("email" in list.items[0]));
});

// ------------------------------------------------------------ the page

const root = new URL("../admin/", import.meta.url);
const read = (p) => readFile(new URL(p, root), "utf8");

test("the page follows the site's CSP: no inline styles, handlers or scripts", async () => {
  const [html, js, css] = await Promise.all([read("stats/index.html"), read("stats/stats.js"), read("stats/stats.css")]);
  for (const [name, text] of [["index.html", html], ["stats.js", js]]) {
    assert.ok(!/\sstyle\s*=/i.test(text), `${name}: inline style=`);
    assert.ok(!/\son[a-z]+\s*=/i.test(text), `${name}: on*= attribute`);
    assert.ok(!/\.onclick|\.onchange|setAttribute\(\s*["']style/.test(text), `${name}: handler or style set inline`);
  }
  assert.ok(!/<script(?![^>]*\ssrc=)[^>]*>/i.test(html), "an inline script");
  assert.ok(!/https?:\/\/(?!app\.netlify\.com|github\.com)/.test(js), "no outside hosts in the script");
  assert.ok(!/@import|url\(\s*["']?https?:/.test(css), "no outside stylesheets");
  assert.match(html, /<meta name="robots" content="noindex, nofollow">/);
});

test("the three admin pages link to each other", async () => {
  const [feedback, usage, stats] = await Promise.all([read("feedback/app.js"), read("usage/usage.js"), read("stats/stats.js")]);
  assert.match(feedback, /href="\/admin\/stats\/"/);
  assert.match(usage, /href="\/admin\/stats\/"/);
  assert.match(stats, /href="\/admin\/usage\/"/);
  assert.match(stats, /href="\/admin\/feedback\/"/);
});

/** The page's render(), run without a browser (it only builds strings). */
async function pageRender() {
  const ctx = vm.createContext({ document: undefined, console, Intl, Date, Number, String, Math });
  vm.runInContext(await read("stats/stats.js"), ctx);
  return ctx.render;
}
const HOSTILE = `<img src=x onerror=alert(1)>"'&`;

test("everything rendered is escaped", async () => {
  const render = await pageRender();
  fresh();
  await seedFeedback();
  const store = createMemoryStore();
  await snap(store, "2026-11-08", { new: 280 });
  await snap(store, "2026-11-09", { new: 290 });
  const real = await S.statsReport({ now: T0, get: github(), store });
  // Hostile text anywhere a name or message could come from.
  const bad = structuredClone(real);
  bad.downloads.data.releases[0].name = HOSTILE;
  bad.downloads.data.releases[0].tag = HOSTILE;
  bad.downloads.data.updatedAt = HOSTILE;
  bad.health.data.storage.stores[0].label = HOSTILE;
  bad.health.data.snapshots.lastRun = { at: HOSTILE, ok: false, error: HOSTILE, lastOkAt: HOSTILE };
  bad.health.data.links = { netlify: `"><script>alert(1)</script>`, github: HOSTILE };
  bad.feedback.error = HOSTILE;
  const html = render(bad);
  assert.ok(!html.includes("<img src=x"), "an <img> got through");
  assert.ok(!html.includes("<script"), "a <script> got through");
  assert.ok(!/onerror=alert/.test(html.replace(/&lt;img src=x onerror=alert\(1\)&gt;/g, "")), "a handler got through");
  assert.ok(!/\sstyle=|\son[a-z]+=/.test(html.replace(/&lt;[^&]*&gt;/g, "")), "inline style or handler in the output");
  // and sections that failed say so in plain words, escaped
  const failed = render({ downloads: { ok: false, error: HOSTILE }, feedback: null, health: { ok: false } });
  assert.ok(!failed.includes("<img"));
  assert.match(failed, /Couldn&#39;t load this one right now/);
  assert.match(failed, /No data/);
});

test("the page says 'collecting' until there are two mornings, and shows real numbers after", async () => {
  const render = await pageRender();
  const empty = await S.statsReport({ now: T0, get: github(), store: createMemoryStore(), summaries: async () => [] });
  const first = render(empty);
  assert.match(first, /collecting/i);
  assert.ok(!/<svg class="cols"[^>]*aria-label="Downloads per day"/.test(first), "no download chart without a delta");
  const store = createMemoryStore();
  await snap(store, "2026-11-08", { new: 280 });
  await snap(store, "2026-11-09", { new: 290 });
  const later = render(await S.statsReport({ now: T0, get: github(), store, summaries: async () => [] }));
  assert.match(later, /<svg class="cols"[^>]*aria-label="Downloads per day"/);
  assert.match(later, /Latest full day/);
  assert.match(later, /No feedback yet/);
});
