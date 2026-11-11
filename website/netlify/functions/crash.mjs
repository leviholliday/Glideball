// Crash reports from the Mac app, only from people who chose to send them
// (see netlify/lib/usage.mjs for what's kept). The app reads macOS's own
// report of the crash on its next launch and sends a small part of it: the
// kind of crash and the stack of the thread that crashed, with nothing that
// could name a person or their files.
//
//   POST /api/crash   {installId, crashedAt, version, os, exception, frames, ...}

import { env, json, fail, sameSecret, clientIP, allow } from "../lib/common.mjs";
import { usage, readBody, cleanCrash, crashKey, MAX_CRASH_BYTES } from "../lib/usage.mjs";

export const config = { path: "/api/crash" };

export default async (req, context) => {
  try {
    return await route(req, context);
  } catch (e) {
    console.error("crash:", e);
    return fail(500, "Something went wrong.");
  }
};

async function route(req, context) {
  const key = env("APP_KEY");
  if (key && !sameSecret(req.headers.get("x-glide-key"), key)) return fail(403, "Not from Glideball.");
  if (req.method !== "POST") return fail(405, "POST crash reports here.");
  if (!(await allow(`crash/${clientIP(req, context)}`, 20, 3600))) return fail(429, "Too many at once. Try again later.");
  const [b, bad] = await readBody(req, MAX_CRASH_BYTES);
  if (bad) return fail(bad === "That's too big." ? 413 : 400, bad);
  const [clean, why] = cleanCrash(b);
  if (why) return fail(400, why);
  // A Mac that crashes over and over doesn't need to say so more than this.
  if (!(await allow(`crash/install/${clean.install}`, 10, 86400))) return fail(429, "That's enough for today.");
  if (!(await allow("crash/everyone", 500, 86400))) return fail(429, "Too many today. Try again tomorrow.");
  await usage().setJSON(crashKey(clean.crash.signature, clean.install), clean.crash);
  return json({ ok: true }, 201);
}
