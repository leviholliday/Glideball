// Every hour: feedback whose attachments never all came (the app quit, the
// page was closed, the connection dropped, a piece was refused). Once the
// sender's time to send them is over, the ones that did arrive are kept,
// the pieces of the rest are deleted, and the item goes to the inbox with a
// notification, so what was said still reaches Levi. Also: rate counters
// whose time is over go, and feedback that came in past the push budget
// gets one push saying how much.

import { UPLOAD_WINDOW, items, files, misc, changeItem, whole, notify, pushDigest, rateExpired } from "../lib/common.mjs";

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

  // Rate counters whose window is over (their names say when it ends), and
  // the older kinds that never ended.
  const { blobs: rates } = await misc().list({ prefix: "rate/" });
  const over = rates.filter((b) => rateExpired(b.key));
  for (let i = 0; i < over.length; i += 50) {
    await Promise.all(over.slice(i, i + 50).map((b) => misc().delete(b.key)));
  }

  // Feedback that came in past the hour's push budget: one push for all of it.
  await pushDigest();
};
