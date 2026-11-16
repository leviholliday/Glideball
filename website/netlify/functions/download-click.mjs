// A click on one of the website's download links (app.js sends it as the
// download starts). Counted a day at a time by file, nothing else: no cookie is
// read or set, there's no ID, and no address is kept (lib/downloads.mjs,
// countClick). The Statistics page shows the counts next to GitHub's.
//
//   POST /api/download-click   {"asset": "mac" | "mac-auto" | "linux" | "linux-deb" | "windows" | "windows-arm"}
//
// Whatever happens, the page doesn't wait for it or show anything.

import { json, fail, clientIP, allow } from "../lib/common.mjs";
import { statsStore, countClick, CLICK_ASSETS } from "../lib/downloads.mjs";

export const config = { path: "/api/download-click" };

const MAX_BYTES = 200;

export default async (req, context) => {
  try {
    return await route(req, context);
  } catch (e) {
    console.error("download-click:", e);
    return fail(500, "Something went wrong.");
  }
};

async function route(req, context) {
  if (req.method !== "POST") return fail(405, "POST a click here.");
  // Only this site's own pages (a browser always says where a POST comes from;
  // a script can leave it out, which the limits below are for).
  const origin = req.headers.get("origin");
  if (origin !== null && origin !== new URL(req.url).origin) return fail(403, "Not from this site.");
  const text = await req.text();
  if (text.length > MAX_BYTES) return fail(413, "That's too big.");
  let asset;
  try { asset = JSON.parse(text)?.asset; } catch { return fail(400, "That wasn't JSON."); }
  if (!CLICK_ASSETS.includes(asset)) return fail(400, "Unknown download.");
  // A person clicks a few times at most; a page left open and reloaded, a few more.
  if (!(await allow(`click/${clientIP(req, context)}`, 10, 3600))) return fail(429, "That's plenty for now.");
  if (!(await allow("click/everyone", 5000, 86400))) return fail(429, "Too many today.");
  if (!(await countClick(statsStore(), asset))) return fail(503, "Busy. It didn't count.");
  return json({ ok: true }, 201);
}
