#!/bin/zsh
# Deploys website/ (pages + feedback functions) to glideball.netlify.app
# from a clean copy: only files git tracks (or would track), plus a fresh
# `npm ci` for the functions — so local test data, lockfiles and node_modules
# junk never reach the live site.
#   scripts/deploy-site.sh ["deploy message"]
set -euo pipefail
cd "$(dirname "$0")/.."
NETLIFY_SITE="749c72a7-7049-463e-8555-48263ed392ec"
STAGE=$(mktemp -d -t glide-site)
trap 'rm -rf "$STAGE"' EXIT

# Build the generated pages (help, changelog…) and the shared nav/footer first,
# so the changelog has the latest releases. The warning below then also
# catches pages the build changed that aren't committed yet.
python3 scripts/build_pages.py \
  || { print -u2 "error: scripts/build_pages.py failed; website not deployed"; exit 1; }
python3 scripts/check_site.py \
  || { print -u2 "error: scripts/check_site.py found problems; website not deployed"; exit 1; }

# It publishes what is on disk (tracked or untracked), so say if that isn't committed.
if [[ -n $(git status --porcelain -- website) ]]; then
  print -u2 "warning: website/ has uncommitted changes; deploying what is on disk:"
  git status --porcelain -- website | head -n 10 | sed 's/^/         /' >&2
fi

git ls-files -co --exclude-standard website | while read -r f; do
  rel=${f#website/}
  [[ $rel == _pages/* ]] && continue   # page sources; the built pages are what's served
  mkdir -p "$STAGE/${rel:h}"
  cp "$f" "$STAGE/$rel"
done
# UNTIL THE CUT-OVER (docs/ADMIN-SITE.md, step 2): the admin pages, whose home
# is now admin-site/public/, are also published here at /admin/ as before, so
# nothing breaks while the admin site is being set up. The cut-over deletes
# these lines and redirects /admin/* to the admin site instead.
mkdir -p "$STAGE/admin"
git ls-files -co --exclude-standard admin-site/public | while read -r f; do
  rel=${f#admin-site/public/}
  [[ $rel == robots.txt ]] && continue
  mkdir -p "$STAGE/admin/${rel:h}"
  cp "$f" "$STAGE/admin/$rel"
done

(cd "$STAGE" && npm ci --silent --no-audit --no-fund) \
  || { print -u2 "error: npm ci failed; website not deployed"; exit 1; }

LOG="$STAGE.deploy.log"
if ! (cd "$STAGE" && netlify deploy --prod --dir . --site "$NETLIFY_SITE" --message "${1:-Website update}") >"$LOG" 2>&1; then
  tail -n 20 "$LOG" >&2
  rm -f "$LOG"
  print -u2 "error: netlify deploy failed; the website was NOT updated"
  exit 1
fi
grep -E "Production URL|Deploy is live" "$LOG" || true
rm -f "$LOG"
