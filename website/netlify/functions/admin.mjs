// The admin side: one password (set once with SETUP_CODE, then changeable),
// a signed cookie, and the feedback itself.
//
//   GET    /api/admin/session                  { needsSetup, loggedIn }
//   POST   /api/admin/setup     {code, password}   first password, once
//   POST   /api/admin/login     {password}
//   POST   /api/admin/logout
//   POST   /api/admin/password  {current, next}
//   GET    /api/admin/feedback                 every item, newest first
//   GET    /api/admin/feedback/:id
//   PATCH  /api/admin/feedback/:id  {status}
//   DELETE /api/admin/feedback/:id
//   GET    /api/admin/file?id&name              an attachment (Range requests too, for video)

import crypto from "node:crypto";
import {
  STATUSES, UPLOAD_WINDOW, items, files, misc, env, json, fail, sameSecret, randomToken, clientIP, allow, forAdmin, changeItem, whole,
} from "../lib/common.mjs";

export const config = { path: "/api/admin/*" };

const COOKIE = "glide_admin";
const DAYS = 30;
const SCRYPT = { N: 32768, r: 8, p: 1, maxmem: 96 * 1024 * 1024 };

const passwordRecord = () => misc().get("admin/password", { type: "json" });

function hashPassword(pw) {
  const salt = crypto.randomBytes(16);
  const hash = crypto.scryptSync(pw, salt, 64, SCRYPT);
  // v changes with every password, so old sessions stop working.
  return { salt: salt.toString("base64"), hash: hash.toString("base64"), N: SCRYPT.N, r: SCRYPT.r, p: SCRYPT.p, v: randomToken(9) };
}
function checkPassword(pw, rec) {
  const h = crypto.scryptSync(String(pw ?? ""), Buffer.from(rec.salt, "base64"), 64, { N: rec.N, r: rec.r, p: rec.p, maxmem: SCRYPT.maxmem });
  return crypto.timingSafeEqual(h, Buffer.from(rec.hash, "base64"));
}

const secret = () => env("SESSION_SECRET");
const sign = (payload) => crypto.createHmac("sha256", secret()).update(payload).digest("base64url");
function session(rec) {
  const p = `${Date.now() + DAYS * 86400e3}.${rec.v}`;
  return `${p}.${sign(p)}`;
}
const cookieHeader = (value, maxAge) =>
  `${COOKIE}=${value}; Path=/api/admin; HttpOnly; Secure; SameSite=Strict; Max-Age=${maxAge}`;
function readCookie(req) {
  const m = (req.headers.get("cookie") ?? "").match(new RegExp(`(?:^|;\\s*)${COOKIE}=([^;]+)`));
  return m ? m[1] : null;
}
async function signedIn(req) {
  const c = readCookie(req);
  if (!c || !secret()) return false;
  const [exp, v, sig] = c.split(".");
  if (!exp || !v || !sig || !sameSecret(sig, sign(`${exp}.${v}`)) || Number(exp) < Date.now()) return false;
  const rec = await passwordRecord();
  return !!rec && rec.v === v;
}

// Whatever goes wrong, the reply never carries the error itself (the
// platform's own error reply would include the stack).
export default async (req, context) => {
  try {
    return await route(req, context);
  } catch (e) {
    console.error("admin:", e);
    return fail(500, "Something went wrong.");
  }
};

async function route(req, context) {
  if (!secret()) return fail(500, "The site isn't set up (SESSION_SECRET).");
  const path = new URL(req.url).pathname.replace(/^\/api\/admin\/?/, "").replace(/\/+$/, "");
  // (Nothing to decode: ids and route names are plain letters and digits.)
  const parts = path.split("/");
  const m = req.method;

  // Anything that changes something carries this header, which a page on
  // another site can't add without asking first (and it won't be asked).
  if (m !== "GET" && req.headers.get("x-glide-admin") !== "1") return fail(403, "Missing header.");

  if (path === "session" && m === "GET") {
    return json({ needsSetup: !(await passwordRecord()), loggedIn: await signedIn(req) });
  }
  if (path === "setup" && m === "POST") return setup(req, context);
  if (path === "login" && m === "POST") return login(req, context);
  if (path === "logout" && m === "POST") {
    return json({ ok: true }, 200, { "set-cookie": cookieHeader("", 0) });
  }

  if (!(await signedIn(req))) return fail(401, "Sign in first.");

  if (path === "password" && m === "POST") return changePassword(req);
  if (path === "file" && m === "GET") {
    const url = new URL(req.url);
    const id = url.searchParams.get("id") ?? "";
    if (!/^[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$/.test(id)) return fail(404, "No such feedback.");
    const item = await items().get(`items/${id}`, { type: "json" });
    return item ? serve(req, item, url.searchParams.get("name") ?? "") : fail(404, "No such feedback.");
  }
  if (parts[0] === "feedback") {
    if (parts.length === 1 && m === "GET") return list();
    const id = parts[1];
    if (!/^[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$/.test(id ?? "")) return fail(404, "No such feedback.");
    const item = await items().get(`items/${id}`, { type: "json" });
    if (!item) return fail(404, "No such feedback.");
    if (parts.length === 2) {
      if (m === "GET") return json(forAdmin(item));
      if (m === "PATCH") return update(req, item);
      if (m === "DELETE") return remove(item);
    }
  }
  return fail(404, "Not here.");
}

/** The JSON object sent, or {} for anything else (null, a list, not JSON). */
async function body(req) {
  try {
    const v = await req.json();
    return v && typeof v === "object" && !Array.isArray(v) ? v : {};
  } catch { return {}; }
}

async function setup(req, context) {
  if (await passwordRecord()) return fail(409, "There's already a password. Sign in instead.");
  if (!(await allow(`setup/${clientIP(req, context)}`, 8, 900))) return fail(429, "Too many tries. Wait a few minutes.");
  const { code, password } = await body(req);
  if (!env("SETUP_CODE") || !sameSecret(code, env("SETUP_CODE"))) return fail(403, "That setup code isn't right.");
  if (typeof password !== "string" || password.length < 10) return fail(400, "Use at least 10 characters.");
  const rec = hashPassword(password);
  await misc().setJSON("admin/password", rec);
  return json({ ok: true }, 200, { "set-cookie": cookieHeader(session(rec), DAYS * 86400) });
}

async function login(req, context) {
  if (!(await allow(`login/${clientIP(req, context)}`, 8, 900))) return fail(429, "Too many tries. Wait a few minutes.");
  // And from everywhere at once, for guessing spread over many addresses.
  if (!(await allow("login/everyone", 60, 3600))) return fail(429, "Too many tries. Wait a while.");
  const rec = await passwordRecord();
  if (!rec) return fail(409, "Set a password first.");
  const { password } = await body(req);
  if (!checkPassword(password, rec)) return fail(401, "That's not the password.");
  return json({ ok: true }, 200, { "set-cookie": cookieHeader(session(rec), DAYS * 86400) });
}

async function changePassword(req) {
  const rec = await passwordRecord();
  const { current, next } = await body(req);
  if (!checkPassword(current, rec)) return fail(401, "The current password isn't right.");
  if (typeof next !== "string" || next.length < 10) return fail(400, "Use at least 10 characters.");
  const fresh = hashPassword(next);
  await misc().setJSON("admin/password", fresh);
  return json({ ok: true }, 200, { "set-cookie": cookieHeader(session(fresh), DAYS * 86400) });
}

/** What the list shows of an item, and what its search box looks through.
 * (Change SUMMARY when this changes, so the kept summaries are made again.) */
const SUMMARY = 2;
function summary(it) {
  return {
    id: it.id, createdAt: it.createdAt, status: it.status, title: it.title, priority: it.priority,
    tags: it.tags, autoTags: it.autoTags, platform: it.platform,
    version: it.app?.version, build: it.app?.build,
    name: it.name, hasEmail: !!it.email, contactOK: it.contactOK,
    snippet: (it.details ?? "").slice(0, 180),
    search: [it.title, (it.details ?? "").slice(0, 4000), it.name, ...(it.tags ?? [])].join(" ").toLowerCase(),
    files: (it.files ?? []).map((f) => ({ name: f.name, type: f.type, size: f.size, done: f.done })),
  };
}

/** Every item, newest first. Each one's summary is kept (in admin/list) with
 * the etag the item had, so a refresh reads only the items that changed
 * since the last one, and the first after a deploy reads them 50 at a time. */
async function list() {
  const { blobs } = await items().list({ prefix: "items/" });
  const saved = await misc().getWithMetadata("admin/list", { type: "json" });
  const was = saved?.data?.v === SUMMARY ? saved.data.items : {};
  const now = {};
  const changed = [];
  for (const b of blobs) {
    const id = b.key.slice("items/".length);
    if (b.etag && was[id]?.etag === b.etag) now[id] = was[id];
    else changed.push([id, b]);
  }
  for (let i = 0; i < changed.length; i += 50) {
    await Promise.all(changed.slice(i, i + 50).map(async ([id, b]) => {
      const it = await items().get(b.key, { type: "json" });
      if (it) now[id] = { etag: b.etag, item: summary(it) };
    }));
  }
  if (changed.length || Object.keys(now).length !== Object.keys(was).length || !saved) {
    // If another refresh saved it meanwhile, this one's copy is dropped: the
    // next refresh catches up.
    await misc().setJSON("admin/list", { v: SUMMARY, items: now }, saved ? { onlyIfMatch: saved.etag } : { onlyIfNew: true });
  }
  const all = Object.values(now).map((e) => e.item);
  all.sort((a, b) => (a.id < b.id ? 1 : -1));
  return json({ items: all });
}

async function update(req, item) {
  const { status } = await body(req);
  if (!STATUSES.includes(status)) return fail(400, "Unknown status.");
  const [it, stop] = await changeItem(item.id, (it) => {
    // Once the sender's time to send the attachments is over, it can be dealt
    // with like any other: what arrived whole can be looked at (as
    // cleanup.mjs does, which never sees items stuck before it existed),
    // and the rest never will arrive.
    if (it.status === "uploading") {
      if (Date.now() - Date.parse(it.createdAt) <= UPLOAD_WINDOW) return fail(409, "It's still uploading.");
      for (const f of it.files ?? []) if (!f.done && whole(f)) f.done = true;
    }
    it.status = status;
    it.updatedAt = new Date().toISOString();
  });
  return stop ?? json(forAdmin(it));
}

async function remove(item) {
  const { blobs } = await files().list({ prefix: `${item.id}/` });
  await Promise.all(blobs.map((b) => files().delete(b.key)));
  await items().delete(`items/${item.id}`);
  await items().delete(`uploading/${item.id}`);
  return json({ ok: true });
}

/** An attachment, put back together from its pieces. Browsers ask videos
 * for byte ranges (iPhones insist), and no reply may be too big for a
 * function, so a range reply is at most 4 MB and a whole big file streams. */
async function serve(req, item, name) {
  const f = (item.files ?? []).find((x) => x.name === name && x.done);
  if (!f) return fail(404, "No such attachment.");
  const sizes = f.chunks;
  const starts = [];
  let total = 0;
  for (const s of sizes) { starts.push(total); total += s; }
  const url = new URL(req.url);
  // Shown in the page only if it's a picture or a video; never run as a page
  // on this site, whatever it really is.
  const inline = !url.searchParams.has("download") && /^(image|video)\//.test(f.type);
  const headers = {
    "content-type": f.type,
    "accept-ranges": "bytes",
    "cache-control": "private, max-age=3600",
    "content-disposition": `${inline ? "inline" : "attachment"}; filename="${name}"`,
    "x-content-type-options": "nosniff",
    "content-security-policy": "sandbox; default-src 'none'; img-src 'self'; media-src 'self'; style-src 'unsafe-inline'",
  };
  const piece = async (i) => new Uint8Array(await files().get(`${item.id}/${name}/${i}`, { type: "arrayBuffer" }));
  async function bytes(start, end) {
    const out = new Uint8Array(end - start + 1);
    let at = 0;
    for (let i = 0; i < sizes.length; i++) {
      const cs = starts[i], ce = cs + sizes[i] - 1;
      if (ce < start || cs > end) continue;
      const part = (await piece(i)).subarray(Math.max(0, start - cs), Math.min(sizes[i], end - cs + 1));
      out.set(part, at);
      at += part.length;
    }
    return out;
  }

  const range = req.headers.get("range");
  if (range) {
    const r = /^bytes=(\d*)-(\d*)$/.exec(range.trim());
    let start, end;
    if (r && r[1] === "" && r[2] !== "") { start = Math.max(0, total - Number(r[2])); end = total - 1; }
    else if (r && r[1] !== "") { start = Number(r[1]); end = r[2] === "" ? total - 1 : Math.min(Number(r[2]), total - 1); }
    if (start === undefined || start >= total || start > end) {
      return new Response(null, { status: 416, headers: { "content-range": `bytes */${total}` } });
    }
    end = Math.min(end, start + 4 * 1024 * 1024 - 1);
    const b = await bytes(start, end);
    return new Response(b, { status: 206, headers: { ...headers, "content-range": `bytes ${start}-${end}/${total}`, "content-length": String(b.length) } });
  }
  if (total <= 5 * 1024 * 1024) {
    const b = await bytes(0, total - 1);
    return new Response(b, { status: 200, headers: { ...headers, "content-length": String(total) } });
  }
  let i = 0;
  const stream = new ReadableStream({
    async pull(ctrl) {
      if (i >= sizes.length) return ctrl.close();
      ctrl.enqueue(await piece(i++));
    },
  });
  return new Response(stream, { status: 200, headers: { ...headers, "content-length": String(total) } });
}
