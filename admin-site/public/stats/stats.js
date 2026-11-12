// Glide Statistics: the admin page for downloads, feedback counts and site
// health. Signs in through the Feedback page (the same session). Read-only:
// nothing here changes anything, and it shows counts only (no feedback text,
// no IDs, no addresses). Each section has its own error, so one failing never
// blanks the page.
//
// Downloads come from GitHub's counts of the release files; GitHub only gives
// running totals, so the site writes them down every morning (UTC) and each
// day's bar is the difference between two mornings. Until there are two
// mornings the page says "collecting" rather than showing a made-up number.
//
// (The site's CSP allows no inline styles or on*= attributes: bars are SVG
// with plain attributes and colours come from classes. render() is plain
// string-building with everything escaped, so the tests can run it without a
// browser.)

const app = typeof document !== "undefined" ? document.getElementById("app") : null;
const ICON = "/assets/icon-256.png";

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const num = (n) => (Number.isFinite(Number(n)) ? Number(n) : 0).toLocaleString(undefined, { maximumFractionDigits: 1 });
// A bare day ("2026-11-10") is a UTC day, shown as that day everywhere.
const fmtDay = (d) => (/^\d{4}-\d{2}-\d{2}$/.test(String(d)) ? new Date(`${d}T12:00:00Z`).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" }) : "unknown");
const shortDay = (d) => (/^\d{4}-\d{2}-\d{2}$/.test(String(d)) ? new Date(`${d}T12:00:00Z`).toLocaleDateString(undefined, { month: "short", day: "numeric", timeZone: "UTC" }) : "");
const when = (iso) => {
  const t = Date.parse(iso);
  return Number.isFinite(t) ? new Date(t).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }) : "unknown";
};

async function api(path) {
  const r = await fetch(`/api/admin/${path}`, { credentials: "same-origin" });
  let data = null;
  try { data = await r.json(); } catch {}
  if (!r.ok) {
    const e = new Error(data?.error || `Something went wrong (${r.status}).`);
    e.status = r.status;
    throw e;
  }
  return data;
}

// ---------------------------------------------------------------- the page

function shell() {
  app.innerHTML = `
    <header class="top glass">
      <img src="${ICON}" alt="">
      <h1>Statistics</h1>
      <span class="count" id="stamp"></span>
      <span class="spacer"></span>
      <button class="icon-btn" id="refresh">Refresh</button>
      <a class="icon-btn" href="../">Admin</a>
      <a class="icon-btn" href="../usage/">Usage</a>
      <a class="icon-btn" href="../feedback/">Feedback</a>
    </header>
    <main class="stats" id="body"><div class="placeholder">Loading…</div></main>`;
  document.getElementById("refresh").addEventListener("click", load);
}

async function load() {
  try {
    const s = await api("stats");
    document.getElementById("body").innerHTML = render(s);
    document.getElementById("stamp").textContent = `Loaded ${when(s.generatedAt)}`;
  } catch (e) {
    if (e.status === 401) return signedOut();
    document.getElementById("body").innerHTML = `<div class="placeholder">${esc(e.message)}</div>`;
  }
}

function signedOut() {
  app.innerHTML = `
    <div class="gate"><div class="card glass">
      <img src="${ICON}" alt="">
      <h1>Glideball Statistics</h1>
      <p>Sign in on the Feedback page first. It's the same password, and you'll stay signed in here too.</p>
      <a class="primary link-btn" href="../feedback/">Go to sign in</a>
    </div></div>`;
}

// ---------------------------------------------------------------- pieces

const tile = (n, label) => `<div class="tile glass"><b>${num(n)}</b><span>${esc(label)}</span></div>`;
const section = (title, inner) => `<section class="section glass"><h3>${esc(title)}</h3>${inner}</section>`;

/** A section's content, or its own error if its part failed (or can't be drawn). */
function part(title, p, draw) {
  let inner;
  try {
    inner = !p ? `<p class="none">No data.</p>` : p.ok === false ? `<p class="err">${esc(p.error || "Couldn't load this one right now.")}</p>` : draw(p.data);
  } catch (e) {
    console.error(title, e);
    inner = `<p class="err">This section couldn't be drawn.</p>`;
  }
  return section(title, inner);
}

/** Stacked columns, one per entry; `keys` is [{ key, cls, name }] from the bottom up.
 * Entries marked estimated are lighter. */
function stacked(list, keys, labelOf, aria) {
  const total = (x) => keys.reduce((s, k) => s + (Number(x[k.key]) || 0), 0);
  const top = Math.max(...list.map(total), 1);
  const w = 10;
  const cols = list.map((x, i) => {
    let y = 100;
    const rects = keys.map((k) => {
      const v = Number(x[k.key]) || 0;
      if (!v) return "";
      const h = (v / top) * 96;
      y -= h;
      return `<rect x="${i * w + 1}" y="${y.toFixed(2)}" width="${w - 2}" height="${h.toFixed(2)}" class="${k.cls}"></rect>`;
    }).join("");
    const tip = `${labelOf(x)}${x.estimated ? " (spread over days the page has no numbers for)" : ""}: ` + (total(x) ? keys.filter((k) => x[k.key]).map((k) => `${num(x[k.key])} ${k.name.toLowerCase()}`).join(", ") : "none");
    return `<g class="${x.estimated ? "est" : ""}"><rect x="${i * w}" y="0" width="${w}" height="100" class="hit"></rect>${total(x) ? rects : `<rect x="${i * w + 1}" y="99.4" width="${w - 2}" height="0.6" class="zero"></rect>`}<title>${esc(tip)}</title></g>`;
  }).join("");
  const legend = keys.map((k) => `<span class="key"><i class="sw ${k.cls}"></i>${esc(k.name)}</span>`).join("");
  return `<svg class="cols" viewBox="0 0 ${list.length * w} 100" preserveAspectRatio="none" role="img" aria-label="${esc(aria)}">${cols}</svg>
    <div class="axis"><span>${esc(labelOf(list[0]))}</span><span>Most in one: ${num(top)}</span><span>${esc(labelOf(list[list.length - 1]))}</span></div>
    <div class="legend">${legend}</div>`;
}

/** A row of label, bar and number per entry, biggest first. */
function bars(obj, labels = {}) {
  const rows = Object.entries(obj ?? {}).filter(([, n]) => n > 0).sort((a, b) => b[1] - a[1]);
  if (!rows.length) return `<p class="none">None.</p>`;
  const top = Math.max(...rows.map(([, n]) => n), 1);
  return `<div class="bars">${rows.map(([k, n]) => `
    <div class="bar-row">
      <span class="label">${esc(labels[k] ?? k)}</span>
      <svg class="bar" viewBox="0 0 100 10" preserveAspectRatio="none" aria-hidden="true"><rect width="${Math.max(1, (n / top) * 100).toFixed(2)}" height="10" rx="2" class="s-${esc(k)}"></rect></svg>
      <span class="n">${num(n)}</span>
    </div>`).join("")}</div>`;
}

// ---------------------------------------------------------------- downloads

const WHAT = { new: "New downloads", updates: "In-app updates", linux: "Linux preview", windows: "Windows preview", other: "Other files" };

function downloads(d) {
  const t = d.totals ?? {};
  const cols = ["new", "updates", "linux", "windows", ...(t.other || d.releases?.some((r) => r.counts?.other) ? ["other"] : [])];
  const row = (label, note, v, collecting) => `<tr><td>${esc(label)}${note ? `<br><span class="m">${esc(note)}</span>` : ""}</td>${
    v ? cols.map((k) => `<td class="num">${num(v[k])}</td>`).join("") : `<td class="num collecting" colspan="${cols.length}">${esc(collecting)}</td>`}</tr>`;
  const waiting = "collecting: this needs a second morning's numbers";
  const y = d.yesterday, w = d.last7, s = d.sinceSnapshot;
  const changes = `
    <div class="tablewrap"><table class="tbl"><thead><tr><th></th>${cols.map((k) => `<th class="num">${esc(WHAT[k])}</th>`).join("")}</tr></thead><tbody>
      ${row("Since the last snapshot", s ? `since ${when(s.at)}` : "", s?.values, "collecting: the first snapshot hasn't been written yet")}
      ${row("Latest full day", y ? `${fmtDay(y.date)}${y.estimated ? ", spread evenly over a stretch with no numbers" : ""}` : "", y?.values, waiting)}
      ${row(w && w.days < 7 ? `Last ${w.days} day${w.days === 1 ? "" : "s"} so far` : "Last 7 days", w?.estimated ? "partly spread evenly over days with no numbers" : "", w?.values, waiting)}
      ${row("All time", "GitHub's running total", t)}
    </tbody></table></div>`;

  const chart = d.collecting
    ? `<p class="none">Collecting. GitHub only gives running totals, so the site writes them down every morning (UTC), and each day's bar is the difference between two mornings. The first bar appears after the second morning${d.snapshots ? " (one snapshot is kept so far)" : ""}.</p>`
    : stacked(
      d.perDay.map((x) => ({ ...x, previews: (x.linux || 0) + (x.windows || 0) })),
      [{ key: "new", cls: "s-new", name: "New downloads" }, { key: "updates", cls: "s-updates", name: "In-app updates" }, { key: "previews", cls: "s-previews", name: "Linux and Windows previews" }, { key: "other", cls: "s-other", name: "Other" }],
      (x) => fmtDay(x.date), "Downloads per day");

  const rels = d.releases ?? [];
  const releaseTable = rels.length ? `
    <div class="tablewrap"><table class="tbl"><thead><tr><th>Release</th>${cols.map((k) => `<th class="num">${esc(WHAT[k])}</th>`).join("")}</tr></thead><tbody>
      ${rels.map((r) => `<tr><td>${esc(r.name || r.tag)}${r.prerelease ? " (beta)" : ""}<br><span class="m">${esc(r.tag)} · ${esc(r.publishedAt ? fmtDay(String(r.publishedAt).slice(0, 10)) : "unknown date")}</span></td>${cols.map((k) => `<td class="num">${num(r.counts?.[k])}</td>`).join("")}</tr>`).join("")}
    </tbody></table></div>` : `<p class="none">GitHub lists no releases.</p>`;

  return `
    <p class="hint">GitHub's own counts of the release files, as of ${esc(when(d.updatedAt))}${d.stale ? " (GitHub couldn't be reached just now, so this is the last answer the site got)" : ""}. New downloads are Glideball.zip, which is a person getting the app. In-app updates are the app fetching its own update (Glideball-update.zip, and Glide.zip for Glide 2.7.1 and older), so they aren't people.</p>
    <div class="tiles">
      ${tile(d.all, "Downloads in all")}${cols.map((k) => tile(t[k], WHAT[k])).join("")}
    </div>
    <h4>Change over time</h4>${changes}
    <h4>Downloads per day, last 30 days</h4>${chart}
    <h4>By release</h4>${releaseTable}`;
}

// ---------------------------------------------------------------- feedback

const KIND_NAMES = { bug: "Bugs", idea: "Ideas", question: "Questions", other: "Other" };
const KIND_KEYS = [
  { key: "bug", cls: "s-bug", name: "Bugs" }, { key: "idea", cls: "s-idea", name: "Ideas" },
  { key: "question", cls: "s-question", name: "Questions" }, { key: "other", cls: "s-other", name: "Other" },
];

function feedback(f) {
  if (!f.total) return `<p class="hint">Counts only; the messages are on the <a href="../feedback/">Feedback page</a>.</p><p class="none">No feedback yet.</p>`;
  return `
    <p class="hint">Counts only; the messages are on the <a href="../feedback/">Feedback page</a>. Open means not marked done yet. Days and weeks are UTC (weeks start on Monday).</p>
    <div class="tiles">${tile(f.open, "Open now")}${tile(f.total, "In all")}${tile(f.last7Days, "Last 7 days")}${tile(f.last30Days, "Last 30 days")}</div>
    <h4>Open now, by kind</h4>${bars(f.openByKind, KIND_NAMES)}
    <h4>Per day, last 30 days</h4>${stacked(f.days, KIND_KEYS, (x) => fmtDay(x.date), "Feedback per day")}
    <h4>Per week, last 12 weeks</h4>${stacked(f.weeks, KIND_KEYS, (x) => `Week of ${fmtDay(x.week)}`, "Feedback per week")}`;
}

// ------------------------------------------------------------- site health

function health(h) {
  const sn = h.snapshots ?? {}, st = h.storage ?? {}, run = sn.lastRun;
  const links = h.links ?? {};
  const runText = !run ? "Hasn't run yet." : run.ok ? `Worked, ${when(run.at)}.` : `Failed (${run.error || "unknown"}), ${when(run.at)}. ${run.lastOkAt ? `It last worked ${when(run.lastOkAt)}.` : "It has never worked."} It tries again every six hours.`;
  const rows = [
    ["Last snapshot", sn.lastAt ? `${when(sn.lastAt)}${sn.haveToday ? "" : ". Today's isn't in yet."}` : "None yet."],
    ["Snapshots kept", sn.count ? `${num(sn.count)}, since ${fmtDay(sn.first)}` : "None yet."],
    ["Last snapshot run", runText],
    ["Function errors", "The site doesn't count these. The snapshot run above is the only function it checks; Netlify's own page (below) has the logs for all of them."],
  ];
  const stores = (st.stores ?? []).map((s) => `<tr><td>${esc(s.label)}</td><td class="num">${s.count === null ? "couldn't count" : `${s.partial ? "at least " : ""}${num(s.count)}`}</td></tr>`).join("");
  return `
    <dl class="kv one">${rows.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join("")}</dl>
    <h4>What's stored</h4>
    <p class="hint">How many separate records each store holds (counted ${esc(when(st.updatedAt))}, and kept for an hour).</p>
    <div class="tablewrap"><table class="tbl"><thead><tr><th>Store</th><th class="num">Records</th></tr></thead><tbody>${stores}</tbody></table></div>
    <h4>Elsewhere</h4>
    <p class="links">
      <a href="${esc(links.netlify)}" target="_blank" rel="noopener noreferrer">Netlify: deploys, function runs and logs</a>
      <a href="${esc(links.github)}" target="_blank" rel="noopener noreferrer">GitHub: the releases</a>
    </p>`;
}

/** The whole page's content from GET /api/admin/stats. */
function render(s) {
  return `
    <p class="intro">Counts only: nothing here comes from visitors, and nothing lists a person, an ID or an address.</p>
    ${part("Downloads", s.downloads, downloads)}
    ${part("Feedback", s.feedback, feedback)}
    ${part("Site health", s.health, health)}`;
}

if (app) { shell(); load(); }
