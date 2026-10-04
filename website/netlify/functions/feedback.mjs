// Feedback from the Glide app and the website's feedback page: the item
// itself, then its attachments a piece at a time, then "that's all" (which
// is when Levi hears of it).
//
//   POST /api/feedback                                  the item (JSON) -> id, upload token
//   PUT  /api/feedback/upload?id&file&index&total       one piece of an attachment
//   POST /api/feedback/complete?id                      every piece is in
//
// (Names go in the query, not the path: a path ending in ".mp4" reads as a
// file to some routers.)

import {
  CHUNK, MAX_CHUNK, TYPES, PRIORITIES, PLATFORMS, UPLOAD_WINDOW,
  items, files, env, json, fail, sha256, sameSecret, randomToken, newID, clientIP, allow, notify, later, changeItem, whole,
} from "../lib/common.mjs";

export const config = { path: ["/api/feedback", "/api/feedback/upload", "/api/feedback/complete"] };

const str = (v, max) => (typeof v === "string" ? v.trim().slice(0, max) : "");
const strList = (v, maxItems, maxLen) =>
  Array.isArray(v)
    ? [...new Set(v.filter((x) => typeof x === "string").map((x) => x.trim().slice(0, maxLen)).filter(Boolean))].slice(0, maxItems)
    : [];
/** A small plain object, or nothing (device details, never anything big). */
const small = (v, maxBytes) => {
  if (!v || typeof v !== "object" || Array.isArray(v)) return {};
  return JSON.stringify(v).length <= maxBytes ? v : {};
};
const safeName = (n) => typeof n === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/.test(n) && !n.includes("..");

// Whatever goes wrong, the reply never carries the error itself (the
// platform's own error reply would include the stack).
export default async (req, context) => {
  try {
    return await route(req, context);
  } catch (e) {
    console.error("feedback:", e);
    return fail(500, "Something went wrong.");
  }
};

async function route(req, context) {
  // Not a secret (it's in the app and in the site's feedback page), but it
  // keeps out what just wanders by.
  const key = env("APP_KEY");
  if (key && !sameSecret(req.headers.get("x-glide-key"), key)) return fail(403, "Not from Glide.");

  const url = new URL(req.url);
  const path = url.pathname.replace(/\/+$/, "");
  if (env("DEBUG_ROUTES")) console.log("route", req.method, path, url.search);
  if (path === "/api/feedback") return req.method === "POST" ? create(req, context) : fail(405, "POST feedback here.");
  const id = url.searchParams.get("id") ?? "";
  if (!/^[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$/.test(id)) return fail(404, "No such feedback.");
  if (path === "/api/feedback/upload") return piece(req, id, url.searchParams.get("file") ?? "");
  if (path === "/api/feedback/complete") return complete(req, id, context);
  return fail(404, "Not here.");
}

async function create(req, context) {
  const ip = clientIP(req, context);
  if (!(await allow(`create/${ip}`, 12, 3600))) return fail(429, "That's a lot of feedback at once. Try again in a while.");
  const text = await req.text();
  if (text.length > 256 * 1024) return fail(413, "That's too long to send.");
  let b;
  try { b = JSON.parse(text); } catch { return fail(400, "That wasn't JSON."); }
  if (!b || typeof b !== "object" || Array.isArray(b)) return fail(400, "That wasn't JSON.");

  const title = str(b.title, 200);
  if (!title) return fail(400, "It needs a title.");
  const email = str(b.email, 200);
  // (Nothing that would mean something else in a mailto: link, like ?bcc=.)
  if (email && !/^[^\s@?&#%/]+@[^\s@?&#%/]+\.[^\s@?&#%/]+$/.test(email)) return fail(400, "That email address doesn't look right.");

  const list = Array.isArray(b.attachments) ? b.attachments : [];
  if (list.length > 6) return fail(400, "That's too many attachments.");
  const meta = [];
  let total = 0;
  for (const a of list) {
    // (Own keys only: "constructor" and the like are in every object.)
    if (!safeName(a?.name) || typeof a.type !== "string" || !Object.hasOwn(TYPES, a.type)) {
      return fail(400, `An attachment can't be sent (${String(a?.name).slice(0, 40)}).`);
    }
    const size = Number(a.size);
    if (!Number.isFinite(size) || size <= 0 || size > TYPES[a.type]) return fail(413, `${a.name} is too big to send.`);
    if (meta.some((f) => f.name === a.name)) return fail(400, "Two attachments have the same name.");
    total += size;
    meta.push({ name: a.name, type: a.type, size, ...(Number(a.duration) > 0 ? { duration: Number(a.duration) } : {}), chunks: [], done: false });
  }
  if (total > 80e6) return fail(413, "The attachments are too big together.");

  const id = newID();
  const uploadToken = randomToken();
  const item = {
    id,
    createdAt: new Date().toISOString(),
    status: meta.length ? "uploading" : "new",
    title,
    details: str(b.details, 20000),
    tags: strList(b.tags, 12, 40),
    autoTags: strList(b.autoTags, 12, 40),
    priority: PRIORITIES.includes(b.priority) ? b.priority : "normal",
    name: str(b.name, 100),
    email,
    contactOK: !!b.contactOK && !!email,
    platform: PLATFORMS.includes(b.platform) ? b.platform : "macos",
    app: small(b.app, 2000),
    system: small(b.system, 8000),
    context: small(b.context, 8000),
    files: meta,
    uploadTokenHash: sha256(uploadToken).toString("hex"),
    ipHash: sha256(`${ip}/${env("SESSION_SECRET") ?? ""}`).toString("hex").slice(0, 16),
  };
  // What the hourly cleanup (cleanup.mjs) looks for, if the rest never comes.
  if (meta.length) await items().setJSON(`uploading/${id}`, {});
  await items().setJSON(`items/${id}`, item);
  if (!meta.length) await later(context, notify(item));
  return json({ id, uploadToken, chunkSize: CHUNK }, 201);
}

async function mine(req, id) {
  const item = await items().get(`items/${id}`, { type: "json" });
  if (!item) return [null, fail(404, "No such feedback.")];
  const tok = req.headers.get("x-upload-token");
  if (!item.uploadTokenHash || !tok || !sameSecret(sha256(tok).toString("hex"), item.uploadTokenHash)) return [null, fail(403, "Not yours to add to.")];
  if (Date.now() - Date.parse(item.createdAt) > UPLOAD_WINDOW) return [null, fail(410, "Too late to add to this one.")];
  return [item, null];
}

async function piece(req, id, name) {
  if (req.method !== "PUT") return fail(405, "PUT pieces here.");
  if (env("DEBUG_ROUTES")) console.log("piece content-length", req.headers.get("content-length"));
  const [item, no] = await mine(req, id);
  if (no) return no;
  if (item.status !== "uploading") return fail(409, "This one's already finished.");
  const f = item.files.find((x) => x.name === name);
  if (!f) return fail(404, "No such attachment.");
  const url = new URL(req.url);
  const index = Number(url.searchParams.get("index"));
  const total = Number(url.searchParams.get("total"));
  // The app and the site cut a file into pieces of CHUNK (the last one
  // whatever's left), so each piece has one right size, and however they're sent (again, or
  // all at once) what's kept is never more than the size the file was sent
  // as, which create() checked against the limits.
  const pieces = Math.max(1, Math.ceil(f.size / CHUNK));
  if (!Number.isInteger(index) || index < 0 || index >= pieces || total !== pieces) return fail(400, "That piece doesn't fit.");
  const body = await req.arrayBuffer();
  if (env("DEBUG_ROUTES")) console.log("piece bytes", body.byteLength, "content-length", req.headers.get("content-length"));
  if (!body.byteLength || body.byteLength > MAX_CHUNK) return fail(413, "That piece is too big.");
  if (body.byteLength !== (index < pieces - 1 ? CHUNK : f.size - index * CHUNK)) return fail(400, `That piece of ${name} isn't the size it should be.`);
  await files().set(`${id}/${name}/${index}`, body);
  // Other pieces may be landing at the same moment, so this one is recorded
  // on the newest copy of the item, and not at all once it's finished.
  const [, stop] = await changeItem(id, (it) => {
    if (it.status !== "uploading") return fail(409, "This one's already finished.");
    const g = it.files.find((x) => x.name === name);
    g.total = total;
    g.chunks[index] = body.byteLength;
  });
  return stop ?? json({ ok: true });
}

async function complete(req, id, context) {
  if (req.method !== "POST") return fail(405, "POST here when it's all in.");
  const item = await items().get(`items/${id}`, { type: "json" });
  if (item && item.status !== "uploading") return json({ ok: true, id });   // already done: fine
  const [, no] = await mine(req, id);
  if (no) {
    // A "complete" sent at the same moment may have finished it meanwhile
    // (and taken its upload token away): that's fine too.
    const now = await items().get(`items/${id}`, { type: "json" });
    return now && now.status !== "uploading" ? json({ ok: true, id }) : no;
  }
  // Written only if no piece (or a second "complete") came in meanwhile, so
  // it's finished, and Levi told, once.
  const [it, stop] = await changeItem(id, (it) => {
    if (it.status !== "uploading") return json({ ok: true, id });
    for (const f of it.files) {
      if (!whole(f)) return fail(409, `${f.name} didn't finish uploading.`);
      f.done = true;
    }
    it.status = "new";
    it.completedAt = new Date().toISOString();
    delete it.uploadTokenHash;
  });
  if (stop) return stop;
  await items().delete(`uploading/${id}`);
  await later(context, notify(it));
  return json({ ok: true, id });
}
