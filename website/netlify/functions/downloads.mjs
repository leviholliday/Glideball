// How many times Glideball has been downloaded: every file of every GitHub
// release (Mac, Linux and Windows), except the two zips only the app fetches
// when it updates itself, so the number is people and not updates. The page shows the
// number only once it's worth showing — below SHOW_FROM this answers null, so
// the count stays private until then. Cached at Netlify's edge for an hour,
// which keeps well inside GitHub's API limits.

const REPO = "leviholliday/glideball";
const SHOW_FROM = 200;
// Fetched by the app, not by people: Glideball-update.zip is what the in-app
// updater downloads, Glide.zip is what Glide 2.7.1 and older update from.
const NOT_COUNTED = new Set(["Glideball-update.zip", "Glide.zip"]);

export const config = { path: "/api/downloads" };

async function totalDownloads() {
  let total = 0;
  for (let page = 1; page <= 10; page++) {
    const res = await fetch(`https://api.github.com/repos/${REPO}/releases?per_page=100&page=${page}`, {
      headers: { accept: "application/vnd.github+json", "user-agent": "glideball-website" },
    });
    if (!res.ok) throw new Error(`GitHub answered ${res.status}`);
    const releases = await res.json();
    for (const r of releases) {
      for (const a of r.assets ?? []) {
        if (!NOT_COUNTED.has(a.name)) total += a.download_count ?? 0;
      }
    }
    if (releases.length < 100) break;
  }
  return total;
}

export default async () => {
  try {
    const total = await totalDownloads();
    return Response.json({ downloads: total >= SHOW_FROM ? total : null }, {
      headers: {
        "cache-control": "public, max-age=300",
        "netlify-cdn-cache-control": "public, durable, s-maxage=3600, stale-while-revalidate=86400",
      },
    });
  } catch {
    // Not worth an error on the page: it just doesn't show a number.
    return Response.json({ downloads: null }, { headers: { "cache-control": "no-store" } });
  }
};
