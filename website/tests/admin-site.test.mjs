// The admin site (admin-site/, docs/ADMIN-SITE.md): its edge function passes
// /api/admin/* on to this site's admin function, which keeps the data. Here
// the real proxy (admin-site/netlify/edge-functions/admin-proxy.js) talks to
// the real admin function, with the in-memory Blobs stand-in and no network:
// nothing here reaches either real site.
//
//   node --experimental-test-module-mocks --test tests/admin-site.test.mjs

import test, { mock } from "node:test";
import assert from "node:assert/strict";
import { readFile, readdir, access } from "node:fs/promises";
import { createMemoryStore } from "./memory-blobs.mjs";

const stores = {};
mock.module("@netlify/blobs", { namedExports: { getStore: ({ name }) => (stores[name] ??= createMemoryStore()) } });
process.env.SESSION_SECRET = "test-secret-test-secret";
process.env.SETUP_CODE = "test-setup-code";
delete process.env.NTFY_TOPIC;
globalThis.fetch = async () => { throw new Error("no network in tests"); };

const { PROXY_SECRET } = await import("./admin-helpers.mjs");   // sets ADMIN_PROXY_SECRET
const A = await import("../netlify/functions/admin.mjs");
const P = await import("../../admin-site/netlify/edge-functions/admin-proxy.js");
const { items, files, misc } = await import("../netlify/lib/common.mjs");

const ADMIN = "https://admin-glideball.netlify.app";
const PROXY_IP = "198.51.100.200";   // the edge function's own address, as the main site sees it
let upstreamCalls = [];
/** The main site, as the proxy reaches it: the real admin function. */
const upstream = async (target, init) => {
  const req = new Request(target, init);
  upstreamCalls.push(req.clone());
  return A.default(req, { ip: PROXY_IP });
};
/** A browser on the admin site asking for /api/admin/<path>. */
function visit(path, { method = "GET", body, cookie, ip = "192.0.2.10", headers = {}, secret = PROXY_SECRET } = {}) {
  const h = { ...headers };
  if (method !== "GET") h["x-glide-admin"] = "1";
  if (body !== undefined) h["content-type"] = "application/json";
  if (cookie) h.cookie = cookie;
  const req = new Request(`${ADMIN}/api/admin/${path}`, { method, headers: h, body: body === undefined ? undefined : JSON.stringify(body) });
  return P.proxy(req, { ip }, { secret, upstream: "https://glideball.netlify.app", fetch: upstream });
}
const cookiesOf = (res) => res.headers.getSetCookie();
const jar = (res) => cookiesOf(res).map((c) => c.split(";")[0]).join("; ");

function fresh() {
  for (const k of Object.keys(stores)) delete stores[k];
  upstreamCalls = [];
}
async function signIn(ip) {
  const r = await visit("setup", { method: "POST", body: { code: "test-setup-code", password: "a long password" }, ip });
  assert.equal(r.status, 200);
  return jar(r);
}

test("set up, sign in and read the session, all through the admin site", async () => {
  fresh();
  assert.deepEqual(await (await visit("session")).json(), { needsSetup: true, loggedIn: false });
  const setup = await visit("setup", { method: "POST", body: { code: "test-setup-code", password: "a long password" } });
  assert.equal(setup.status, 200);
  // The cookies belong to the admin site's host: no Domain, so the browser
  // keeps them for admin-glideball.netlify.app alone.
  const set = cookiesOf(setup);
  assert.equal(set.length, 2);
  for (const c of set) {
    assert.ok(!/;\s*domain=/i.test(c), c);
    assert.match(c, /; HttpOnly; Secure; SameSite=Strict;/);
  }
  assert.match(set[0], /^glide_admin=[^;]+; Path=\/api\/admin;/);
  assert.match(set[1], /^glide_device=[^;]+; Path=\/api\/admin\/login;/);
  assert.deepEqual(await (await visit("session", { cookie: jar(setup) })).json(), { needsSetup: false, loggedIn: true });
  // signing out and in again
  assert.equal((await visit("logout", { method: "POST", cookie: jar(setup) })).status, 200);
  const login = await visit("login", { method: "POST", body: { password: "a long password" } });
  assert.equal(login.status, 200);
  assert.equal((await visit("feedback", { cookie: jar(login) })).status, 200);
  // every forwarded request carried the secret and the visitor's own address
  for (const r of upstreamCalls) {
    assert.equal(r.headers.get("x-glide-admin-proxy"), PROXY_SECRET);
    assert.equal(r.headers.get("x-glide-client-ip"), "192.0.2.10");
  }
});

test("the main site's data reads and changes through the proxy (feedback and an attachment)", async () => {
  fresh();
  const cookie = await signIn();
  const id = "20261111-120000-a1b2c3d4";
  await items().setJSON(`items/${id}`, {
    id, createdAt: "2026-11-11T12:00:00Z", status: "new", title: "Ring stutters", priority: "high", platform: "macos",
    details: "x", files: [{ name: "shot.png", type: "image/png", size: 6, chunks: [6], total: 1, done: true }],
  });
  await files().set(`${id}/shot.png/0`, new Uint8Array([1, 2, 3, 4, 5, 6]));
  const list = await (await visit("feedback", { cookie })).json();
  assert.deepEqual(list.items.map((x) => x.title), ["Ring stutters"]);
  const patched = await visit(`feedback/${id}`, { method: "PATCH", body: { status: "done" }, cookie });
  assert.equal(patched.status, 200);
  assert.equal((await items().get(`items/${id}`, { type: "json" })).status, "done");
  // a byte range of the attachment, with the headers the player needs
  const part = await visit(`file?id=${id}&name=shot.png`, { cookie, headers: { range: "bytes=2-3" } });
  assert.equal(part.status, 206);
  assert.equal(part.headers.get("content-range"), "bytes 2-3/6");
  assert.match(part.headers.get("content-security-policy"), /^sandbox/);
  assert.deepEqual([...new Uint8Array(await part.arrayBuffer())], [3, 4]);
  assert.equal((await visit("usage?days=7", { cookie })).status, 200);
  assert.equal((await visit("stats", { cookie })).status, 200);
});

test("the main site refuses a wrong or missing proxy secret before reading anything", async () => {
  fresh();
  await signIn();
  const before = { ...stores["glide-feedback-misc"].stats() };
  for (const secret of ["x".repeat(40), PROXY_SECRET.slice(0, -1) + "?"]) {
    const req = new Request("https://glideball.netlify.app/api/admin/session", { headers: { "x-glide-admin-proxy": secret } });
    const r = await A.default(req, { ip: "192.0.2.66" });
    assert.equal(r.status, 403);
    assert.match((await r.json()).error, /admin-glideball\.netlify\.app/);
  }
  assert.deepEqual(stores["glide-feedback-misc"].stats(), before, "nothing read or counted");
  // a short ADMIN_PROXY_SECRET, or none, lets no proxied request in
  const saved = process.env.ADMIN_PROXY_SECRET;
  try {
    process.env.ADMIN_PROXY_SECRET = "short";
    assert.equal(A.caller(new Request("https://x/", { headers: { "x-glide-admin-proxy": "short" } }), {}), null);
    delete process.env.ADMIN_PROXY_SECRET;
    assert.equal(A.caller(new Request("https://x/", { headers: { "x-glide-admin-proxy": "" } }), {}), null);
  } finally {
    process.env.ADMIN_PROXY_SECRET = saved;
  }
});

test("direct requests: allowed until the cut-over, refused after; never trusted for an address", () => {
  const direct = new Request("https://glideball.netlify.app/api/admin/session", { headers: { "x-glide-client-ip": "203.0.113.9" } });
  assert.deepEqual(A.caller(direct, { ip: "192.0.2.5" }, true), { ip: "192.0.2.5" }, "its own address, not the header's");
  assert.equal(A.caller(direct, { ip: "192.0.2.5" }, false), null);
  const viaProxy = new Request("https://glideball.netlify.app/api/admin/session", { headers: { "x-glide-admin-proxy": PROXY_SECRET, "x-glide-client-ip": "203.0.113.9" } });
  assert.deepEqual(A.caller(viaProxy, { ip: PROXY_IP }, false), { ip: "203.0.113.9" });
  const junkIP = new Request("https://x/", { headers: { "x-glide-admin-proxy": PROXY_SECRET, "x-glide-client-ip": "1.2.3.4; evil" } });
  assert.deepEqual(A.caller(junkIP, { ip: PROXY_IP }, false), { ip: PROXY_IP });
});

test("wrong passwords are limited per visitor, not per proxy", async () => {
  fresh();
  await signIn("192.0.2.1");
  for (let i = 0; i < 8; i++) assert.equal((await visit("login", { method: "POST", body: { password: "wrong" }, ip: "192.0.2.77" })).status, 401);
  assert.equal((await visit("login", { method: "POST", body: { password: "wrong" }, ip: "192.0.2.77" })).status, 429);
  // someone else, through the same proxy, isn't locked out
  assert.equal((await visit("login", { method: "POST", body: { password: "a long password" }, ip: "192.0.2.88" })).status, 200);
});

test("the proxy: a visitor can't send the secret or an address of their own, nor a change from another site", async () => {
  fresh();
  await visit("session", { headers: { "x-glide-admin-proxy": "mine", "x-glide-client-ip": "203.0.113.1", "x-forwarded-for": "203.0.113.2" } });
  const [r] = upstreamCalls;
  assert.equal(r.headers.get("x-glide-admin-proxy"), PROXY_SECRET);
  assert.equal(r.headers.get("x-glide-client-ip"), "192.0.2.10");
  assert.equal(r.headers.get("x-forwarded-for"), null);
  upstreamCalls = [];
  const cross = await visit("logout", { method: "POST", headers: { origin: "https://evil.example" } });
  assert.equal(cross.status, 403);
  assert.equal(upstreamCalls.length, 0, "never passed on");
  // the admin site without its secret set: nothing is passed on
  assert.equal((await visit("session", { secret: null })).status, 500);
  assert.equal((await visit("session", { secret: "too short" })).status, 500);
  assert.equal(upstreamCalls.length, 0);
});

test("the proxy: only the reply headers the pages need, and a failed main site is a 502", async () => {
  const reply = new Response("{}", { headers: { "content-type": "application/json", "x-secret-thing": "1", "access-control-allow-origin": "*", "set-cookie": "a=1; Path=/api/admin; HttpOnly; Secure; SameSite=Strict" } });
  const r = await P.proxy(new Request(`${ADMIN}/api/admin/session`), { ip: "192.0.2.1" }, { secret: PROXY_SECRET, fetch: async () => reply });
  assert.equal(r.headers.get("x-secret-thing"), null);
  assert.equal(r.headers.get("access-control-allow-origin"), null);
  assert.equal(r.headers.get("cross-origin-resource-policy"), "same-origin");
  assert.equal(r.headers.get("cache-control"), "no-store");
  assert.deepEqual(r.headers.getSetCookie(), ["a=1; Path=/api/admin; HttpOnly; Secure; SameSite=Strict"]);
  const down = await P.proxy(new Request(`${ADMIN}/api/admin/session`), {}, { secret: PROXY_SECRET, fetch: async () => { throw new TypeError("fetch failed"); } });
  assert.equal(down.status, 502);
  const elsewhere = await P.proxy(new Request(`${ADMIN}/api/other`), {}, { secret: PROXY_SECRET, fetch: async () => reply });
  assert.equal(elsewhere.status, 404);
  assert.equal(P.config.path, "/api/admin/*");
  assert.equal(P.UPSTREAM, "https://glideball.netlify.app");
});

// ------------------------------------------------------------------ the pages

const site = new URL("../../admin-site/", import.meta.url);
async function pageFiles(dir = new URL("public/", site)) {
  const out = [];
  for (const e of await readdir(dir, { withFileTypes: true })) {
    const u = new URL(e.name + (e.isDirectory() ? "/" : ""), dir);
    if (e.isDirectory()) { if (e.name !== "assets") out.push(...(await pageFiles(u))); } else out.push(u);
  }
  return out;
}

test("the admin site's pages: home, feedback, usage and stats, own files only, nothing inline", async () => {
  const all = await pageFiles();
  const names = all.map((u) => u.pathname.slice(new URL("public/", site).pathname.length)).sort();
  for (const p of ["index.html", "feedback/index.html", "usage/index.html", "stats/index.html", "robots.txt"]) assert.ok(names.includes(p), p);
  for (const u of all) {
    const text = await readFile(u, "utf8");
    const name = u.pathname.split("/admin-site/")[1];
    if (/\.(html|js)$/.test(name)) {
      assert.ok(!/\sstyle\s*=/i.test(text), `${name}: inline style=`);
      assert.ok(!/\son[a-z]+\s*=/i.test(text), `${name}: on*= attribute`);
      assert.ok(!/\/admin\//.test(text.replace(/\/api\/admin\//g, "")), `${name}: an old /admin/ link (links between pages are relative)`);
      assert.ok(!/(?:src|href)\s*=\s*["']https?:/i.test(text), `${name}: something from another host`);
    }
    if (name.endsWith(".html")) {
      assert.ok(!/<script(?![^>]*\ssrc=)[^>]*>/i.test(text), `${name}: an inline script`);
      assert.match(text, /<meta name="robots" content="noindex, nofollow">/, name);
      // every /assets/ file a page uses exists in website/assets/ (deploy-admin.sh copies them)
      for (const [, a] of text.matchAll(/"\/assets\/([^"]+)"/g)) await access(new URL(`../assets/${a}`, import.meta.url));
    }
  }
  assert.match(await readFile(new URL("public/robots.txt", site), "utf8"), /Disallow: \//);
});

test("the admin site's netlify.toml: strict policy, noindex, the proxy, no analytics", async () => {
  const toml = await readFile(new URL("netlify.toml", site), "utf8");
  const csp = /Content-Security-Policy = "([^"]+)"/.exec(toml)?.[1] ?? "";
  assert.match(csp, /default-src 'none';/);
  assert.match(csp, /script-src 'self';/);
  assert.match(csp, /connect-src 'self';/);
  assert.match(csp, /frame-ancestors 'none'/);
  assert.ok(!/https?:|sha256-|unsafe|\*/.test(csp), csp);
  assert.match(toml, /X-Robots-Tag = "noindex, nofollow"/);
  assert.match(toml, /edge_functions = "netlify\/edge-functions"/);
  assert.ok(!/googletagmanager|google-analytics|cloudflareinsights/.test(toml));
});
