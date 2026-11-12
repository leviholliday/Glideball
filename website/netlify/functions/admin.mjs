// The admin side: one password (set once with SETUP_CODE, then changeable),
// a signed cookie, and the feedback itself.
//
// Reached through the admin site (admin-glideball.netlify.app, admin-site/ in
// the repo, docs/ADMIN-SITE.md): its edge function forwards /api/admin/* here
// with x-glide-admin-proxy: ADMIN_PROXY_SECRET and the visitor's address
// (x-glide-client-ip). The data stays on this site because Netlify Blobs
// belong to one site. A wrong proxy secret is refused before a cookie is read.
// Anything else, a script on this site's public pages among it, is refused
// before a cookie is read.
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
//   GET    /api/admin/stats                     the Statistics page: downloads, feedback counts, site health (counts only, read-only)
//   GET    /api/admin/usage?days=90            the Usage page: installs, settings, crashes
//   POST   /api/admin/usage/lookup  {installId} one install's own data, when its owner gives Levi the ID
//   POST   /api/admin/usage/forget  {installId} everything one install sent, likewise (IDs never go in a URL)
//   DELETE /api/admin/usage/range?from&to       everything sent on those days (YYYY-MM-DD, both included)

import crypto from "node:crypto";
import {
  STATUSES, UPLOAD_WINDOW, items, files, misc, env, adminURL, json, fail, sameSecret, randomToken, clientIP, allow, take, giveBack, forAdmin, changeItem, whole,
} from "../lib/common.mjs";
import { feedbackSummaries } from "../lib/summaries.mjs";
import { statsReport } from "../lib/stats.mjs";
import { usageReport, deleteInstall, lookUpInstall, deleteDays, normalizeID, DAY } from "../lib/usage.mjs";

export const config = { path: "/api/admin/*" };

// Only requests through the admin site's proxy get in (the cut-over,
// docs/ADMIN-SITE.md step 2; true would let this site's own pages in again).
export const DIRECT_ACCESS = false;

const PROXY_HEADER = "x-glide-admin-proxy";
const CLIENT_IP_HEADER = "x-glide-client-ip";
const IP_RE = /^[0-9A-Fa-f:.]{2,45}$/;

/** Who may ask, and from which address (for the limits on wrong passwords):
 * { ip } or null (refused). Through the admin site's proxy: its secret,
 * compared in constant time, and the address it saw. A request carrying the
 * proxy header with the wrong secret (or with none set here, or a short one)
 * is refused, never treated as a direct one. Directly (no proxy header): only
 * while `direct`; its own address, and any x-glide-client-ip is ignored. */
export function caller(req, context, direct = DIRECT_ACCESS) {
  const sent = req.headers.get(PROXY_HEADER);
  if (sent !== null) {
    const want = env("ADMIN_PROXY_SECRET");
    if (!want || want.length < 32 || !sameSecret(sent, want)) return null;
    const ip = (req.headers.get(CLIENT_IP_HEADER) ?? "").trim();
    return { ip: IP_RE.test(ip) ? ip : context?.ip };
  }
  return direct ? { ip: context?.ip } : null;
}

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
function readCookie(req, name = COOKIE) {
  const m = (req.headers.get("cookie") ?? "").match(new RegExp(`(?:^|;\\s*)${name}=([^;]+)`));
  return m ? m[1] : null;
}
// A known device: a browser the owner has signed in from. Its cookie lets a
// sign-in from it skip the limit on wrong passwords from everywhere (so
// guesses spread over many addresses can't lock the owner out). It still
// counts against its address's limit, still needs the password, and is
// never a session: signedIn() reads only glide_admin, and the device cookie
// is sent only to /api/admin/login. It's signed with its own label, so it
// can't pass for a session nor a session for it, and tied to the password's
// v, so changing the password forgets every device (but the browser that
// changed it). Every sign-in brings a new one (new nonce, new expiry);
// signing out leaves it. Wrong passwords sent with one have a budget of
// their own, so a stolen one is no way round the limit either.
const DEVICE = "glide_device";
const DEVICE_DAYS = 180;
const DEVICE_WRONG = 10;   // wrong passwords an hour with one device cookie
const signDevice = (p) => sign(`device:${p}`);
function deviceToken(rec) {
  const p = `${Date.now() + DEVICE_DAYS * 86400e3}.${rec.v}.${randomToken(12)}`;
  return `${p}.${signDevice(p)}`;
}
const deviceCookie = (rec) =>
  `${DEVICE}=${deviceToken(rec)}; Path=/api/admin/login; HttpOnly; Secure; SameSite=Strict; Max-Age=${DEVICE_DAYS * 86400}`;
/** The nonce of this request's device cookie, if this site signed it, for
 * the current password, and it hasn't expired; otherwise null. */
function knownDevice(req, rec) {
  const c = readCookie(req, DEVICE);
  if (!c || !rec) return null;
  const parts = c.split(".");
  if (parts.length !== 4) return null;
  const [exp, v, nonce, sig] = parts;
  if (!/^\d{1,16}$/.test(exp) || !v || !/^[A-Za-z0-9_-]{16}$/.test(nonce)) return null;
  if (!sameSecret(sig, signDevice(`${exp}.${v}.${nonce}`))) return null;
  if (Number(exp) <= Date.now() || v !== rec.v) return null;
  return nonce;
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
  // Before anything else: no cookie is read, nothing is counted.
  const client = caller(req, context);
  if (!client) return fail(403, `The admin pages are at ${adminURL()}/`);
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
  if (path === "setup" && m === "POST") return setup(req, client);
  if (path === "login" && m === "POST") return login(req, client);
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
  if (parts[0] === "usage") return usageRoute(req, parts, m);
  if (parts[0] === "stats") return parts.length === 1 && m === "GET" ? json(await statsReport()) : fail(404, "Not here.");
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

/** The Usage page's data, and its two ways of deleting. */
async function usageRoute(req, parts, m) {
  const url = new URL(req.url);
  if (parts.length === 1 && m === "GET") {
    const days = Number(url.searchParams.get("days") ?? 90);
    if (!Number.isInteger(days) || days < 1 || days > 3660) return fail(400, "Pick between 1 and 3660 days.");
    return json(await usageReport(days));
  }
  if ((parts[1] === "lookup" || parts[1] === "forget") && parts.length === 2 && m === "POST") {
    // Only an ID someone gave Levi: nothing on the page lists any.
    const id = normalizeID((await body(req)).installId);
    if (!id) return fail(400, "That isn't a Glideball install ID (GB-, then eight groups of four).");
    if (parts[1] === "lookup") return json(await lookUpInstall(id));
    return json({ ok: true, deleted: await deleteInstall(id) });
  }
  if (parts[1] === "range" && parts.length === 2 && m === "DELETE") {
    const from = url.searchParams.get("from") ?? "", to = url.searchParams.get("to") ?? "";
    const real = (d) => {
      const t = DAY.test(d) ? Date.parse(`${d}T00:00:00Z`) : NaN;
      return Number.isFinite(t) && new Date(t).toISOString().startsWith(d);   // (not 2026-02-30)
    };
    if (!real(from) || !real(to)) return fail(400, "Pick both days.");
    if (from > to) return fail(400, "The first day is after the last.");
    return json({ ok: true, deleted: await deleteDays(from, to) });
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

/** (client: { ip }, from caller().) */
async function setup(req, client) {
  if (await passwordRecord()) return fail(409, "There's already a password. Sign in instead.");
  if (!(await allow(`setup/${clientIP(req, client)}`, 8, 900))) return fail(429, "Too many tries. Wait a few minutes.");
  const { code, password } = await body(req);
  if (!env("SETUP_CODE") || !sameSecret(code, env("SETUP_CODE"))) return fail(403, "That setup code isn't right.");
  if (typeof password !== "string" || password.length < 10) return fail(400, "Use at least 10 characters.");
  const rec = hashPassword(password);
  await misc().setJSON("admin/password", rec);
  return signedInReply(rec);
}

// Wrong passwords: at most 8 every 15 minutes from one address (or IPv6
// /64), and 60 an hour from everywhere at once, for guessing spread over
// many addresses (which a known device skips, with a budget of its own:
// see knownDevice()). Only wrong ones count: each try is counted before the
// password is checked (so tries sent all at once can't slip past the
// limits) and given back if it was right, so signing in never uses up
// either limit, and the many-addresses limit fills only with real guesses.
async function login(req, client) {
  const mine = await take(`login/${clientIP(req, client)}`, 8, 900);
  if (!mine) return fail(429, "Too many tries. Wait a few minutes.");
  const rec = await passwordRecord();
  const device = knownDevice(req, rec);
  // A known device's own budget, or (without one, or once that's used up)
  // the limit for everyone.
  const wide = (device && await take(`login/device/${device}`, DEVICE_WRONG, 3600)) ||
    await take("login/everyone", 60, 3600);
  if (!wide) {
    await giveBack(mine);
    return fail(429, "Too many tries. Wait a while.");
  }
  const notCounted = () => Promise.all([giveBack(mine), giveBack(wide)]);
  if (!rec) {
    await notCounted();
    return fail(409, "Set a password first.");
  }
  const { password } = await body(req);
  if (!checkPassword(password, rec)) return fail(401, "That's not the password.");
  await notCounted();
  return signedInReply(rec);
}

/** Signed in: a session, and a fresh known-device cookie. */
function signedInReply(rec) {
  const headers = new Headers({ "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
  headers.append("set-cookie", cookieHeader(session(rec), DAYS * 86400));
  headers.append("set-cookie", deviceCookie(rec));
  return new Response(JSON.stringify({ ok: true }), { status: 200, headers });
}

async function changePassword(req) {
  const rec = await passwordRecord();
  const { current, next } = await body(req);
  if (!checkPassword(current, rec)) return fail(401, "The current password isn't right.");
  if (typeof next !== "string" || next.length < 10) return fail(400, "Use at least 10 characters.");
  const fresh = hashPassword(next);
  await misc().setJSON("admin/password", fresh);
  return signedInReply(fresh);
}

/** Every item, newest first (lib/summaries.mjs keeps what's shown of each). */
async function list() {
  return json({ items: await feedbackSummaries() });
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
