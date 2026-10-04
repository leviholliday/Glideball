// Glide Feedback: the admin page. Sign in (or set the password once), then
// the feedback (from the Mac app and the site's /feedback/ page), newest
// first, with its details, attachments and the Mac it came from. ?id=...
// (the ntfy notification's link) opens one.

const app = document.getElementById("app");
const state = {
  items: [],
  filter: { status: "inbox", q: "", priority: "", tag: "", platform: "" },
  selected: new URLSearchParams(location.search).get("id"),
  detail: null,
};

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const cap = (s) => (s ? s[0].toUpperCase() + s.slice(1) : "");
const PLATFORM = { macos: "Mac", web: "Website" };
const ICON = "/assets/icon-256.png";
const PRIORITY_ORDER = ["blocking", "high", "normal", "low"];

async function api(path, { method = "GET", body } = {}) {
  const headers = {};
  if (body !== undefined) headers["content-type"] = "application/json";
  if (method !== "GET") headers["x-glide-admin"] = "1";
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
  toast.timer = setTimeout(() => t.classList.remove("on"), 2200);
}

function ago(iso) {
  const s = (Date.now() - Date.parse(iso)) / 1000;
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
  if (s < 7 * 86400) return `${Math.floor(s / 86400)} d ago`;
  return new Date(iso).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
}
const when = (iso) => new Date(iso).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
/** Attachments still coming in, or (six hours on, when the server stops
 * taking them: UPLOAD_WINDOW in netlify/lib/common.mjs) given up on. */
const unfinished = (i) => (Date.now() - Date.parse(i.createdAt) < 6 * 3600e3 ? "still uploading" : "attachments didn't finish");
const size = (n) => (n > 1e6 ? `${(n / 1e6).toFixed(1)} MB` : `${Math.max(1, Math.round(n / 1e3))} KB`);

// ---------------------------------------------------------------- sign in

async function start() {
  try {
    const s = await api("session");
    if (s.loggedIn) return main();
    return s.needsSetup ? gate(true) : gate(false);
  } catch (e) {
    app.innerHTML = `<div class="gate"><div class="card glass"><img src="${ICON}" alt=""><h1>Can't reach the server</h1><p>${esc(e.message)}</p></div></div>`;
  }
}

function gate(setup) {
  // Signed out: no more refreshing (which would redraw this, half-typed
  // password and all) or back/forward to items.
  clearInterval(poll);
  window.onpopstate = null;
  app.innerHTML = `
    <div class="gate"><div class="card glass">
      <img src="${ICON}" alt="">
      <h1>Glide Feedback</h1>
      <p>${setup ? "Choose the password for this page. You'll need the setup code once." : "Sign in to read what people have sent."}</p>
      <form id="gate">
        ${setup ? `<label for="code">Setup code</label><input class="field" id="code" autocomplete="one-time-code" required>` : ""}
        <label for="pw">${setup ? "New password (10 or more characters)" : "Password"}</label>
        <input class="field" id="pw" type="password" autocomplete="${setup ? "new-password" : "current-password"}" required minlength="${setup ? 10 : 1}" autofocus>
        ${setup ? `<label for="pw2">The same again</label><input class="field" id="pw2" type="password" autocomplete="new-password" required>` : ""}
        <button class="primary" type="submit">${setup ? "Set password" : "Sign in"}</button>
        <p class="error" id="err"></p>
      </form>
    </div></div>`;
  const form = document.getElementById("gate");
  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const err = document.getElementById("err");
    const btn = form.querySelector("button");
    const pw = document.getElementById("pw").value;
    err.textContent = "";
    if (setup && pw !== document.getElementById("pw2").value) { err.textContent = "The two passwords don't match."; return; }
    btn.disabled = true;
    try {
      if (setup) await api("setup", { method: "POST", body: { code: document.getElementById("code").value.trim(), password: pw } });
      else await api("login", { method: "POST", body: { password: pw } });
      main();
    } catch (e) {
      err.textContent = e.message;
      btn.disabled = false;
    }
  });
}

// ---------------------------------------------------------------- the page

let poll;

async function main() {
  app.innerHTML = `
    <header class="top glass">
      <img src="${ICON}" alt="">
      <h1>Feedback</h1>
      <span class="count" id="count"></span>
      <span class="spacer"></span>
      <button class="icon-btn" id="refresh" title="Refresh">Refresh</button>
      <div class="menu" id="menu">
        <button class="icon-btn" id="menu-btn" aria-haspopup="true" aria-label="More">•••</button>
        <div class="menu-list glass">
          <button id="change-pw">Change password…</button>
          <button id="sign-out">Sign out</button>
        </div>
      </div>
    </header>
    <div class="shell" id="shell">
      <section class="list-pane">
        <div class="filters">
          <div class="seg" id="status">
            <button data-s="inbox">Inbox</button><button data-s="done">Done</button><button data-s="all">All</button>
          </div>
          <input class="field small" id="q" type="search" placeholder="Search titles, details, names, tags">
          <div class="row">
            <select class="field small" id="f-priority"><option value="">Priority</option>${PRIORITY_ORDER.map((p) => `<option value="${p}">${cap(p)}</option>`).join("")}</select>
            <select class="field small" id="f-tag"><option value="">Tag</option></select>
            <select class="field small" id="f-platform"><option value="">Source</option><option value="macos">Mac app</option><option value="web">Website</option></select>
          </div>
        </div>
        <div class="list" id="list"></div>
      </section>
      <section class="detail" id="detail"><div class="placeholder">Pick something from the list.</div></section>
    </div>`;

  document.getElementById("refresh").onclick = () => load(true);
  const menu = document.getElementById("menu");
  document.getElementById("menu-btn").onclick = (e) => { e.stopPropagation(); menu.classList.toggle("open"); };
  document.onclick = () => menu.classList.remove("open");
  document.getElementById("sign-out").onclick = async () => { await api("logout", { method: "POST" }).catch(() => {}); gate(false); };
  document.getElementById("change-pw").onclick = changePassword;
  document.getElementById("status").onclick = (e) => {
    const s = e.target.dataset?.s;
    if (s) { state.filter.status = s; renderList(); }
  };
  document.getElementById("q").oninput = (e) => { state.filter.q = e.target.value.toLowerCase(); renderList(); };
  for (const k of ["priority", "tag", "platform"]) {
    document.getElementById(`f-${k}`).onchange = (e) => { state.filter[k] = e.target.value; renderList(); };
  }
  window.onpopstate = () => {
    state.selected = new URLSearchParams(location.search).get("id");
    state.selected ? openItem(state.selected, false) : closeItem(false);
  };
  await load();
  if (!document.getElementById("list")) return;   // signed out meanwhile
  if (state.selected) openItem(state.selected, false);
  clearInterval(poll);
  poll = setInterval(() => { if (document.visibilityState === "visible" && document.getElementById("list")) load(); }, 60000);
}

async function load(announce) {
  try {
    const { items } = await api("feedback");
    state.items = items;
    const tags = [...new Set(items.flatMap((i) => i.tags ?? []))].sort();
    const sel = document.getElementById("f-tag");
    const cur = sel.value;
    sel.innerHTML = `<option value="">Tag</option>` + tags.map((t) => `<option ${t === cur ? "selected" : ""}>${esc(t)}</option>`).join("");
    renderList();
    if (announce) toast("Up to date");
  } catch (e) {
    if (e.status === 401) return gate(false);
    toast(e.message);
  }
}

function visible() {
  const f = state.filter;
  return state.items.filter((i) => {
    if (f.status === "inbox" && i.status === "done") return false;
    if (f.status === "done" && i.status !== "done") return false;
    if (f.priority && i.priority !== f.priority) return false;
    if (f.tag && !(i.tags ?? []).includes(f.tag)) return false;
    if (f.platform && i.platform !== f.platform) return false;
    if (f.q && !(i.search ?? `${i.title} ${i.snippet} ${i.name}`.toLowerCase()).includes(f.q)) return false;
    return true;
  });
}

function renderList() {
  for (const b of document.querySelectorAll("#status button")) b.classList.toggle("on", b.dataset.s === state.filter.status);
  const fresh = state.items.filter((i) => i.status === "new").length;
  document.getElementById("count").textContent = fresh ? `${fresh} new` : "";
  const list = visible();
  const el = document.getElementById("list");
  if (!list.length) {
    el.innerHTML = `<div class="empty">${state.items.length ? "Nothing matches." : "No feedback yet. It'll show up here (and on your phone) when it arrives."}</div>`;
    return;
  }
  el.innerHTML = list.map((i) => `
    <button class="item ${i.status === "new" ? "new" : ""} ${i.id === state.selected ? "sel" : ""}" data-id="${esc(i.id)}">
      <div class="t">${esc(i.title)}</div>
      ${i.snippet ? `<div class="s">${esc(i.snippet)}</div>` : ""}
      <div class="m">
        <span class="prio ${esc(i.priority)}">${cap(i.priority)}</span>
        <span>${esc(PLATFORM[i.platform] ?? i.platform)}${i.version ? ` ${esc(i.version)}` : ""}</span>
        ${(i.tags ?? []).slice(0, 3).map((t) => `<span class="tag">${esc(t)}</span>`).join("")}
        ${i.files?.length ? `<span title="Attachments">📎 ${i.files.length}</span>` : ""}
        ${i.status === "uploading" ? `<span>${unfinished(i)}</span>` : ""}
        <span title="${esc(when(i.createdAt))}">${ago(i.createdAt)}</span>
      </div>
    </button>`).join("");
  el.onclick = (e) => {
    const b = e.target.closest(".item");
    if (b) openItem(b.dataset.id, true);
  };
}

// ---------------------------------------------------------------- one item

async function openItem(id, push) {
  state.selected = id;
  if (push) history.pushState({}, "", `?id=${encodeURIComponent(id)}`);
  document.getElementById("shell").classList.add("showing");
  renderList();
  const pane = document.getElementById("detail");
  pane.innerHTML = `<div class="placeholder">Loading…</div>`;
  try {
    let it = await api(`feedback/${encodeURIComponent(id)}`);
    if (it.status === "new") {
      it = await api(`feedback/${encodeURIComponent(id)}`, { method: "PATCH", body: { status: "seen" } });
      const s = state.items.find((x) => x.id === id);
      if (s) s.status = "seen";
      renderList();
    }
    state.detail = it;
    renderDetail(it);
    pane.scrollTop = 0;
    window.scrollTo(0, 0);
  } catch (e) {
    if (e.status === 401) return gate(false);
    pane.innerHTML = `<div class="placeholder">${esc(e.message)}</div>`;
  }
}

function closeItem(push) {
  state.selected = null;
  if (push) history.pushState({}, "", location.pathname);
  document.getElementById("shell").classList.remove("showing");
  document.getElementById("detail").innerHTML = `<div class="placeholder">Pick something from the list.</div>`;
  renderList();
}

const LABELS = {
  name: "App", version: "Version", build: "Build", commit: "Commit", channel: "Testing group",
  os: "System", model: "Model", chip: "Chip", memoryGB: "Memory (GB)", cpus: "Cores", displays: "Displays",
  locale: "Language", appearance: "Appearance", userAgent: "User agent", screen: "Screen",
  device: "Trackball", connected: "Trackball connected", paused: "Paused", profile: "Profile",
  pointerSpeed: "Pointer speed", scrollMode: "Scroll mode", sync: "iCloud sync",
  accessibility: "Accessibility allowed", inputMonitoring: "Input Monitoring allowed",
};
function kv(title, obj) {
  const rows = Object.entries(obj ?? {}).filter(([, v]) => v !== null && v !== undefined && v !== "");
  if (!rows.length) return "";
  return `<dt class="group">${esc(title)}</dt>` + rows.map(([k, v]) => {
    const val = Array.isArray(v) ? v.join(", ") : typeof v === "boolean" ? (v ? "Yes" : "No") : typeof v === "object" ? JSON.stringify(v) : v;
    return `<dt>${esc(LABELS[k] ?? k)}</dt><dd>${esc(val)}</dd>`;
  }).join("");
}

function fileView(it, f) {
  const url = `/api/admin/file?id=${encodeURIComponent(it.id)}&name=${encodeURIComponent(f.name)}`;
  if (!f.done) return `<div class="file"><div class="cap"><span>${esc(f.name)}</span><span>didn't finish uploading</span></div></div>`;
  const capLine = `<div class="cap"><span>${esc(f.name)}${f.duration ? ` · ${Math.round(f.duration)} s` : ""}</span><a href="${url}&download">${size(f.size)} ↓</a></div>`;
  if (f.type.startsWith("image/")) return `<div class="file"><a href="${url}" target="_blank" rel="noopener"><img src="${url}" alt="${esc(f.name)}" loading="lazy"></a>${capLine}</div>`;
  if (f.type.startsWith("video/")) return `<div class="file wide"><video src="${url}" controls playsinline preload="metadata"></video>${capLine}</div>`;
  return `<div class="file"><div class="cap"><span>${esc(f.name)}</span><a href="${url}&download">Download (${size(f.size)})</a></div></div>`;
}

function renderDetail(it) {
  const auto = new Set(it.autoTags ?? []);
  const done = it.status === "done";
  document.getElementById("detail").innerHTML = `
    <div class="detail-inner">
      <button class="btn back" id="back">‹ All feedback</button>
      <div class="d-head">
        <h2>${esc(it.title)}</h2>
        <div class="actions">
          <button class="btn ${done ? "" : "go"}" id="toggle">${done ? "Back to inbox" : "Mark done"}</button>
          <button class="btn danger" id="delete">Delete</button>
        </div>
      </div>
      <div class="d-meta">
        <span class="prio ${esc(it.priority)}">${cap(it.priority)} priority</span>
        <span>${it.platform === "web" ? "From the website" : `${esc(PLATFORM[it.platform] ?? it.platform)} · ${esc(it.app?.name ?? "Glide")} ${esc(it.app?.version ?? "")}${it.app?.build ? ` (build ${esc(it.app.build)})` : ""}`}</span>
        <span title="${esc(when(it.createdAt))}">${esc(when(it.createdAt))}</span>
        ${it.status === "uploading" ? `<span>${unfinished(it)}</span>` : ""}
      </div>
      ${(it.tags ?? []).length || auto.size ? `<div class="d-tags">${
        [...new Set([...(it.tags ?? []), ...auto])].map((t) => {
          const chosen = (it.tags ?? []).includes(t);
          const suggested = auto.has(t);
          // (A class, not a style attribute: the site's CSP allows no inline styles.)
          return `<span class="tag ${suggested ? "auto" : ""} ${chosen ? "" : "removed"}" title="${suggested ? (chosen ? "Suggested by the app, kept" : "Suggested by the app, removed") : "Chosen"}">${esc(t)}</span>`;
        }).join("")}</div>` : ""}
      <div class="section glass">
        <h3>What they said</h3>
        ${it.details ? `<p class="text">${esc(it.details)}</p>` : `<p class="text none">No details, just the title.</p>`}
      </div>
      ${(it.files ?? []).length ? `<div class="section glass"><h3>Attachments</h3><div class="files">${it.files.map((f) => fileView(it, f)).join("")}</div></div>` : ""}
      <div class="section glass">
        <h3>From</h3>
        <div class="from">
          <span class="who">${esc(it.name || "Someone who didn't say")}</span>
          ${!it.email ? "" : /^[^\s@?&#%/]+@[^\s@?&#%/]+$/.test(it.email)
            ? `<a href="mailto:${esc(it.email)}?subject=${encodeURIComponent(`Your Glide feedback: ${it.title}`)}">${esc(it.email)}</a>`
            : `<span>${esc(it.email)}</span>`}
          ${it.contactOK ? `<span class="ok">Happy to be contacted</span>` : it.email ? `<span>(didn't ask to be contacted)</span>` : ""}
        </div>
      </div>
      <div class="section glass">
        <h3>Their setup</h3>
        <dl class="kv">${kv("App", it.app)}${kv(it.platform === "web" ? "Browser" : "Mac", it.system)}${kv("At the time", it.context)}</dl>
      </div>
    </div>`;
  document.getElementById("back").onclick = () => (history.state !== null && history.length > 1 ? history.back() : closeItem(true));
  document.getElementById("toggle").onclick = async () => {
    try {
      const next = await api(`feedback/${encodeURIComponent(it.id)}`, { method: "PATCH", body: { status: done ? "seen" : "done" } });
      const s = state.items.find((x) => x.id === it.id);
      if (s) s.status = next.status;
      renderDetail(next);
      renderList();
      toast(done ? "Back in the inbox" : "Marked done");
    } catch (e) { toast(e.message); }
  };
  document.getElementById("delete").onclick = async () => {
    if (!confirm(`Delete "${it.title}" and its attachments? This can't be undone.`)) return;
    try {
      await api(`feedback/${encodeURIComponent(it.id)}`, { method: "DELETE" });
      state.items = state.items.filter((x) => x.id !== it.id);
      closeItem(true);
      toast("Deleted");
    } catch (e) { toast(e.message); }
  };
}

function changePassword() {
  const bg = document.createElement("div");
  bg.className = "modal-bg";
  bg.innerHTML = `
    <div class="card glass">
      <h1>Change password</h1>
      <form id="pwf">
        <label for="cur">Current password</label><input class="field" id="cur" type="password" autocomplete="current-password" required>
        <label for="nw">New password (10 or more characters)</label><input class="field" id="nw" type="password" autocomplete="new-password" minlength="10" required>
        <button class="primary" type="submit">Change</button>
        <button class="btn" type="button" id="cancel">Cancel</button>
        <p class="error" id="pwerr"></p>
      </form>
    </div>`;
  document.body.append(bg);
  bg.querySelector("#cur").focus();
  const close = () => bg.remove();
  bg.querySelector("#cancel").onclick = close;
  bg.onclick = (e) => { if (e.target === bg) close(); };
  bg.querySelector("#pwf").onsubmit = async (e) => {
    e.preventDefault();
    try {
      await api("password", { method: "POST", body: { current: bg.querySelector("#cur").value, next: bg.querySelector("#nw").value } });
      close();
      toast("Password changed");
    } catch (err) { bg.querySelector("#pwerr").textContent = err.message; }
  };
}

start();
