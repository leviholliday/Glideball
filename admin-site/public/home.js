// Glideball Admin: the home page. Signs in like the other admin pages (the
// same session, the same /api/admin/* routes), then links to Feedback, Usage
// and Statistics with a few headline numbers. Each number is optional: if one
// can't load, that card just shows its link. (No inline styles or on*=
// attributes: the admin CSP forbids them.)

const app = document.getElementById("app");
const ICON = "/assets/icon-256.png";
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

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

async function start() {
  try {
    const s = await api("session");
    if (s.loggedIn) return main();
    return gate(!!s.needsSetup);
  } catch (e) {
    app.innerHTML = `<div class="gate"><div class="card glass"><img src="${ICON}" alt=""><h1>Can't reach the server</h1><p>${esc(e.message)}</p></div></div>`;
  }
}

function gate(setup) {
  if (setup) {
    app.innerHTML = `<div class="gate"><div class="card glass"><img src="${ICON}" alt=""><h1>Glideball Admin</h1>
      <p>The password isn't set yet. Set it once on the Feedback page.</p>
      <a class="primary link-btn" href="feedback/">Go to setup</a></div></div>`;
    return;
  }
  app.innerHTML = `
    <div class="gate"><div class="card glass">
      <img src="${ICON}" alt="">
      <h1>Glideball Admin</h1>
      <p>Sign in to see feedback, usage and statistics.</p>
      <form id="gate">
        <label for="pw">Password</label>
        <input class="field" id="pw" type="password" autocomplete="current-password" required autofocus>
        <button class="primary" type="submit">Sign in</button>
        <p class="error" id="err"></p>
      </form>
    </div></div>`;
  const form = document.getElementById("gate");
  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const err = document.getElementById("err");
    const btn = form.querySelector("button");
    err.textContent = "";
    btn.disabled = true;
    try {
      await api("login", { method: "POST", body: { password: document.getElementById("pw").value } });
      main();
    } catch (e) {
      err.textContent = e.message;
      btn.disabled = false;
    }
  });
}

const n = (v) => (v !== null && v !== undefined && Number.isFinite(Number(v)) ? Number(v).toLocaleString() : null);

function card(href, title, line, id) {
  return `<a class="nav-card glass" href="${href}"><strong>${esc(title)}</strong><span>${esc(line)}</span><div class="num" id="${id}"></div></a>`;
}

function main() {
  app.innerHTML = `
    <header class="top glass">
      <img src="${ICON}" alt="">
      <h1>Admin</h1>
      <span class="spacer"></span>
      <button class="icon-btn" id="sign-out">Sign out</button>
    </header>
    <main class="home">
      <nav class="cards" aria-label="Admin pages">
        ${card("feedback/", "Feedback", "What people send from the app and the site: read, sort and answer it.", "n-feedback")}
        ${card("usage/", "Usage", "What the app reports from people who turned on anonymous usage statistics.", "n-usage")}
        ${card("stats/", "Statistics", "Downloads, feedback counts and site health: aggregate numbers only.", "n-stats")}
      </nav>
    </main>`;
  document.getElementById("sign-out").addEventListener("click", async () => {
    try { await api("logout", { method: "POST" }); } catch {}
    gate(false);
  });
  const show = (id, value, label) => {
    const el = document.getElementById(id);
    if (el && value !== null) el.innerHTML = `<b>${esc(value)}</b><em>${esc(label)}</em>`;
  };
  api("stats").then((s) => {
    show("n-feedback", n(s.feedback?.data?.open), "open now");
    show("n-stats", n(s.downloads?.data?.all), "downloads in all");
  }).catch((e) => { if (e.status === 401) gate(false); });
  api("usage?days=7").then((d) => {
    const w = d.perWeek?.length ? d.perWeek[d.perWeek.length - 1].active : null;
    show("n-usage", n(w), "installs this week");
  }).catch(() => {});
}

start();
