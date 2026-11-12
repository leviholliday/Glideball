#!/bin/zsh
# Deploys admin-site/ (the admin pages and the /api/admin/* proxy) to
# admin-glideball.netlify.app from a clean copy: only files git tracks (or
# would track), plus the three icons the pages use, copied from website/assets/.
# The data stays on glideball.netlify.app; see docs/ADMIN-SITE.md.
#   scripts/deploy-admin.sh ["deploy message"]
#
# The site ID is never guessed: it comes from $GLIDEBALL_ADMIN_SITE_ID, or from
# admin-site/.site-id (git-ignored; one line, the "Project ID" from the admin
# site's Project configuration page in Netlify).
set -euo pipefail
cd "$(dirname "$0")/.."
MAIN_SITE="749c72a7-7049-463e-8555-48263ed392ec"   # glideball.netlify.app (scripts/deploy-site.sh)

SITE_ID=${GLIDEBALL_ADMIN_SITE_ID:-}
if [[ -z $SITE_ID && -f admin-site/.site-id ]]; then
  SITE_ID=$(tr -d '[:space:]' < admin-site/.site-id)
fi
if [[ -z $SITE_ID ]]; then
  print -u2 "error: no admin site ID. Put it in admin-site/.site-id (or set GLIDEBALL_ADMIN_SITE_ID); see docs/ADMIN-SITE.md"
  exit 1
fi
if [[ ! $SITE_ID =~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' ]]; then
  print -u2 "error: '$SITE_ID' doesn't look like a Netlify site ID (8-4-4-4-12 hex)"
  exit 1
fi
if [[ $SITE_ID == $MAIN_SITE ]]; then
  print -u2 "error: that's the main site's ID, not the admin site's"
  exit 1
fi

# The admin tests (the proxy against the real admin function, the pages' rules).
(
  cd website
  [[ -d node_modules ]] || npm ci --silent --no-audit --no-fund
  npm run -s test:admin
) >/dev/null 2>&1 || { print -u2 "error: the admin tests failed (cd website && npm run test:admin); admin site not deployed"; exit 1; }

if [[ -n $(git status --porcelain -- admin-site) ]]; then
  print -u2 "warning: admin-site/ has uncommitted changes; deploying what is on disk:"
  git status --porcelain -- admin-site | head -n 10 | sed 's/^/         /' >&2
fi

STAGE=$(mktemp -d -t glide-admin)
trap 'rm -rf "$STAGE"' EXIT
git ls-files -co --exclude-standard admin-site | while read -r f; do
  rel=${f#admin-site/}
  [[ $rel == .site-id ]] && continue
  mkdir -p "$STAGE/${rel:h}"
  cp "$f" "$STAGE/$rel"
done
# The icons, from the main site's copies (so there's one of each in the repo).
mkdir -p "$STAGE/public/assets"
for icon in favicon-64.png apple-touch-icon.png icon-256.png; do
  cp "website/assets/$icon" "$STAGE/public/assets/$icon"
done

LOG="$STAGE.deploy.log"
if ! (cd "$STAGE" && netlify deploy --prod --dir public --site "$SITE_ID" --message "${1:-Admin site update}") >"$LOG" 2>&1; then
  tail -n 20 "$LOG" >&2
  rm -f "$LOG"
  print -u2 "error: netlify deploy failed; the admin site was NOT updated"
  exit 1
fi
grep -E "Production URL|Deploy is live" "$LOG" || true
rm -f "$LOG"
