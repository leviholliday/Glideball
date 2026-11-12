// The app's opt-in stats and crash reports: /api/usage, /api/crash and the
// admin's Usage page (/api/admin/usage*). The Blobs library is replaced with
// the in-memory stand-in and fetch with a stub, so nothing here ever reaches
// the real site (or Levi's phone). Needs --experimental-test-module-mocks:
//
//   npm run test:usage

import test, { mock } from "node:test";
import assert from "node:assert/strict";
import { createMemoryStore } from "./memory-blobs.mjs";

const stores = {};
mock.module("@netlify/blobs", { namedExports: { getStore: ({ name }) => (stores[name] ??= createMemoryStore()) } });
process.env.SESSION_SECRET = "test-secret-test-secret";
process.env.SETUP_CODE = "test-setup-code";
process.env.APP_KEY = "test-app-key";
delete process.env.NTFY_TOPIC;
globalThis.fetch = async () => { throw new Error("no network in tests"); };
const realNow = Date.now;
let clock = null;
Date.now = () => clock ?? realNow();

const { default: usageFn } = await import("../netlify/functions/usage.mjs");
const { default: crashFn } = await import("../netlify/functions/crash.mjs");
const { viaProxy } = await import("./admin-helpers.mjs");
const adminFn = viaProxy((await import("../netlify/functions/admin.mjs")).default);
const { default: cleanup } = await import("../netlify/functions/cleanup.mjs");
const { weekOf, scrub, signature, normalizeID, installKey } = await import("../netlify/lib/usage.mjs");

const T0 = Date.UTC(2026, 10, 10, 15, 0, 0);   // Tuesday 10 November 2026, 15:00 UTC
const DAY = 86400e3;
function fresh() {
  for (const k of Object.keys(stores)) delete stores[k];
  clock = T0;
}
const S = () => stores["glide-usage"];
// An install ID as the app makes them ("GB-" and eight groups of four Crockford
// base32 characters), and what the server keeps it under (SHA-256, hex).
const ID = (i) => `GB-${String(i).padStart(4, "0")}-7K3Q-AB12-CDEF-GHJK-MNPQ-RSTV-WXYZ`;
const H = (i) => installKey(ID(i));

const call = (fn, path, init = {}, ip = "198.51.100.7") =>
  fn(new Request(`https://glideball.netlify.app${path}`, {
    ...init, headers: { "x-glide-key": "test-app-key", ...(init.headers ?? {}) },
  }), { ip });

const PING = (i, extra = {}) => ({
  installId: ID(i), version: "2.11", build: "20", os: "26.1", lang: "en", arch: "arm64",
  trackballs: [{ name: "Kensington Expert Mouse", product: 0x1020 }],
  scrollMode: "flywheel", performance: "efficient", pointerSpeed: "4-8", beta: false,
  appProfiles: 2, combos: 1, buttons: { leftClick: 1, rightClick: 1, shortcut: 2 }, ...extra,
});
const ping = (i, extra, ip) => call(usageFn, "/api/usage", { method: "POST", body: JSON.stringify(PING(i, extra)) }, ip);

const CRASH = (i, extra = {}) => ({
  installId: ID(i), crashedAt: new Date(clock - 3600e3).toISOString(), version: "2.11", build: "20", os: "26.1", arch: "arm64",
  exception: "EXC_BREAKPOINT", signal: "SIGTRAP", termination: "Trace/BPT trap: 5",
  reason: "Fatal error: Index out of range",
  ownImage: "Glide",
  frames: [
    { image: "Glide", symbol: "Engine.hidValue(_:)", offset: 1234 },
    { image: "Glide", symbol: "closure #1 in Engine.startListening()", offset: 2000 },
    { image: "IOKit", symbol: "IOHIDQueueInterfaceCallback", offset: 300 },
  ],
  ...extra,
});
const crash = (i, extra, ip) => call(crashFn, "/api/crash", { method: "POST", body: JSON.stringify(CRASH(i, extra)) }, ip);

// ---------------------------------------------------------------- /api/usage

test("a ping is kept under its day and install, with only what's on the list", async () => {
  fresh();
  const r = await ping(1, { appNames: ["Safari"], email: "someone@example.com", windowTitle: "Secret" });
  assert.equal(r.status, 201);
  assert.deepEqual(S().keys(), [`pings/2026-11-10/${H(1)}`]);
  const kept = JSON.parse(S().peek(`pings/2026-11-10/${H(1)}`));
  assert.equal(kept.scrollMode, "flywheel");
  assert.deepEqual(kept.trackballs, [{ name: "Kensington Expert Mouse", product: 0x1020 }]);
  assert.deepEqual(kept.buttons, { leftClick: 1, rightClick: 1, shortcut: 2 });
  for (const k of ["appNames", "email", "windowTitle", "installId"]) assert.ok(!(k in kept), k);
  // no address and no raw ID anywhere: not with the data, not in a rate counter
  for (const s of Object.values(stores)) {
    for (const { key } of s.entries()) {
      assert.ok(!/198\.51|GB-/.test(key) && !/198\.51|GB-/.test(s.peek(key)), key);
    }
  }
});

test("sent again the same day, it replaces that day's; the next day is a new one", async () => {
  fresh();
  assert.equal((await ping(1)).status, 201);
  assert.equal((await ping(1, { scrollMode: "follow" })).status, 201);
  assert.equal(S().keys().length, 1);
  assert.equal(JSON.parse(S().peek(`pings/2026-11-10/${H(1)}`)).scrollMode, "follow");
  clock += DAY;
  assert.equal((await ping(1)).status, 201);
  assert.deepEqual(S().keys(), [`pings/2026-11-10/${H(1)}`, `pings/2026-11-11/${H(1)}`]);
});

test("a ping that doesn't look right is turned down whole", async () => {
  fresh();
  const bad = [
    { installId: "not-an-id" },
    { installId: "00000001-1111-4222-8333-000000000001" },
    { installId: "GB-0001-7K3Q-AB12-CDEF-GHJK-MNPQ-RSTV" },
    { installId: "GB-0001-7K3Q-AB12-CDEF-GHJK-MNPQ-RSTV-WXYU" },
    { scrollMode: "turbo" },
    { pointerSpeed: 4.5 },
    { buttons: { leftClick: 1, typedText: 3 } },
    { buttons: { shortcut: 1000 } },
    { trackballs: [{ name: "Expert Mouse <script>", product: 4128 }] },
    { trackballs: [{ name: "Expert Mouse", product: 70000 }] },
    { trackballs: Array(9).fill({ name: "Orbit", product: 1 }) },
    { lang: "en_US/../../etc" },
    { version: "x".repeat(40) },
    { beta: "yes" },
    { appProfiles: -1 },
  ];
  for (const b of bad) assert.equal((await ping(1, b)).status, 400, JSON.stringify(b));
  assert.equal(S()?.keys().length ?? 0, 0);
  const notJSON = await call(usageFn, "/api/usage", { method: "POST", body: "nope" });
  assert.equal(notJSON.status, 400);
  const big = await call(usageFn, "/api/usage", { method: "POST", body: JSON.stringify(PING(1, { pad: "x".repeat(5000) })) });
  assert.equal(big.status, 413);
});

test("only from the app (its key), and only POST or DELETE", async () => {
  fresh();
  const r = await usageFn(new Request("https://glideball.netlify.app/api/usage", { method: "POST", body: JSON.stringify(PING(1)) }), { ip: "1.2.3.4" });
  assert.equal(r.status, 403);
  assert.equal((await call(usageFn, "/api/usage", { method: "GET" })).status, 405);
  assert.equal((await call(crashFn, "/api/crash", { method: "GET" })).status, 405);
});

test("one install: 4 pings a day, then 429 until the next day", async () => {
  fresh();
  for (let i = 0; i < 4; i++) assert.equal((await ping(1)).status, 201);
  assert.equal((await ping(1)).status, 429);
  assert.equal((await ping(2)).status, 201, "another install");
  clock += DAY;
  assert.equal((await ping(1)).status, 201, "the next day");
});

test("one address (an IPv6 /64 counts as one): 30 an hour", async () => {
  fresh();
  const s = [];
  for (let i = 0; i < 35; i++) s.push((await ping(i + 1, {}, `2001:db8:5:5::${(i + 1).toString(16)}`)).status);
  assert.equal(s.filter((x) => x === 201).length, 30);
  assert.equal(s[30], 429);
  assert.equal((await ping(99, {}, "2001:db8:5:6::1")).status, 201, "another /64");
});

// ---------------------------------------------------------------- /api/crash

test("a crash is kept under its signature, with paths and emails taken out", async () => {
  fresh();
  const r = await crash(1, {
    reason: "Fatal error: couldn't open /Users/levi/Library/Application Support/Glide/x.json for levi@example.com",
    frames: [{ image: "Glide", symbol: "load(from: /Users/levi/Desktop/a.json)", offset: 10 }, { image: "libswiftCore.dylib", offset: 99 }],
  });
  assert.equal(r.status, 201);
  const [key] = S().keys();
  assert.equal(key.split(".").at(-1), H(1));
  assert.match(key, /^crashes\/[0-9a-f]{16}\/20261110-150000-[0-9a-f]{8}\.[0-9a-f]{64}$/);
  const kept = JSON.parse(S().peek(key));
  assert.ok(!/levi/.test(JSON.stringify(kept)), JSON.stringify(kept));
  assert.match(kept.reason, /\/Users\/~\/Library/);
  assert.match(kept.reason, /\(email\)/);
  assert.equal(kept.frames[1].symbol, undefined);
  assert.equal(kept.title, "EXC_BREAKPOINT (SIGTRAP) in load(from: /Users/~/Desktop/a.json)");
});

test("the same crash gets the same signature; another place, another one", async () => {
  fresh();
  assert.equal((await crash(1)).status, 201);
  assert.equal((await crash(2)).status, 201);
  assert.equal((await crash(3, { frames: [{ image: "Glide", symbol: "SmoothScroller.tick()", offset: 5 }] })).status, 201);
  const sigs = new Set(S().keys().map((k) => k.split("/")[1]));
  assert.equal(sigs.size, 2);
  // system frames under Glideball's own don't change it
  const a = { exception: "EXC_BAD_ACCESS", signal: "SIGSEGV", ownImage: "Glide", frames: [{ image: "Glide", symbol: "f()" }, { image: "libsystem", symbol: "x" }] };
  const b = { ...a, frames: [{ image: "libobjc", symbol: "objc_msgSend" }, { image: "Glide", symbol: "f()" }] };
  assert.equal(signature(a), signature(b));
});

test("a crash report that doesn't look right is turned down", async () => {
  fresh();
  const bad = [
    { crashedAt: new Date(T0 + 3 * DAY).toISOString() },
    { crashedAt: new Date(T0 - 120 * DAY).toISOString() },
    { crashedAt: "yesterday" },
    { frames: [] },
    { frames: Array(41).fill({ image: "Glide", offset: 1 }) },
    { frames: [{ image: "/Users/levi/Glide", offset: 1 }] },
    { exception: "exc_bad_access" },
    { signal: "KILL" },
    { installId: "" },
  ];
  for (const b of bad) assert.equal((await crash(1, b)).status, 400, JSON.stringify(b));
  const big = await call(crashFn, "/api/crash", { method: "POST", body: JSON.stringify(CRASH(1, { reason: "x".repeat(40000) })) });
  assert.equal(big.status, 413);
  assert.equal(S()?.keys().length ?? 0, 0);
});

test("one install: 10 crash reports a day", async () => {
  fresh();
  for (let i = 0; i < 10; i++) assert.equal((await crash(1, {}, `203.0.113.${i + 1}`)).status, 201);
  assert.equal((await crash(1, {}, "203.0.113.50")).status, 429);
  assert.equal((await crash(2, {}, "203.0.113.50")).status, 201);
});

test("scrub() takes out home folders, volumes and email addresses", () => {
  assert.equal(scrub("/Users/jane.doe/Desktop/x and /home/bob/y", 200), "/Users/~/Desktop/x and /home/~/y");
  assert.equal(scrub("on /Volumes/Backup/z", 200), "on /Volumes/~/z");
  assert.equal(scrub("/Users/o'brien/x", 200), "/Users/~/x");
  assert.equal(scrub("write to a.b@c.org now", 200), "write to (email) now");
  assert.equal(scrub("x".repeat(50), 10).length, 10);
});

// ---------------------------------------------------------------- Delete my data

test("DELETE /api/usage removes everything that install sent, and nothing else", async () => {
  fresh();
  await ping(1); await ping(2); await crash(1); await crash(2);
  clock += DAY;
  await ping(1);
  const r = await call(usageFn, "/api/usage", { method: "DELETE", body: JSON.stringify({ installId: ID(1) }) });
  assert.equal(r.status, 200);
  assert.equal((await r.json()).deleted, 3);
  assert.ok(S().keys().every((k) => !k.includes(H(1))), S().keys().join(" "));
  assert.equal(S().keys().filter((k) => k.includes(H(2))).length, 2);
  // an install that never sent anything: fine too
  const again = await call(usageFn, "/api/usage", { method: "DELETE", body: JSON.stringify({ installId: ID(1) }) });
  assert.equal((await again.json()).deleted, 0);
  const bad = await call(usageFn, "/api/usage", { method: "DELETE", body: JSON.stringify({ installId: "*" }) });
  assert.equal(bad.status, 400);
});

// ---------------------------------------------------------------- the admin's Usage page

const A = (path, init = {}, cookie = "") =>
  adminFn(new Request(`https://glideball.netlify.app/api/admin/${path}`, {
    ...init, headers: { ...(init.method && init.method !== "GET" ? { "x-glide-admin": "1" } : {}), ...(cookie ? { cookie } : {}), ...(init.headers ?? {}) },
  }), { ip: "192.0.2.10" });

async function signIn() {
  const r = await A("setup", { method: "POST", body: JSON.stringify({ code: "test-setup-code", password: "a long test password" }) });
  assert.equal(r.status, 200);
  return r.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");
}

test("the Usage page needs signing in, and deleting needs the admin header", async () => {
  fresh();
  assert.equal((await A("usage")).status, 401);
  const cookie = await signIn();
  assert.equal((await A("usage", {}, cookie)).status, 200);
  const noHeader = await adminFn(new Request("https://glideball.netlify.app/api/admin/usage/forget", { method: "POST", headers: { cookie }, body: JSON.stringify({ installId: ID(1) }) }), { ip: "192.0.2.10" });
  assert.equal(noHeader.status, 403);
  assert.equal((await A("usage?days=0", {}, cookie)).status, 400);
  assert.equal((await A("usage?days=abc", {}, cookie)).status, 400);
});

test("active installs by day and week, settings, and crashes grouped", async () => {
  fresh();
  const cookie = await signIn();
  // Monday 2 November: installs 1 and 2. Tuesday 10 November (today): 1, 3 and 4.
  clock = Date.UTC(2026, 10, 2, 12);
  await ping(1, { version: "2.10" });
  await ping(2, { trackballs: [] });
  await crash(2);
  clock = T0;
  await ping(1);
  await ping(3, { scrollMode: "native", beta: true, trackballs: [{ name: "Kensington SlimBlade Trackball", product: 0x2041 }, { name: "Kensington Expert Mouse", product: 0x1020 }] });
  await ping(4, { os: "26.0.1", lang: "pt-BR", buttons: {} });
  await crash(1);
  await crash(3);
  await crash(3, { frames: [{ image: "Glide", symbol: "SmoothScroller.tick()", offset: 5 }] });

  const r = await A("usage?days=30", {}, cookie);
  assert.equal(r.status, 200);
  const d = await r.json();
  assert.equal(d.today, "2026-11-10");
  assert.equal(d.perDay.length, 30);
  assert.deepEqual(d.perDay.at(-1), { day: "2026-11-10", active: 3, new: 2 });
  assert.deepEqual(d.perDay.find((x) => x.day === "2026-11-02"), { day: "2026-11-02", active: 2, new: 2 });
  assert.deepEqual(d.perWeek, [{ week: "2026-11-02", active: 2 }, { week: "2026-11-09", active: 3 }]);
  assert.equal(d.totals.installs, 4);
  assert.equal(d.totals.crashes, 4);
  const b = d.breakdowns;
  assert.deepEqual(b.version, { "2.11": 4 }, "install 1's most recent day is 2.11, not the 2.10 before it");
  assert.deepEqual(b.trackball, { "Kensington Expert Mouse (0x1020)": 3, "Kensington SlimBlade Trackball (0x2041)": 1, "None connected": 1 });
  assert.deepEqual(b.scrollMode, { flywheel: 3, native: 1 });
  assert.deepEqual(b.beta, { Off: 3, On: 1 });
  assert.deepEqual(b.os, { "macOS 26.1": 3, "macOS 26.0": 1 });
  assert.deepEqual(b.appProfiles, { "2–4": 4 });
  assert.deepEqual(b.buttons.shortcut, { installs: 3, buttons: 6 });
  // no install's ID, nor its hash, anywhere in what the page gets
  const text = JSON.stringify(d);
  for (let i = 1; i <= 4; i++) assert.ok(!text.includes(ID(i)) && !text.includes(H(i)), `install ${i}`);
  assert.ok(!("installs" in d));

  assert.equal(d.crashes.length, 2);
  const [top] = d.crashes;
  assert.equal(top.count, 3);
  assert.equal(top.installs, 3);
  assert.equal(top.title, "EXC_BREAKPOINT (SIGTRAP) in Engine.hidValue(_:)");
  assert.equal(top.sample.frames.length, 3);
  assert.deepEqual(top.versions, { "2.11": 3 });

  // a shorter window leaves the 2nd out
  const week = await (await A("usage?days=7", {}, cookie)).json();
  assert.equal(week.totals.installs, 3);
  assert.equal(week.totals.crashes, 3);
});

test("a second visit reads only what changed", async () => {
  fresh();
  const cookie = await signIn();
  for (let i = 1; i <= 20; i++) { await ping(i); await crash(i); }
  await A("usage", {}, cookie);
  S().clearStats();
  await A("usage", {}, cookie);
  // the two lists, the two kept copies, and one sample per kind of crash
  assert.ok(S().stats().reads <= 4, JSON.stringify(S().stats()));
  await ping(21);
  S().clearStats();
  const d = await (await A("usage", {}, cookie)).json();
  assert.equal(d.totals.installs, 21);
  assert.ok(S().stats().reads <= 5, JSON.stringify(S().stats()));
});

test("the admin looks up and deletes one install only from an ID pasted in", async () => {
  fresh();
  const cookie = await signIn();
  await ping(1, { scrollMode: "follow" }); await ping(2); await crash(1);
  await A("usage", {}, cookie);   // so there are kept copies to drop
  // as someone might paste it: lower case, spaces, O for 0
  const pasted = ` ${ID(1).toLowerCase().replace(/-/g, " ").replace("0001", "OOO1")} `;
  const look = await A("usage/lookup", { method: "POST", body: JSON.stringify({ installId: pasted }) }, cookie);
  assert.equal(look.status, 200);
  const one = await look.json();
  assert.equal(one.found, true);
  assert.deepEqual(one.days, ["2026-11-10"]);
  assert.equal(one.latest.scrollMode, "follow");
  assert.equal(one.crashCount, 1);
  assert.ok(!JSON.stringify(one).includes(H(1)), "no hash in the reply");
  const r = await A("usage/forget", { method: "POST", body: JSON.stringify({ installId: pasted }) }, cookie);
  assert.equal(r.status, 200);
  assert.equal((await r.json()).deleted, 2);
  const d = await (await A("usage", {}, cookie)).json();
  assert.equal(d.totals.installs, 1);
  assert.equal(d.crashes.length, 0);
  assert.equal((await (await A("usage/lookup", { method: "POST", body: JSON.stringify({ installId: ID(1) }) }, cookie)).json()).found, false);
  // a hash is no way in: only the ID itself
  for (const installId of [H(2), "nope", ""]) {
    assert.equal((await A("usage/forget", { method: "POST", body: JSON.stringify({ installId }) }, cookie)).status, 400, installId);
  }
  assert.equal((await A(`usage/install/${H(2)}`, { method: "DELETE" }, cookie)).status, 404);
});

test("normalizeID() reads an ID however it's pasted, and nothing else", () => {
  assert.equal(normalizeID(ID(1)), ID(1));
  assert.equal(normalizeID(ID(1).toLowerCase()), ID(1));
  assert.equal(normalizeID(ID(1).replace(/-/g, "")), ID(1));
  assert.equal(normalizeID("gb-ooo1 7k3q ab12 cdef ghjk mnpq rstv wxyz"), ID(1));
  assert.equal(normalizeID("GB-OOOL-7K3Q-AB12-CDEF-GHJK-MNPQ-RSTV-WXYZ"), ID(1));
  for (const bad of ["", "GB-", ID(1) + "-AAAA", ID(1).replace("WXYZ", "WXYU"), ID(1).slice(3), 42, null, "x".repeat(100)]) {
    assert.equal(normalizeID(bad), null, String(bad));
  }
  assert.match(installKey(ID(1)), /^[0-9a-f]{64}$/);
});

test("the admin deletes a period (both days included), and only that", async () => {
  fresh();
  const cookie = await signIn();
  for (const day of [1, 2, 3, 4, 5]) {
    clock = Date.UTC(2026, 10, day, 12);
    await ping(1);
    await crash(2);
  }
  clock = T0;
  const r = await A("usage/range?from=2026-11-02&to=2026-11-04", { method: "DELETE" }, cookie);
  assert.equal(r.status, 200);
  assert.equal((await r.json()).deleted, 6);
  const days = S().keys().map((k) => (k.startsWith("pings/") ? k.split("/")[1] : k.split("/")[2].slice(0, 8)));
  assert.deepEqual(days.sort(), ["2026-11-01", "2026-11-05", "20261101", "20261105"]);
  for (const q of ["from=2026-11-05&to=2026-11-01", "from=2026-02-30&to=2026-03-01", "from=&to=2026-11-01", "from=2026-1-1&to=2026-11-01"]) {
    assert.equal((await A(`usage/range?${q}`, { method: "DELETE" }, cookie)).status, 400, q);
  }
});

test("weeks start on Monday", () => {
  assert.equal(weekOf("2026-11-09"), "2026-11-09");   // Monday
  assert.equal(weekOf("2026-11-15"), "2026-11-09");   // Sunday
  assert.equal(weekOf("2026-11-16"), "2026-11-16");
  assert.equal(weekOf("2027-01-01"), "2026-12-28");
});

test("the hourly cleanup drops old rate counters and never touches the data", async () => {
  fresh();
  await ping(1); await crash(1);
  const before = S().keys();
  clock = T0 + 3 * DAY;
  await cleanup();
  assert.deepEqual(S().keys(), before);
  assert.equal(stores["glide-feedback-misc"].keys().filter((k) => k.startsWith("rate/")).length, 0);
});

// ---------------------------------------------------------------- security review, 2026-11-11

test("a version named like an object's own methods counts as a number", async () => {
  fresh();
  const cookie = await signIn();
  await ping(1, { version: "constructor" });
  await ping(2, { version: "toString" });
  await ping(3, { version: "constructor" });
  await crash(1, { version: "constructor" });
  const d = await (await A("usage", {}, cookie)).json();
  assert.deepEqual(d.breakdowns.version, { constructor: 2, toString: 1 });
  assert.deepEqual(d.crashes[0].versions, { constructor: 1 });
});

test("scrub() can't be got round with invisible characters, case or a drive name with spaces", () => {
  const ZWSP = String.fromCodePoint(0x200b), RLO = String.fromCodePoint(0x202e), LRI = String.fromCodePoint(0x2066);
  assert.equal(scrub("/Us\u0001ers/jane/x", 200), "/Users/~/x");
  assert.equal(scrub(`/Users/ja${ZWSP}ne/x`, 200), "/Users/~/x");
  assert.equal(scrub("/users/jane/x", 200), "/users/~/x");
  assert.equal(scrub("on /Volumes/Jane Doe's Passport/z", 200), "on /Volumes/~/z");
  assert.equal(scrub(`j${ZWSP}ane@exa\u0002mple.com`, 200), "(email)");
  assert.equal(scrub(`a${RLO}b${LRI}c`, 200), "abc");
  assert.equal(scrub("line one\nline two\ttab", 200), "line one\nline two\ttab");
});

test("Delete my data: at most 500 a day from everywhere (each one reads every key)", async () => {
  fresh();
  const del = (ip) => call(usageFn, "/api/usage", { method: "DELETE", body: JSON.stringify({ installId: ID(1) }) }, ip);
  const codes = [];
  for (let i = 0; i < 501; i++) codes.push((await del(`203.0.${Math.floor(i / 20)}.${(i % 20) + 1}`)).status);
  assert.equal(codes.filter((c) => c === 200).length, 500);
  assert.equal(codes.at(-1), 429);
  clock += DAY;
  assert.equal((await del("203.0.113.200")).status, 200, "the next day");
});

test("feedback: at most 200 items a day from everywhere, however many addresses", async () => {
  fresh();
  const { default: feedbackFn } = await import("../netlify/functions/feedback.mjs");
  const send = (ip) => call(feedbackFn, "/api/feedback", { method: "POST", body: JSON.stringify({ title: "Hi", platform: "web" }) }, ip);
  const codes = [];
  for (let i = 0; i < 201; i++) codes.push((await send(`198.18.${Math.floor(i / 12)}.${(i % 12) + 1}`)).status);
  assert.equal(codes.filter((c) => c === 201).length, 200);
  assert.equal(codes.at(-1), 429);
  clock += DAY;
  assert.equal((await send("198.18.200.1")).status, 201, "the next day");
});

test("the admin pages get a policy of their own, with no outside scripts", async () => {
  const { readFile } = await import("node:fs/promises");
  const toml = await readFile(new URL("../../admin-site/netlify.toml", import.meta.url), "utf8");
  const block = /for = "\/\*"\s*\[headers\.values\]([\s\S]*?)(?=\n\[\[|$)/.exec(toml)?.[1] ?? "";
  const csp = /Content-Security-Policy = "([^"]+)"/.exec(block)?.[1] ?? "";
  assert.match(csp, /script-src 'self';/);
  assert.match(csp, /connect-src 'self';/);
  assert.ok(!/https?:|sha256-|unsafe/.test(csp), csp);
});
