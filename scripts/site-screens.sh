#!/bin/zsh
# The website's screenshots, made from the app itself: runs scripts/render-ui.sh
# for the screens the homepage shows (dark, 2x) and writes, for each one,
#   website/assets/screens/<screen>-960.webp, -1600.webp and -1200.png
# Then it updates the homepage so browsers fetch the new pictures: every
# assets/screens/<screen>-… URL gets ?v=<a short hash of the picture> (the
# /assets/ folder is cached for a year), and each <img> gets the picture's
# real width and height.
#
#   scripts/site-screens.sh                 builds the app first
#   scripts/site-screens.sh --no-build      uses the binary that's already built
#
# Needs cwebp (brew install webp). Nothing is deployed; look at the site, then commit.
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"

# Where each one goes on the homepage: pointer = Ball, scrolling = Ring, buttons = Buttons,
# overview = "See what your trackball is doing, live". The app has a sidebar now, so each
# picture is the window as it opens on that tab (the sidebar's trackball included).
SCREENS=(overview pointer scrolling buttons)
OUT=build/site-screens
DEST=website/assets/screens
typeset -a pass
for arg in "$@"; do pass+=("$arg"); done

command -v cwebp >/dev/null || { print -u2 "cwebp is missing: brew install webp"; exit 1; }

scripts/render-ui.sh "$OUT" --appearance dark --scale 2 --only "${(j:,:)SCREENS}" "${pass[@]}"

mkdir -p "$DEST"
for s in $SCREENS; do
  src="$OUT/$s.dark.png"
  [[ -f $src ]] || { print -u2 "render-ui didn't make $src"; exit 1; }
  cwebp -quiet -q 86 -m 6 -resize 960 0 "$src" -o "$DEST/$s-960.webp"
  cwebp -quiet -q 84 -m 6 -resize 1600 0 "$src" -o "$DEST/$s-1600.webp"
  sips --resampleWidth 1200 "$src" --out "$DEST/$s-1200.png" >/dev/null
  print "$s: $(sips -g pixelWidth -g pixelHeight "$src" | awk '/pixel/{printf "%s ", $2}')→ $DEST/$s-{960,1600}.webp, -1200.png"
done

# Point the homepage at the new files.
python3 - "$OUT" "${SCREENS[@]}" <<'PY'
import hashlib, os, re, subprocess, sys
out, screens = sys.argv[1], sys.argv[2:]
page = "website/index.html"
html = open(page, encoding="utf-8").read()
for s in screens:
    src = os.path.join(out, f"{s}.dark.png")
    ver = hashlib.sha256(open(src, "rb").read()).hexdigest()[:8]
    dims = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", src], capture_output=True, text=True).stdout
    w = re.search(r"pixelWidth: (\d+)", dims).group(1)
    h = re.search(r"pixelHeight: (\d+)", dims).group(1)
    # Cache-busting version on every URL of this screen (not the JSON-LD ones, which have none).
    html = re.sub(rf"(assets/screens/{s}-(?:960|1600)\.webp|assets/screens/{s}-1200\.png)\?v=[\w.-]+", rf"\1?v={ver}", html)
    # The real size on the <img> that shows it.
    html = re.sub(rf'(<img src="[^"]*assets/screens/{s}-1200\.png\?v={ver}" )width="\d+" height="\d+"',
                  rf'\1width="{w}" height="{h}"', html)
open(page, "w", encoding="utf-8").write(html)
print(f"updated {page}")
PY
