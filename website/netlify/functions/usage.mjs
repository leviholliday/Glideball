// Settings stats from the Mac app, only from people who chose "Crash reports
// + anonymous settings stats" (see netlify/lib/usage.mjs for what's kept).
//
//   POST   /api/usage   {installId, version, os, ...}   today's ping (sent again the same day, it replaces it)
//   DELETE /api/usage   {installId}                     everything that install sent ("Delete my data")
//
// The ID arrives raw only to be hashed (see netlify/lib/usage.mjs); it's never kept.

import { env, json, fail, sameSecret, clientIP, allow } from "../lib/common.mjs";
import { usage, readBody, cleanPing, deleteInstall, normalizeID, dayOf, MAX_PING_BYTES } from "../lib/usage.mjs";

export const config = { path: "/api/usage" };

// Whatever goes wrong, the reply never carries the error itself.
export default async (req, context) => {
  try {
    return await route(req, context);
  } catch (e) {
    console.error("usage:", e);
    return fail(500, "Something went wrong.");
  }
};

async function route(req, context) {
  // The same not-a-secret as feedback: it keeps out what just wanders by.
  const key = env("APP_KEY");
  if (key && !sameSecret(req.headers.get("x-glide-key"), key)) return fail(403, "Not from Glideball.");
  if (req.method === "POST") return ping(req, context);
  if (req.method === "DELETE") return forget(req, context);
  return fail(405, "POST stats or DELETE them here.");
}

async function ping(req, context) {
  const ip = clientIP(req, context);
  if (!(await allow(`usage/${ip}`, 30, 3600))) return fail(429, "Too many at once. Try again later.");
  const [b, bad] = await readBody(req, MAX_PING_BYTES);
  if (bad) return fail(bad === "That's too big." ? 413 : 400, bad);
  const [clean, why] = cleanPing(b);
  if (why) return fail(400, why);
  // One a day is all the app sends; a few more leaves room for a retry.
  if (!(await allow(`usage/install/${clean.install}`, 4, 86400))) return fail(429, "Already have today's.");
  if (!(await allow("usage/everyone", 20000, 86400))) return fail(429, "Too many today. Try again tomorrow.");
  await usage().setJSON(`pings/${dayOf(Date.now())}/${clean.install}`, clean.ping);
  return json({ ok: true }, 201);
}

async function forget(req, context) {
  if (!(await allow(`usage-delete/${clientIP(req, context)}`, 20, 3600))) return fail(429, "Too many at once. Try again later.");
  const [b, bad] = await readBody(req, 1024);
  if (bad) return fail(400, bad);
  const id = normalizeID(b.installId);
  if (!id) return fail(400, "No install ID.");
  const deleted = await deleteInstall(id);
  return json({ ok: true, deleted });
}
