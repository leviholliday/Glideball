// The daily download snapshot for the Statistics page (/admin/stats/). GitHub
// only gives running totals of how often each release file was downloaded, so
// the totals are written down once a UTC day and the change per day is the
// difference. One GitHub request, only when today's isn't kept yet.
//
// It runs four times a day (just after 00:00, 06:00, 12:00 and 18:00 UTC), and
// only the first success of a UTC day writes: a GitHub hiccup at midnight is
// retried six hours later instead of leaving a gap. (A scheduled function runs
// only on the published production deploy.)

import { statsStore, takeSnapshot } from "../lib/downloads.mjs";

export const config = { schedule: "5 0,6,12,18 * * *" };

export default async () => {
  const r = await takeSnapshot(statsStore());
  console.log("stats-snapshot", JSON.stringify(r));
};
