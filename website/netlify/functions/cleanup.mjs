// Every hour: feedback whose attachments never all came (the app quit, the
// page was closed, the connection dropped, a piece was refused). Once the
// sender's time to send them is over, the ones that did arrive are kept,
// the pieces of the rest are deleted, and the item goes to the inbox with a
// notification, so what was said still reaches Levi.

import { UPLOAD_WINDOW, items, files, misc, changeItem, whole, notify } from "../lib/common.mjs";

export const config = { schedule: "@hourly" };

/** When an id was made: 20260929-231502-a1b2c3d4. */
function madeAt(id) {
  const m = /^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})-/.exec(id);
  return m ? Date.UTC(m[1], m[2] - 1, m[3], m[4], m[5], m[6]) : NaN;
}

export default async () => {
  const { blobs } = await items().list({ prefix: "uploading/" });
  for (const { key } of blobs) {
    const id = key.slice("uploading/".length);
    if (!(Date.now() - madeAt(id) > UPLOAD_WINDOW)) continue;
    let gaveUp = false;
    const lost = [];
    const [item, stop] = await changeItem(id, (it) => {
      gaveUp = it.status === "uploading";
      lost.length = 0;
      for (const f of it.files ?? []) {
        if (f.done) continue;
        if (whole(f)) f.done = true;
        else lost.push(f.name);
      }
      if (gaveUp) it.status = "new";
      delete it.uploadTokenHash;
    });
    if (stop && stop.status !== 404) continue;   // busy: next hour (404: deleted, pieces and all)
    for (const name of lost) {
      const { blobs: pieces } = await files().list({ prefix: `${id}/${name}/` });
      await Promise.all(pieces.map((b) => files().delete(b.key)));
    }
    await items().delete(key);
    if (item && gaveUp) await notify(item);
  }

  // Rate counters from before there was one per key (rate/<key>/<window>): long over.
  const { blobs: old } = await misc().list({ prefix: "rate/" });
  await Promise.all(old.filter((b) => b.key.split("/").length > 2).map((b) => misc().delete(b.key)));
};
