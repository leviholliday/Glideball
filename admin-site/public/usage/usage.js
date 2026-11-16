// Glide Usage: the admin page for the app's opt-in crash reports and
// settings stats. Signs in through the Feedback page (the same session).
// Shows active installs by day and week, what versions, Macs, trackballs and
// settings they use (a breakdown per setting, grouped, with "not reported" for
// installs on an app too old to send it), and crashes grouped by where they
// happened; and deletes everything from a stretch of days.
//
// Nothing here lists or shows install IDs (the server keeps only their
// hashes, and never sends those either). To look at or delete one person's
// data, they give Levi the ID from their app (Settings › Privacy) and he
// pastes it into "One install".
//
// (The site's CSP allows no inline styles or on*= attributes: bars are SVG
// with plain attributes, and every handler is added with addEventListener.)

const app = typeof document !== "undefined" ? document.getElementById("app") : null;
const ICON = "/assets/icon-256.png";
const state = { days: 90, data: null };
try { state.days = Number(localStorage.getItem("usage-days")) || 90; } catch {}

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const fmtDay = (d) => new Date(`${d}T12:00:00Z`).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
const when = (iso) => new Date(iso).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });

async function api(path, { method = "GET", body } = {}) {
  const headers = method !== "GET" ? { "x-glide-admin": "1" } : {};
  if (body !== undefined) headers["content-type"] = "application/json";
  const r = await fetch(`/api/admin/${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), credentials: "same-origin" });
  let data = null;
  try { data = await r.json(); } catch {}
  if (!r.ok) {
    const e = new Error(data?.error || `Something went wrong (${r.status}).`);
    e.status = r.status;
    throw e;
  }
  return data;
}

function toast(text) {
  let t = document.querySelector(".toast");
  if (!t) { t = document.createElement("div"); t.className = "toast"; document.body.append(t); }
  t.textContent = text;
  t.classList.add("on");
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => t.classList.remove("on"), 2400);
}

// ---------------------------------------------------------------- the page

const PERIODS = [[7, "Last 7 days"], [30, "Last 30 days"], [90, "Last 90 days"], [365, "Last year"], [3650, "Everything"]];

function shell() {
  app.innerHTML = `
    <header class="top glass">
      <img src="${ICON}" alt="">
      <h1>Usage</h1>
      <span class="spacer"></span>
      <select class="field small" id="period" aria-label="Period">
        ${PERIODS.map(([d, label]) => `<option value="${d}" ${d === state.days ? "selected" : ""}>${label}</option>`).join("")}
      </select>
      <button class="icon-btn" id="refresh">Refresh</button>
      <a class="icon-btn" href="../">Admin</a>
      <a class="icon-btn" href="../stats/">Statistics</a>
      <a class="icon-btn" href="../feedback/">Feedback</a>
    </header>
    <main class="usage" id="body"><div class="placeholder">Loading…</div></main>`;
  document.getElementById("period").addEventListener("change", (e) => {
    state.days = Number(e.target.value);
    try { localStorage.setItem("usage-days", String(state.days)); } catch {}
    load();
  });
  document.getElementById("refresh").addEventListener("click", () => load(true));
}

async function load(announce) {
  try {
    state.data = await api(`usage?days=${state.days}`);
    render(state.data);
    if (announce) toast("Up to date");
  } catch (e) {
    if (e.status === 401) return signedOut();
    document.getElementById("body").innerHTML = `<div class="placeholder">${esc(e.message)}</div>`;
  }
}

function signedOut() {
  app.innerHTML = `
    <div class="gate"><div class="card glass">
      <img src="${ICON}" alt="">
      <h1>Glideball Usage</h1>
      <p>Sign in on the Feedback page first. It's the same password, and you'll stay signed in here too.</p>
      <a class="primary link-btn" href="../feedback/">Go to sign in</a>
    </div></div>`;
}

// ---------------------------------------------------------------- pieces

/** A row of label, bar and number for each entry, biggest first. */
function bars(obj, total, labels = {}) {
  const rows = Object.entries(obj ?? {}).sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1));
  if (!rows.length) return `<p class="none">Nothing yet.</p>`;
  const top = Math.max(...rows.map(([, n]) => n), 1);
  return `<div class="bars">${rows.map(([k, n]) => `
    <div class="bar-row">
      <span class="label" title="${esc(labels[k] ?? k)}">${esc(labels[k] ?? k)}</span>
      <svg class="bar" viewBox="0 0 100 10" preserveAspectRatio="none" aria-hidden="true"><rect width="${Math.max(1, (n / top) * 100).toFixed(2)}" height="10" rx="2"></rect></svg>
      <span class="n">${n.toLocaleString()}${total ? ` <span class="pct">${Math.round((n / total) * 100)}%</span>` : ""}</span>
    </div>`).join("")}</div>`;
}

/** Columns, one a day (or a week). */
function columns(list, key, labelOf) {
  if (!list.length) return `<p class="none">Nothing yet.</p>`;
  const top = Math.max(...list.map((x) => x[key]), 1);
  const w = 10;
  return `<svg class="cols" viewBox="0 0 ${list.length * w} 100" preserveAspectRatio="none" role="img" aria-label="${esc(key)}">
    ${list.map((x, i) => {
      const h = (x[key] / top) * 96;
      return `<rect x="${i * w + 1}" y="${(100 - h).toFixed(2)}" width="${w - 2}" height="${Math.max(h, 0.6).toFixed(2)}" class="${x[key] ? "" : "zero"}"><title>${esc(labelOf(x))}: ${x[key]}</title></rect>`;
    }).join("")}
  </svg>
  <div class="axis"><span>${esc(labelOf(list[0]))}</span><span>${esc(labelOf(list[list.length - 1]))}</span></div>`;
}

const SCROLL = { native: "Native", flywheel: "Flywheel", follow: "Follow" };
const PERF = { smooth: "Smoothest", efficient: "Efficient", minimal: "Minimal" };
const ACTION = {
  system: "Default", leftClick: "Left click", rightClick: "Right click", middleClick: "Middle click",
  back: "Back", forward: "Forward", shortcut: "Keyboard shortcut", holdShortcut: "Held shortcut",
  modifiedClick: "Modifier-click", disabled: "Do nothing", precisionHold: "Precision (hold)",
  precisionToggle: "Precision (toggle)", ballScrollHold: "Scroll with ball", dragLock: "Drag lock",
  media: "Media key", openApp: "Open an app", gesture: "Gesture",
};
const SPEED = { "<2": "Under 2", "2-4": "2 to 4", "4-8": "4 to 8", "8-16": "8 to 16", "16-32": "16 to 32", "32+": "32 or more" };

// Which settings are in use (sent from 2.10 beta 15 on; website/netlify/lib/usage.mjs,
// SETTINGS, has the same keys and values). Each: [key, label, value labels (in the
// order they're shown; values not listed come after)]. "group.switch" is one switch
// of a group (soundKinds, modesSetUp, used).
const ON_OFF = { on: "On", off: "Off" };
const UNIT = { "<25": "Under 25%", "25-50": "25 to 50%", "50-75": "50 to 75%", "75+": "75% or more" };
const range = (...edges) => {
  const out = { [`<${edges[0]}`]: `Under ${edges[0]}` };
  for (let i = 0; i + 1 < edges.length; i++) out[`${edges[i]}-${edges[i + 1]}`] = `${edges[i]} to ${edges[i + 1]}`;
  out[`${edges.at(-1)}+`] = `${edges.at(-1)} or more`;
  return out;
};
const COUNT = { 0: "None", 1: "1", 2: "2", "2–4": "2 to 4", "3": "3", "4+": "4", "5+": "5 or more" };
const SETTING_GROUPS = [
  ["Look", [
    ["ballColor", "Ball color", { orb: "Orb", ember: "Ember", sunset: "Sunset", ocean: "Ocean", forest: "Forest", graphite: "Graphite", classic: "Classic red", custom: "Custom" }],
    ["appIcon", "App icon", { orb: "Orb", classic: "Classic" }],
    ["light", "Light", { off: "Off", ...UNIT }],
    ["launchStyle", "When Glideball opens", { animation: "Animation", fade: "Quick fade", none: "Nothing" }],
    ["celebrations", "Celebrations", ON_OFF],
    ["weeklyRecap", "Weekly recap", ON_OFF],
  ]],
  ["Sound", [
    ["sounds", "Sounds", ON_OFF],
    ["soundVolume", "Volume", UNIT],
    ["soundKinds.pauseResume", "Pause and resume sounds", ON_OFF],
    ["soundKinds.modes", "Modes on and off sounds", ON_OFF],
    ["soundKinds.ticks", "Slider and switch ticks", ON_OFF],
    ["soundKinds.milestones", "Milestone and record sounds", ON_OFF],
    ["soundKinds.buttons", "Button press sounds (Buttons page)", ON_OFF],
  ]],
  ["Scrolling", [
    ["smoothScrolling", "Smooth scrolling", ON_OFF],
    ["flipDirection", "Flip direction", ON_OFF],
    ["shiftSideways", "Shift scrolls sideways", ON_OFF],
    ["nativeSpeed", "Native: scroll speed", range(0.5, 1, 1.7)],
    ["flyDistance", "Flywheel: slow-turn distance (pt)", range(4, 8, 12)],
    ["flyPower", "Flywheel: spin power", UNIT],
    ["flyReach", "Flywheel: fast-spin reach", UNIT],
    ["flyGlide", "Flywheel: glide", UNIT],
    ["followDistance", "Follow: distance per notch (pt)", range(8, 16, 24)],
    ["followSmoothness", "Follow: softness", UNIT],
    ["followAcceleration", "Follow: spin acceleration", UNIT],
    ["throwOn", "Follow: throw to coast", ON_OFF],
    ["throwDistance", "Follow: throw distance", UNIT],
  ]],
  ["Pointer", [
    ["precisionSpeed", "Precision speed", range(0.5, 1, 1.5)],
    ["perDisplaySpeed", "Per-display speeds", ON_OFF],
    ["ballScrollSpeed", "Scroll with ball speed", range(0.5, 1, 2)],
  ]],
  ["Buttons and gestures", [
    ["gestures", "Gestures", ON_OFF],
    ["gestureButtons", "Gesture buttons and combos", COUNT],
    ["gestureDistance", "Gesture distance", { short: "Short", normal: "Normal", long: "Long" }],
    ["steadyHands", "Steady hands", ON_OFF],
    ["gestureActions", "What gesture directions do (installs using each)", { ...ACTION, none: "No directions set" }],
    ["modesSetUp.precision", "Precision on a button or shortcut", ON_OFF],
    ["modesSetUp.ballScroll", "Scroll with ball on a button or shortcut", ON_OFF],
    ["modesSetUp.dragLock", "Drag lock on a button or shortcut", ON_OFF],
  ]],
  ["App", [
    ["menuBarIcon", "Menu bar icon", ON_OFF],
    ["menuBarStyle", "Menu bar icon style", { mono: "Mono", color: "Color" }],
    ["menuBarOpens", "Menu bar icon opens", { menu: "Menu", panel: "Panel" }],
    ["showInDock", "Show in Dock and app switcher", ON_OFF],
    ["askBeforeQuitting", "Ask before quitting", ON_OFF],
    ["openAtLogin", "Open at login", ON_OFF],
    ["allowScripts", "Allow Raycast and scripts", ON_OFF],
    ["ownLanguage", "A language just for Glideball", ON_OFF],
    ["lowBatteryAlerts", "Low battery alerts", ON_OFF],
    ["sync", "iCloud Drive sync", ON_OFF],
    ["autoBackups", "Automatic backups", ON_OFF],
    ["globalShortcuts", "Global shortcuts set", COUNT],
    ["displays", "Displays", { 1: "1", 2: "2", "3+": "3 or more" }],
    ["windowLayout", "Window layout", { single: "One column", double: "Two columns", roomy: "Two wide columns", triple: "Three columns", unknown: "Never opened" }],
    ["used.search", "Used search", ON_OFF],
    ["used.tryBeforeChange", "Used try before you keep", ON_OFF],
    ["used.share", "Used Share…", ON_OFF],
    ["used.kensingtonWorks", "Imported from KensingtonWorks", ON_OFF],
    ["used.buttonPreset", "Applied a button preset", ON_OFF],
  ]],
];

/** One setting: a bar per value (in the labels' order), with how many installs and what
 * share of the period's installs, then the installs that didn't send it. */
function settingBars(s, n, labels) {
  if (!s) return `<p class="none">Nothing yet.</p>`;
  const order = Object.keys(labels);
  const rows = Object.entries(s.counts).sort((a, b) => {
    const ia = order.indexOf(a[0]), ib = order.indexOf(b[0]);
    return (ia < 0 ? 1e3 : ia) - (ib < 0 ? 1e3 : ib) || b[1] - a[1];
  }).map(([k, c]) => [labels[k] ?? k, c, ""]);
  if (s.notReported) rows.push(["Not reported", s.notReported, "nr"]);
  if (!rows.length) return `<p class="none">Nothing yet.</p>`;
  return `<div class="bars">${rows.map(([label, c, cls]) => `
    <div class="bar-row ${cls}">
      <span class="label" title="${esc(label)}">${esc(label)}</span>
      <svg class="bar" viewBox="0 0 100 10" preserveAspectRatio="none" aria-hidden="true"><rect width="${Math.max(1, (c / Math.max(n, 1)) * 100).toFixed(2)}" height="10" rx="2"></rect></svg>
      <span class="n">${c.toLocaleString()} <span class="pct">${n ? Math.round((c / n) * 100) : 0}%</span></span>
    </div>`).join("")}</div>`;
}

/** The settings, a section per group. */
function settingsSections(settings, n) {
  const any = SETTING_GROUPS.some(([, list]) => list.some(([k]) => settings?.[k] && Object.keys(settings[k].counts).length));
  const note = any ? "" : `<p class="none">No install in this period has sent these yet (they come from 2.10 beta 15 on).</p>`;
  return `
    <h2 class="group-title">Settings in use</h2>
    <p class="hint">Each install's most recent day in this period. A bar is the share of all ${n.toLocaleString()} install${n === 1 ? "" : "s"}; "Not reported" are installs on an older Glideball that doesn't send that setting. Ranges are what the app sends, never exact values.</p>
    ${note}
    ${SETTING_GROUPS.map(([title, list]) => section(title, `<div class="settings">${list.map(([k, label, labels]) => `
      <div class="setting"><h4>${esc(label)}</h4>${settingBars(settings?.[k], n, labels)}</div>`).join("")}</div>`)).join("")}`;
}

/** One install's settings, in words (for "One install"). */
function settingRows(p) {
  const rows = [];
  for (const [, list] of SETTING_GROUPS) {
    for (const [k, label, labels] of list) {
      const [key, flag] = k.split(".");
      let v = flag ? p[key]?.[flag] : p[key];
      if (v === undefined) continue;
      if (typeof v === "boolean") v = v ? "on" : "off";
      if (typeof v === "object") v = Object.entries(v).map(([kind, c]) => `${ACTION[kind] ?? kind} ${c}`).join(", ") || "none";
      rows.push([label, labels[v] ?? String(v)]);
    }
  }
  return rows;
}

function section(title, inner, cls = "") {
  return `<section class="section glass ${cls}"><h3>${esc(title)}</h3>${inner}</section>`;
}

function render(d) {
  document.getElementById("body").innerHTML = page(d);
  document.getElementById("one").addEventListener("submit", lookUp);
  document.getElementById("one-delete").addEventListener("click", deleteInstall);
  document.getElementById("range").addEventListener("submit", deleteRange);
}

/** The page's content from GET /api/admin/usage: plain string-building with everything
 * escaped, so the tests can run it without a browser. */
function page(d) {
  const b = d.breakdowns;
  const n = d.totals.installs;
  const thisWeek = d.perWeek.length ? d.perWeek[d.perWeek.length - 1].active : 0;
  const today = d.perDay.length ? d.perDay[d.perDay.length - 1].active : 0;
  const buttonRows = Object.entries(b.buttons).sort((x, y) => y[1].installs - x[1].installs);

  return `
    <p class="intro">From people who chose to share. ${esc(fmtDay(d.since))} to ${esc(fmtDay(d.today))} (UTC). Settings are each install's most recent day in this period.</p>
    <div class="tiles">
      <div class="tile glass"><b>${n.toLocaleString()}</b><span>Installs in this period</span></div>
      <div class="tile glass"><b>${today.toLocaleString()}</b><span>Today</span></div>
      <div class="tile glass"><b>${thisWeek.toLocaleString()}</b><span>This week</span></div>
      <div class="tile glass"><b>${d.totals.crashes.toLocaleString()}</b><span>Crashes in this period</span></div>
      <div class="tile glass"><b>${d.totals.everSeen.toLocaleString()}</b><span>Installs ever</span></div>
    </div>
    ${section("Active installs by day", columns(d.perDay, "active", (x) => fmtDay(x.day)))}
    ${section("Active installs by week", columns(d.perWeek, "active", (x) => `Week of ${fmtDay(x.week)}`))}
    ${section("New installs by day", columns(d.perDay, "new", (x) => fmtDay(x.day)))}
    <div class="grid">
      ${section("Version", bars(b.version, n))}
      ${section("macOS", bars(b.os, n))}
      ${section("Trackballs", bars(b.trackball))}
      ${section("Language", bars(b.lang, n))}
      ${section("Chip", bars(b.arch, n, { arm64: "Apple silicon", x86_64: "Intel" }))}
      ${section("Scroll mode", bars(b.scrollMode, n, SCROLL))}
      ${section("Pointer speed", bars(b.pointerSpeed, n, SPEED))}
      ${section("Performance", bars(b.performance, n, PERF))}
      ${section("Other Kensington trackballs", bars(b.beta, n))}
      ${section("Early updates", bars(b.earlyUpdates ?? {}, n))}
      ${section("App setups", bars(b.appProfiles, n))}
      ${section("Button combos", bars(b.combos, n))}
      ${section("What buttons are set to", buttonRows.length ? `
        <table class="tbl"><thead><tr><th>Action</th><th>Installs</th><th>Buttons</th></tr></thead><tbody>
          ${buttonRows.map(([k, v]) => `<tr><td>${esc(ACTION[k] ?? k)}</td><td>${v.installs}</td><td>${v.buttons}</td></tr>`).join("")}
        </tbody></table>` : `<p class="none">Nothing yet.</p>`)}
    </div>
    ${settingsSections(d.settings ?? {}, n)}
    ${section(`Crashes (${d.crashes.length} kind${d.crashes.length === 1 ? "" : "s"})`, crashList(d.crashes))}
    ${section("One install", `
      <p class="hint">If someone asks to see or delete their data, they can copy their install ID from Settings › Privacy in the app and send it to you. Paste it here. Nothing on this page lists IDs.</p>
      <form class="range" id="one">
        <label class="grow">Install ID <input class="field small mono" id="one-id" autocomplete="off" spellcheck="false" placeholder="GB-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX" required></label>
        <button class="btn" type="submit">Look up</button>
        <button class="btn danger" type="button" id="one-delete">Delete everything from it…</button>
      </form>
      <div id="one-result"></div>`)}
    ${section("Delete a period", `
      <p class="hint">Deletes every stats day and crash report from these days (UTC, both included), from every install. It can't be undone.</p>
      <form class="range" id="range">
        <label>From <input class="field small" type="date" id="from" required></label>
        <label>To <input class="field small" type="date" id="to" required></label>
        <button class="btn danger" type="submit">Delete these days…</button>
      </form>`)}`;
}

function crashList(list) {
  if (!list.length) return `<p class="none">No crashes in this period.</p>`;
  return list.map((c) => {
    const s = c.sample ?? {};
    const frames = (s.frames ?? []).map((f, i) =>
      `${String(i).padEnd(3)} ${f.image.padEnd(22)} ${f.symbol ? f.symbol : `+${f.offset}`}`).join("\n");
    return `
      <details class="crash">
        <summary>
          <span class="t">${esc(c.title)}</span>
          <span class="m">${c.count} time${c.count === 1 ? "" : "s"} · ${c.installs} install${c.installs === 1 ? "" : "s"} · last ${esc(when(c.lastAt))}</span>
        </summary>
        <dl class="kv">
          <dt>Versions</dt><dd>${esc(Object.entries(c.versions).map(([v, k]) => `${v} (${k})`).join(", "))}</dd>
          <dt>macOS</dt><dd>${esc(Object.entries(c.os).map(([v, k]) => `${v} (${k})`).join(", "))}</dd>
          <dt>First seen</dt><dd>${esc(when(c.firstAt))}</dd>
          <dt>Signature</dt><dd><code>${esc(c.signature)}</code></dd>
          ${s.termination ? `<dt>Ended by</dt><dd>${esc(s.termination)}</dd>` : ""}
          ${s.reason ? `<dt>Message</dt><dd>${esc(s.reason)}</dd>` : ""}
        </dl>
        <p class="hint">The newest one (${esc(s.version ?? "")}, macOS ${esc(s.os ?? "")}, ${esc(s.arch ?? "")}), the thread that crashed:</p>
        <pre class="frames">${esc(frames)}</pre>
      </details>`;
  }).join("");
}

/** What one install sent (from an ID its owner gave), shown under the box. */
function showInstall(r) {
  const out = document.getElementById("one-result");
  if (!r.found) { out.innerHTML = `<p class="none">Nothing from that ID. It may have been deleted, or never sent anything.</p>`; return; }
  const p = r.latest;
  const rows = p ? [
    ["Days sent", `${r.days.length} (${fmtDay(r.days[0])} to ${fmtDay(r.days.at(-1))})`],
    ["Version", `${p.version} (build ${p.build})`], ["macOS", p.os], ["Language", p.lang], ["Chip", p.arch],
    ["Trackballs", p.trackballs.map((t) => t.name).join(", ") || "None connected"],
    ["Scroll mode", SCROLL[p.scrollMode] ?? p.scrollMode], ["Pointer speed", SPEED[p.pointerSpeed] ?? p.pointerSpeed],
    ["Performance", PERF[p.performance] ?? p.performance], ["Other Kensington trackballs", p.beta ? "On" : "Off"], ["Early updates", p.earlyUpdates ? "On" : "Off"],
    ["App setups", p.appProfiles], ["Combos", p.combos],
    ["Buttons", Object.entries(p.buttons).map(([k, v]) => `${ACTION[k] ?? k} ${v}`).join(", ") || "None changed"],
    ...settingRows(p),
  ] : [["Days sent", "None (crash reports only)"]];
  out.innerHTML = `
    <dl class="kv one">${rows.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join("")}
      <dt>Crashes</dt><dd>${r.crashCount}</dd></dl>
    ${r.crashes.map((c) => `<p class="hint">${esc(when(c.at))}: ${esc(c.title)} (${esc(c.version)}, macOS ${esc(c.os)})</p>`).join("")}`;
}

// ---------------------------------------------------------------- deleting

const pastedID = () => document.getElementById("one-id").value.trim();

async function lookUp(ev) {
  ev.preventDefault();
  try {
    showInstall(await api("usage/lookup", { method: "POST", body: { installId: pastedID() } }));
  } catch (e) {
    if (e.status === 401) return signedOut();
    toast(e.message);
  }
}

async function deleteInstall() {
  if (!pastedID()) return toast("Paste the install ID first.");
  if (!confirm("Delete everything this install has sent (every stats day and crash report)? This can't be undone.")) return;
  try {
    const r = await api("usage/forget", { method: "POST", body: { installId: pastedID() } });
    toast(`Deleted ${r.deleted} record${r.deleted === 1 ? "" : "s"}`);
    load();
  } catch (e) {
    if (e.status === 401) return signedOut();
    toast(e.message);
  }
}

async function deleteRange(ev) {
  ev.preventDefault();
  const from = document.getElementById("from").value, to = document.getElementById("to").value;
  if (!from || !to) return toast("Pick both days.");
  if (from > to) return toast("The first day is after the last.");
  const span = from === to ? fmtDay(from) : `${fmtDay(from)} to ${fmtDay(to)}`;
  if (!confirm(`Delete every stats day and crash report from ${span} (UTC), from every install? This can't be undone.`)) return;
  try {
    const r = await api(`usage/range?from=${from}&to=${to}`, { method: "DELETE" });
    toast(`Deleted ${r.deleted} record${r.deleted === 1 ? "" : "s"}`);
    load();
  } catch (e) {
    if (e.status === 401) return signedOut();
    toast(e.message);
  }
}

if (app) { shell(); load(); }
