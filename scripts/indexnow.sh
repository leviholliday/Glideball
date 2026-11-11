#!/usr/bin/env bash
# Tell IndexNow search engines (Bing, Yandex, Naver, Seznam; Bing also feeds DuckDuckGo/Yahoo)
# that the site's pages changed. Run it by hand after deploying. No account needed: the key file
# website/2c833d30970d088c1c9f40c05af20c7e.txt proves we own the site.
set -euo pipefail

HOST="glideball.netlify.app"
KEY="2c833d30970d088c1c9f40c05af20c7e"

status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "https://api.indexnow.org/indexnow" \
  -H 'Content-Type: application/json; charset=utf-8' \
  -d "{\"host\":\"$HOST\",\"key\":\"$KEY\",\"keyLocation\":\"https://$HOST/$KEY.txt\",\"urlList\":[\"https://$HOST/\",\"https://$HOST/feedback/\"]}")
echo "IndexNow responded HTTP $status (200 or 202 means accepted)"
