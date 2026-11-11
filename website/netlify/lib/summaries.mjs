// What the Feedback page lists of each item, kept so a refresh reads only what
// changed. The Feedback page (admin.mjs, GET /api/admin/feedback) and the
// Statistics page (stats.mjs, which counts them) both read it from here.

import { items, misc } from "./common.mjs";

/** What the list shows of an item, and what its search box looks through.
 * (Change SUMMARY when this changes, so the kept summaries are made again.) */
export const SUMMARY = 2;
export function summary(it) {
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

/** Every item's summary, newest first. Each one's summary is kept (in admin/list) with
 * the etag the item had, so a refresh reads only the items that changed
 * since the last one, and the first after a deploy reads them 50 at a time. */
export async function feedbackSummaries() {
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
  return all;
}
