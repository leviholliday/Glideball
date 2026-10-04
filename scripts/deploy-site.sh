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

git ls-files -co --exclude-standard website | while read -r f; do
  rel=${f#website/}
  mkdir -p "$STAGE/${rel:h}"
  cp "$f" "$STAGE/$rel"
done
(cd "$STAGE" && npm ci --silent --no-audit --no-fund)
(cd "$STAGE" && netlify deploy --prod --dir . --site "$NETLIFY_SITE" --message "${1:-Website update}") \
  | grep -E "Production URL|Deploy is live" || true
