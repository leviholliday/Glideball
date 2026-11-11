#!/usr/bin/env bash
# Tell IndexNow engines (Bing, Yandex, Seznam, Naver, Yep; Bing feeds DuckDuckGo and Yahoo)
# which pages exist. Run it by hand after deploying. 200 or 202 = accepted; neither means
# "indexed". The URLs come from website/sitemap.xml, so add new pages there.
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="glideball.netlify.app"
KEY="2c833d30970d088c1c9f40c05af20c7e"
# The live key file must answer before we submit, or the engines reply 403/422.
curl -fsS "https://$HOST/$KEY.txt" | grep -qx "$KEY" || { echo "IndexNow key file not live; skipped"; exit 0; }
urls=$(grep -o '<loc>[^<]*</loc>' website/sitemap.xml | sed 's/<\/*loc>//g' | sed 's/.*/"&"/' | paste -sd, -)
[ -n "$urls" ] || { echo "No URLs found in website/sitemap.xml" >&2; exit 1; }
status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "https://api.indexnow.org/indexnow" \
  -H 'Content-Type: application/json; charset=utf-8' \
  -d "{\"host\":\"$HOST\",\"key\":\"$KEY\",\"keyLocation\":\"https://$HOST/$KEY.txt\",\"urlList\":[$urls]}")
echo "IndexNow: HTTP $status (200/202 accepted; 422 = URL/key mismatch; 429 = too often)"
