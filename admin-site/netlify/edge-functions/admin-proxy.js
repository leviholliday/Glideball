// The admin site's /api/admin/*: passed on to the main site's admin function
// (website/netlify/functions/admin.mjs on glideball.netlify.app), which keeps
// the data (its Netlify Blobs stores: feedback, usage, crashes, stats) and the
// password. The same approach as CedarLogic's admin site.
//
// Why a proxy and not reading the Blobs from here: Blobs belong to one site.
// Reading another site's stores needs a Netlify personal access token, which
// opens every site on the account. ADMIN_PROXY_SECRET opens only the admin
// API, and lives only in the two sites' environment variables (never in the
// repo or the browser).
//
// Why an edge function and not a netlify.toml proxy rewrite: a rewrite's
// headers are fixed text (it can't read the secret from the environment).
// Here the secret comes from ADMIN_PROXY_SECRET at run time, and the visitor's
// own address (context.ip) goes with it, so the main site's sign-in limits
// stay per visitor and not one shared counter for this proxy.
//
// Only what the admin pages need is passed on, both ways: no other request
// header (so a visitor can't send their own x-glide-admin-proxy or
// x-glide-client-ip) and no other reply header. The session cookie is set by
// the main site's reply but, coming through here, it belongs to this site's
// host: the main site's public pages never hold it.
//
// Plain web APIs only, so admin-site/tests/admin-proxy.test.mjs runs it in node.

export const UPSTREAM = "https://glideball.netlify.app";
export const PROXY_HEADER = "x-glide-admin-proxy";
export const CLIENT_IP_HEADER = "x-glide-client-ip";
// (range: the attachment player asks for byte ranges.)
const REQUEST_HEADERS = ["accept", "content-type", "cookie", "range", "x-glide-admin", "user-agent"];
const REPLY_HEADERS = ["content-type", "content-length", "content-range", "accept-ranges", "content-disposition", "cache-control",
  "retry-after", "content-security-policy", "x-content-type-options"];

const refuse = (status, error) => new Response(JSON.stringify({ error }), {
  status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
});

/** One request to /api/admin/*, passed on. opts: { secret, upstream, fetch }
 * (the tests'; the handler below gives the real ones). */
export async function proxy(request, context, { secret, upstream = UPSTREAM, fetch: send = fetch } = {}) {
  if (!secret || secret.length < 32) return refuse(500, "The admin site isn't set up (ADMIN_PROXY_SECRET).");
  const url = new URL(request.url);
  if (!url.pathname.startsWith("/api/admin/")) return refuse(404, "Not here.");
  const method = request.method;
  // A change from another site's page (it couldn't add x-glide-admin without
  // a preflight, which nothing here answers, and the cookie is SameSite=Strict,
  // but still): never passed on.
  const origin = request.headers.get("origin");
  if (method !== "GET" && method !== "HEAD" && origin && origin !== url.origin) return refuse(403, "Not from this site.");

  const headers = new Headers();
  for (const k of REQUEST_HEADERS) {
    const v = request.headers.get(k);
    if (v !== null) headers.set(k, v);
  }
  headers.set(PROXY_HEADER, secret);
  if (context?.ip) headers.set(CLIENT_IP_HEADER, String(context.ip));
  // Uncompressed from the main site (Netlify compresses it again for the
  // browser): a body unzipped on the way in would otherwise go out still
  // labelled gzip.
  headers.set("accept-encoding", "identity");

  const target = new URL(url.pathname + url.search, upstream);
  let r;
  try {
    r = await send(target, {
      method, headers, redirect: "manual",
      body: method === "GET" || method === "HEAD" ? undefined : await request.arrayBuffer(),
    });
  } catch (e) {
    console.error("admin proxy:", e?.name);
    return refuse(502, "The main site didn't answer.");
  }
  const out = new Headers();
  for (const k of REPLY_HEADERS) {
    const v = r.headers.get(k);
    if (v !== null) out.set(k, v);
  }
  if (r.headers.get("content-encoding")) out.delete("content-length");
  for (const c of r.headers.getSetCookie?.() ?? []) out.append("set-cookie", c);
  out.set("cross-origin-resource-policy", "same-origin");
  out.set("x-robots-tag", "noindex, nofollow");
  out.set("referrer-policy", "no-referrer");
  if (!out.has("cache-control")) out.set("cache-control", "no-store");
  return new Response(method === "HEAD" ? null : r.body, { status: r.status, headers: out });
}

export default (request, context) => proxy(request, context, { secret: globalThis.Netlify?.env.get("ADMIN_PROXY_SECRET") });

export const config = { path: "/api/admin/*" };
