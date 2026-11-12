# The admin site

The admin pages (home, Feedback, Usage, Statistics) are moving from
`glideball.netlify.app/admin/` to a site of their own,
**admin-glideball.netlify.app**, the same way CedarLogic's admin moved to
cedarlogic-admin.netlify.app. They then share nothing with the public pages,
which load the analytics scripts. Netlify adds those scripts to every page of
the public site, so they could see the admin pages and use the admin's
sign-in (the security review's finding).

## How it works

- `admin-site/public/` holds the pages: `/`, `/feedback/`, `/usage/` and `/stats/`.
- `admin-site/netlify.toml` sets a strict policy: the site's own files only, no
  analytics, `noindex`.
- The data stays where it is, in the main site's Netlify Blobs: feedback,
  attachments, usage, crash reports, stats and the admin password. Blobs
  belong to one site.
- `/api/admin/*` on the admin site is an edge function
  (`admin-site/netlify/edge-functions/admin-proxy.js`). It sends each request
  to the main site's admin function (`website/netlify/functions/admin.mjs`)
  with a shared secret, **ADMIN_PROXY_SECRET**, plus the visitor's address, so
  the limit on wrong passwords still counts each visitor separately.
- Sign-in works exactly as today: the same password, the same setup code, the
  same session code. The session cookie now belongs to the admin site's own
  address. The public site never gets it.
- These stay on the main site and don't change: the hourly cleanup, the
  download snapshot four times a day, and the ntfy pushes for new feedback.
  After the cut-over, tapping a push opens the item on the admin site.

Why a shared secret and not a Netlify token: the other way to read another
site's Blobs is a Netlify personal access token, and that token can change
every site on your account. ADMIN_PROXY_SECRET only opens the admin API, which
still asks for your password. It lives in the two sites' settings, never in the
repo or a browser.

## One-time setup (you do this)

1. **Create the site.** In Terminal, from the repo:
   ```
   netlify sites:create --name admin-glideball
   ```
   Pick your team when asked. If the name is taken, use `glideball-admin`
   instead, then also do step 4b. The command prints a **Project ID** (also
   shown in Netlify under the new project, then Project configuration). Don't
   link the folder and don't connect a Git repo: it's deployed by the script.

2. **Save the site ID** where the deploy script reads it (this file is
   git-ignored):
   ```
   echo "PASTE-THE-PROJECT-ID" > admin-site/.site-id
   ```

3. **Make the secret.** Run `openssl rand -base64 48` and copy what it prints.
   It's at least 32 characters, and both sites refuse anything shorter.

4. **Set it on both sites.** In Netlify, for **glideball** and then for
   **admin-glideball**: Project configuration, Environment variables, Add a
   variable. Key: `ADMIN_PROXY_SECRET`. Value: the secret from step 3. Mark it
   as a secret, and leave the Functions scope on (that also covers edge
   functions). Use the same value on both sites.
   - 4b. Only if the site is called `glideball-admin`: also add `ADMIN_URL` =
     `https://glideball-admin.netlify.app` on **glideball**. Before the
     cut-over, change `admin-glideball` to `glideball-admin` in its two
     redirect rules in `website/netlify.toml`.
   - Leave SESSION_SECRET, SETUP_CODE and NTFY_TOPIC on **glideball** only.
     The admin site doesn't need them.

5. **Deploy both.** The main site needs a deploy to pick up the new variable:
   ```
   scripts/deploy-site.sh "Admin site: accept the proxy"
   scripts/deploy-admin.sh "First deploy"
   ```

6. **Check it.**
   - Open https://admin-glideball.netlify.app/ and sign in with your usual
     password. Open Feedback, an attachment, Usage and Statistics.
   - `curl -sI https://admin-glideball.netlify.app/ | grep -i -E "content-security|x-robots"`
     shows `default-src 'none'` and `noindex, nofollow`.
   - The old https://glideball.netlify.app/admin/ still works too until the
     cut-over.
   - If the pages say "The admin site isn't set up (ADMIN_PROXY_SECRET)", the
     variable is missing on admin-glideball. If they say "The admin pages are
     at …", the two values don't match (or glideball wasn't redeployed).

## Step 2: the cut-over (once step 6 checks out)

This is one commit on the branch `admin-site-cutover`. It:

- turns off direct access in `admin.mjs` (`DIRECT_ACCESS = false`), so the main
  site answers `/api/admin/*` only to the admin site's proxy and tells anyone
  else where the admin pages are
- redirects `/admin` and `/admin/*` on the public site to the admin site (302;
  `/admin/feedback/?id=…` goes to `/feedback/?id=…`, so older push links still
  work)
- stops publishing the copy of the admin pages at `/admin/`, and drops their
  separate policy from the public site's `netlify.toml`
- points new ntfy pushes at the admin site

To do it:
```
git merge admin-site-cutover
scripts/deploy-site.sh "Admin moved to admin-glideball.netlify.app"
```
Then check: https://glideball.netlify.app/admin goes to the admin site, and
`curl -s https://glideball.netlify.app/api/admin/session` answers with "The
admin pages are at https://admin-glideball.netlify.app/". To undo, revert that
commit and deploy the main site again.

## Later

- Admin page changes: `scripts/deploy-admin.sh`. Admin API changes
  (`admin.mjs`, `website/netlify/lib/`): `scripts/deploy-site.sh`, because the
  API runs on the main site.
- To change the secret, set the new value on both sites, then redeploy the
  main site and the admin site. Until both are redeployed, the admin pages
  can't reach the data.
- Tests: `cd website && npm run test:admin`, also run by `npm test` and
  `scripts/check.sh` (step `admin`).

## About "/admin goes to /admin/feedback"

No redirect rule ever did this. `website/netlify.toml` has never had an
`/admin` rule (git history included), and the live deploy (6af53d13, 12 Nov
04:14 UTC) has exactly the 10 rules in that file, none for `/admin`. That
deploy includes `admin/index.html`, the new home page. So `/admin` should
go to `/admin/` and show the home page. The likely cause is the browser's
address bar filling in `/admin/feedback/` from history, or a check made before
that deploy. Try a private window. After the cut-over, an explicit rule sends
`/admin` to the admin site's home page.
