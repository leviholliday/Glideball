// For tests that call the admin function (netlify/functions/admin.mjs): every
// request goes in the way the admin site's proxy sends it (its secret, and the
// visitor's address from the test's context), so the tests hold before and
// after the cut-over (docs/ADMIN-SITE.md).

export const PROXY_SECRET = "test-proxy-secret-0123456789abcdef-0123456789";
process.env.ADMIN_PROXY_SECRET = PROXY_SECRET;

/** The request as the proxy forwards it. */
export function proxied(req, context) {
  const headers = new Headers(req.headers);
  headers.set("x-glide-admin-proxy", PROXY_SECRET);
  if (context?.ip) headers.set("x-glide-client-ip", String(context.ip));
  const hasBody = req.method !== "GET" && req.method !== "HEAD" && req.body;
  return new Request(req, { headers, ...(hasBody ? { duplex: "half" } : {}) });
}

/** adminFn, called the proxy's way. */
export const viaProxy = (adminFn) => (req, context) => adminFn(proxied(req, context), context);
