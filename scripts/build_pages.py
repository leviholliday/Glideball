#!/usr/bin/env python3
"""Builds the website's extra pages and keeps the shared nav and footer in step.

    python3 scripts/build_pages.py

What it does (Python standard library only, no framework):
  1. Renders every website/_pages/**/*.html into website/<path>/index.html,
     wrapped in the shared head (SEO tags, breadcrumb JSON-LD), nav and footer.
  2. Builds /changelog/ from the GitHub releases (`gh api`, read-only). Without
     gh or a network it uses scripts/releases-cache.json, which it refreshes
     whenever gh works.
  3. Replaces the nav and footer between the <!-- site-nav --> / <!-- /site-nav -->
     and <!-- site-footer --> / <!-- /site-footer --> markers in the hand-written
     pages (index.html, feedback/, 404.html), so every page shares one copy.
  4. Rewrites website/sitemap.xml: the built pages plus whatever else it
     already lists (the home page, /feedback/), keeping their lastmod.

The generated files are committed, so the site works without running this.
scripts/deploy-site.sh runs it before every deploy.

A page in website/_pages starts with a comment of "key: value" lines:

    <!--
    title: How to Uninstall KensingtonWorks · Glideball
    description: ...
    path: /help/uninstall-kensingtonworks/
    crumb: Uninstall KensingtonWorks
    parent: /help/
    nav: help
    kicker: Help
    h1: How to uninstall KensingtonWorks
    lede: One or two sentences (HTML allowed).
    updated: 2026-11-10
    -->
    ...the rest of the page body...

<details data-faq> blocks in a body also become FAQPage structured data.
"""
import json
import os
import re
import subprocess
import sys
from datetime import date, datetime
from html import escape, unescape

HERE = os.path.dirname(os.path.abspath(__file__))
WEB = os.path.normpath(os.path.join(HERE, "..", "website"))
PAGES = os.path.join(WEB, "_pages")
CACHE = os.path.join(HERE, "releases-cache.json")
SITE = "https://glideball.netlify.app"
REPO = "leviholliday/glideball"
ZIP = f"https://github.com/{REPO}/releases/latest/download/Glideball.zip"
DOWNLOAD = "/download/"   # the "Your download is starting" page, which starts ZIP
# /assets/ is cached for a year: bump ASSET_V when the icons or og.png change (scripts/site-icons.py).
ASSET_V = "4"
OG_IMAGE = SITE + f"/assets/og.png?v={ASSET_V}"
OG_ALT = ("The Glideball app icon, a glowing trackball, next to the name Glideball and the line: "
          "A smoother scroll ring and a faster pointer for your Kensington trackball")

# ------------------------------------------------------------------ nav + footer
# (href, label, key). The key marks the current page (aria-current).
NAV = [
    ("/#features", "Features", "features"),
    ("/#install", "Install", "install"),
    ("/help/", "Help", "help"),
    ("/trackballs/", "Trackballs", "trackballs"),
    ("/changelog/", "What's new", "changelog"),
    ("/feedback/", "Feedback", "feedback"),
]

FOOTER_COLS = [
    ("Glideball", [
        (DOWNLOAD, "Download for Mac"),
        ("/#features", "Features"),
        ("/#install", "Install"),
        ("/changelog/", "What's new"),
        ("/trackballs/", "Supported trackballs"),
        ("/kensingtonworks-alternative/", "KensingtonWorks alternative"),
    ]),
    ("Help", [
        ("/help/", "All help"),
        ("/#faq", "FAQ"),
        ("/help/open-anyway/", "First launch"),
        ("/help/permissions/", "Permissions"),
        ("/help/troubleshooting/", "Troubleshooting"),
        ("/help/uninstall-kensingtonworks/", "Uninstall KensingtonWorks"),
        ("/help/uninstall-glideball/", "Uninstall Glideball"),
    ]),
    ("Contact", [
        ("/feedback/", "Send feedback"),
        ("mailto:glideball@proton.me", "glideball@proton.me"),
        (f"https://github.com/{REPO}/issues", "GitHub issues"),
    ]),
]


def nav_html(current=None, home=False):
    cur = ' aria-current="page"'
    links = "\n        ".join(
        f'<a href="{h}"{cur if k == current else ""}>{label}</a>' for h, label, k in NAV)
    brand = "#top" if home else "/"
    return f"""<header class="nav-wrap">
    <div class="nav">
      <a class="brand" href="{brand}" aria-label="Glideball home">
        <img src="/assets/icon-256.webp?v={ASSET_V}" width="28" height="28" alt="">
        <span>Glideball</span>
      </a>
      <nav class="nav-links" aria-label="Primary">
        {links}
      </nav>
      <a class="btn btn-primary btn-sm" href="{DOWNLOAD}">
        <svg class="icon" aria-hidden="true"><use href="#i-download"/></svg>
        <span>Download</span>
      </a>
      <details class="nav-menu">
        <summary aria-label="Menu"><span class="nav-menu-bars" aria-hidden="true"></span></summary>
        <nav class="nav-menu-panel" aria-label="Menu">
          {links.replace(chr(10) + "        ", chr(10) + "          ")}
        </nav>
      </details>
    </div>
  </header>"""


def footer_html():
    cols = "\n".join(
        f'        <div class="footer-col">\n          <h2 class="footer-h">{title}</h2>\n          <ul>'
        + "".join(f'<li><a href="{h}">{label}</a></li>' for h, label in items)
        + "</ul>\n        </div>"
        for title, items in FOOTER_COLS)
    return f"""<footer class="footer">
    <div class="container footer-inner">
      <div class="footer-about">
        <div class="footer-brand">
          <img src="/assets/icon-256.webp?v={ASSET_V}" width="24" height="24" alt="" loading="lazy">
          <span>Glideball</span>
        </div>
        <p class="footer-tag">A free, open-source Mac app for Kensington trackballs. Made by Levi Holliday, a student.</p>
      </div>
      <div class="footer-cols">
{cols}
      </div>
      <nav class="footer-links" aria-label="Footer">
        <a href="https://github.com/{REPO}">GitHub</a>
        <a href="https://github.com/{REPO}/releases">Releases</a>
        <a href="/privacy/">Privacy</a>
        <a href="https://gravatar.com/optimistic1bba948d22" rel="me">Gravatar</a>
      </nav>
      <p class="legal">Glideball is an independent project and is not affiliated with or endorsed by Kensington. Kensington, Expert Mouse and KensingtonWorks are trademarks of their respective owners.</p>
    </div>
  </footer>
  <script src="/nav.js" defer></script>"""


# ------------------------------------------------------------------ icons
ICONS = {
    "download": '<path d="M12 4v11m0 0-4.5-4.5M12 15l4.5-4.5M5 19.5h14"/>',
    "arrow": '<path d="M5 12h14m0 0-5.5-5.5M19 12l-5.5 5.5"/>',
    "chevron": '<path d="m6 9 6 6 6-6"/>',
    "check": '<path d="m5 12.5 4.4 4.4L19 7.5"/>',
    "shield": '<path d="M12 3 19 6v5.5c0 4.3-2.9 7.9-7 9.2-4.1-1.3-7-4.9-7-9.2V6z"/><path d="m9 12 2.1 2.1L15.2 10"/>',
    "lock": '<rect x="5" y="10.5" width="14" height="10" rx="2.6"/><path d="M8.2 10.5V8a3.8 3.8 0 0 1 7.6 0v2.5"/>',
    "power": '<path d="M12 3.5V11"/><path d="M6.4 7a7.6 7.6 0 1 0 11.2 0"/>',
    "wrench": '<path d="M14.5 5.5a4 4 0 0 0 5 5L12 18a2.1 2.1 0 0 1-3-3l7.5-7.5"/><path d="M14.5 5.5 17 3l4 4-2.5 2.5"/>',
    "trash": '<path d="M4.5 7h15M9.5 7V4.5h5V7M6.5 7l1 13h9l1-13"/><path d="M10 11v5.5M14 11v5.5"/>',
    "swap": '<path d="M4 8h14m0 0-3.5-3.5M18 8l-3.5 3.5M20 16H6m0 0 3.5-3.5M6 16l3.5 3.5"/>',
    "alert": '<path d="M12 3.8 21 19.5H3z"/><path d="M12 10v4.2M12 17h.01"/>',
    "question": '<circle cx="12" cy="12" r="8.5"/><path d="M9.6 9.4a2.5 2.5 0 0 1 4.8 1c0 1.7-2.4 2.1-2.4 3.6M12 17h.01"/>',
    "list": '<path d="M9 6.5h11M9 12h11M9 17.5h11"/><path d="M4.5 6.5h.01M4.5 12h.01M4.5 17.5h.01"/>',
    "target": '<circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="3.6"/>',
    "file": '<path d="M7 3h7l5 5v12a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z"/><path d="M14 3v5h5M9.5 13.5h5M9.5 17h5"/>',
    "github": '<path class="fill" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8z"/>',
}


def sprite():
    out = []
    for name, paths in ICONS.items():
        box = "0 0 16 16" if name == "github" else "0 0 24 24"
        out.append(f'    <symbol id="i-{name}" viewBox="{box}">{paths}</symbol>')
    return ('<svg class="sprite" aria-hidden="true" focusable="false" xmlns="http://www.w3.org/2000/svg">\n'
            + "\n".join(out) + "\n  </svg>")


def icon(name):
    return f'<svg class="icon" aria-hidden="true"><use href="#i-{name}"/></svg>'


# ------------------------------------------------------------------ helpers
def plain(html_text):
    """HTML as the words a reader sees."""
    return re.sub(r"\s+", " ", unescape(re.sub(r"<[^>]+>", "", html_text))).strip()


def long_date(iso):
    d = date.fromisoformat(iso[:10])
    return f"{d.strftime('%B')} {d.day}, {d.year}"


def attr(s):
    return escape(s, quote=True)


def crumbs_ld(trail):
    return {"@type": "BreadcrumbList", "@id": SITE + trail[-1][1] + "#breadcrumb", "itemListElement": [
        {"@type": "ListItem", "position": i, "name": n, "item": SITE + p} for i, (n, p) in enumerate(trail, 1)]}


def faq_ld(body):
    items = re.findall(r"<details[^>]*\bdata-faq\b[^>]*>\s*<summary>(.*?)</summary>(.*?)</details>", body, re.S)
    if not items:
        return None
    return {"@type": "FAQPage", "@id": "#faq", "mainEntity": [
        {"@type": "Question", "name": plain(q), "acceptedAnswer": {"@type": "Answer", "text": plain(a)}}
        for q, a in items]}


# ------------------------------------------------------------------ one page
ROBOTS = "index, follow, max-image-preview:large, max-snippet:-1"


def indexed(meta):
    """A page with "robots: noindex" in its header stays out of the sitemap."""
    return "noindex" not in meta.get("robots", "")


def render(meta, body, trail):
    path = meta["path"]
    url = SITE + path
    title, desc = meta["title"], meta["description"]
    if len(title) > 60 or len(desc) > 160:
        print(f"note: {path}: title {len(title)} / description {len(desc)} characters; search results may cut them")
    updated = meta["updated"]
    graph = [
        {"@type": "WebPage", "@id": url + "#webpage", "url": url, "name": title, "description": desc,
         "inLanguage": "en", "dateModified": updated,
         "isPartOf": {"@id": SITE + "/#website"},
         "breadcrumb": {"@id": url + "#breadcrumb"},
         "about": {"@id": SITE + "/#app"}},
        crumbs_ld(trail),
    ]
    faq = faq_ld(body)
    if faq:
        faq["@id"] = url + "#faq"
        graph.append(faq)
    ld = json.dumps({"@context": "https://schema.org", "@graph": graph}, ensure_ascii=False, indent=1)
    crumb_html = '<span aria-hidden="true">›</span>'.join(
        f'<a href="{p}">{escape(n)}</a>' if i < len(trail) - 1 else f'<span aria-current="page">{escape(n)}</span>'
        for i, (n, p) in enumerate(trail))
    extra_head = meta.get("head", "")
    # "scripts: /app.js" in a page header: more of the site's own scripts (the CSP allows 'self' only).
    scripts = "".join(f'\n  <script src="{attr(src)}" defer></script>' for src in meta.get("scripts", "").split())
    body_class = f' class="{attr(meta["body_class"])}"' if meta.get("body_class") else ""
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>{escape(title, quote=False)}</title>
  <meta name="description" content="{attr(desc)}">
  <meta name="robots" content="{meta.get('robots', ROBOTS)}">
  <link rel="canonical" href="{url}">
  <meta name="application-name" content="Glideball">
  <meta name="color-scheme" content="dark">
  <meta name="theme-color" content="#0b0b10">
  <link rel="icon" href="/favicon.ico" sizes="48x48">
  <link rel="icon" type="image/png" sizes="64x64" href="/assets/favicon-64.png?v={ASSET_V}">
  <link rel="apple-touch-icon" sizes="180x180" href="/assets/apple-touch-icon.png?v={ASSET_V}">
  <meta property="og:url" content="{url}">
  <meta property="og:type" content="{meta.get('og_type', 'website')}">
  <meta property="og:site_name" content="Glideball">
  <meta property="og:locale" content="en_US">
  <meta property="og:title" content="{attr(title)}">
  <meta property="og:description" content="{attr(desc)}">
  <meta property="og:image" content="{OG_IMAGE}">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">
  <meta property="og:image:alt" content="{attr(OG_ALT)}">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="{attr(title)}">
  <meta name="twitter:description" content="{attr(desc)}">
  <meta name="twitter:image" content="{OG_IMAGE}">{extra_head}
  <link rel="stylesheet" href="/styles.css">{scripts}
  <script src="/privacy.js" defer></script>
  <script type="application/ld+json">
{ld}
  </script>
</head>
<body{body_class}>
  <!-- Generated by scripts/build_pages.py from {meta['source']}. Edit that file, not this one. -->
  {sprite()}

  <a class="skip" href="#main">Skip to content</a>

  <!-- site-nav -->
  {nav_html(meta.get("nav"))}
  <!-- /site-nav -->

  <main id="main" class="pg">
    <div class="container pg-container">
      <nav class="crumbs" aria-label="Breadcrumb">{crumb_html}</nav>
      <header class="pg-hero">
        <h1>{meta["h1"]}</h1>
        {f'<p class="lede">{meta["lede"]}</p>' if meta.get("lede") else ""}
      </header>
{body.rstrip()}
      <p class="pg-updated">Last updated <time datetime="{updated}">{long_date(updated)}</time></p>
    </div>
  </main>

  <!-- site-footer -->
  {footer_html()}
  <!-- /site-footer -->
</body>
</html>
"""


# <!-- cta --> in a page body: the closing download card.
CTA = f"""      <section class="pg-cta" aria-labelledby="cta-h">
        <picture>
          <source srcset="/assets/icon-256.webp?v={ASSET_V}" type="image/webp">
          <img src="/assets/icon-256.png?v={ASSET_V}" width="72" height="72" alt="" loading="lazy">
        </picture>
        <h2 id="cta-h">Get Glideball</h2>
        <p>Free and open source. macOS 26 Tahoe or later, on Apple silicon or Intel.</p>
        <div class="cta-row">
          <a class="btn btn-primary btn-lg" href="{DOWNLOAD}">{icon('download')}<span>Download for Mac</span></a>
          <a class="btn btn-secondary btn-lg" href="https://github.com/{REPO}">{icon('github')}<span>View on GitHub</span></a>
        </div>
      </section>"""

# <!-- still-stuck --> in a page body: where to get help.
STUCK = """      <section class="pg-section">
        <div class="callout">
          <svg class="icon" aria-hidden="true"><use href="#i-question"/></svg>
          <div>
            <p><strong>Still stuck?</strong> Tell me what happened on the <a href="/feedback/">feedback page</a> or email <a href="mailto:glideball@proton.me">glideball@proton.me</a>. In the app, Help › Send Feedback… can attach your settings and a scroll log, and you see it all before it goes. It's just me, so replies can take a few days.</p>
          </div>
        </div>
      </section>"""


def install_steps():
    """The homepage's install steps (between its <!-- install-steps --> markers), so
    /download/ shows the very same words."""
    with open(os.path.join(WEB, "index.html"), encoding="utf-8") as f:
        m = re.search(r"<!-- install-steps -->\n(.*?)\n\s*<!-- /install-steps -->", f.read(), re.S)
    if not m:
        sys.exit("index.html: no <!-- install-steps --> markers to copy the install steps from")
    return m.group(1)


def parse_page(file):
    with open(file, encoding="utf-8") as f:
        text = f.read()
    text = text.replace("<!-- cta -->", CTA).replace("<!-- still-stuck -->", STUCK)
    if "<!-- install-steps -->" in text:
        text = text.replace("<!-- install-steps -->", install_steps())
    m = re.match(r"\s*<!--(.*?)-->\n?", text, re.S)
    if not m:
        sys.exit(f"{file}: needs a <!-- key: value --> header")
    meta = {}
    for line in m.group(1).strip().splitlines():
        if line.strip():
            k, _, v = line.partition(":")
            meta[k.strip()] = v.strip()
    for k in ("title", "description", "path", "crumb", "h1", "updated"):
        if k not in meta:
            sys.exit(f"{file}: missing '{k}'")
    meta["source"] = os.path.relpath(file, os.path.join(WEB, "..")).replace(os.sep, "/")
    return meta, text[m.end():]


def trail_for(meta, by_path):
    trail = [(meta["crumb"], meta["path"])]
    parent = meta.get("parent")
    while parent:
        p = by_path[parent]
        trail.insert(0, (p["crumb"], p["path"]))
        parent = p.get("parent")
    return [("Glideball", "/")] + trail


def write(path, text):
    out = os.path.join(WEB, path.strip("/"), "index.html")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    old = open(out, encoding="utf-8").read() if os.path.exists(out) else None
    if old != text:
        with open(out, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"wrote {os.path.relpath(out, WEB)}")


# ------------------------------------------------------------------ changelog
def releases():
    data = None
    try:
        out = subprocess.run(
            ["gh", "api", f"repos/{REPO}/releases", "--paginate", "--jq",
             '.[] | select(.draft | not) | {tag: .tag_name, name: .name, date: .published_at, '
             'prerelease: .prerelease, url: .html_url, body: (.body // "")}'],
            capture_output=True, text=True, timeout=60)
        if out.returncode == 0 and out.stdout.strip():
            data = [json.loads(line) for line in out.stdout.splitlines() if line.strip()]
            data.sort(key=lambda r: r["date"], reverse=True)
            with open(CACHE, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=1, ensure_ascii=False)
                f.write("\n")
        else:
            print("note: gh api failed; using scripts/releases-cache.json", file=sys.stderr)
    except (OSError, subprocess.SubprocessError):
        print("note: gh not available; using scripts/releases-cache.json", file=sys.stderr)
    if data is None and os.path.exists(CACHE):
        with open(CACHE, encoding="utf-8") as f:
            data = json.load(f)
    return data or []


def md_inline(s):
    """One line of release-note markdown as safe HTML: **bold**, `code`, [links](https://…)."""
    links = []

    def keep(m):
        links.append((m.group(1), m.group(2)))
        return f"\x00{len(links) - 1}\x00"
    s = re.sub(r"\[([^\]]+)\]\((https://[^)\s]+)\)", keep, s)
    s = escape(s, quote=False)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"(?<![\w*])\*([^*\s][^*]*)\*(?![\w*])", r"<em>\1</em>", s)
    s = re.sub(r"(?<=\w) > (?=[A-Z'‘\"])", " › ", s)
    s = s.replace(" — ", ", ").replace(" – ", ", ")   # the site writes no dashes as pauses
    s = re.sub(r"\x00(\d+)\x00", lambda m: f'<a href="{attr(links[int(m.group(1))][1])}">{escape(links[int(m.group(1))][0], quote=False)}</a>', s)
    return s


def md_block(body):
    """Release notes as HTML. The download boilerplate after a '---' line is left out."""
    body = re.split(r"^\s*---+\s*$", body.replace("\r\n", "\n"), maxsplit=1, flags=re.M)[0]
    out, para, items = [], [], []

    def flush():
        if para:
            out.append("<p>" + md_inline(" ".join(para)) + "</p>")
            para.clear()
        if items:
            out.append("<ul>" + "".join(f"<li>{md_inline(i)}</li>" for i in items) + "</ul>")
            items.clear()
    for raw in body.split("\n"):
        line = raw.strip()
        if not line:
            flush()
        elif re.match(r"^[-*] ", line):
            if para:
                flush()
            items.append(line[2:])
        elif line.startswith("#"):
            flush()
            out.append(f"<h4>{md_inline(line.lstrip('#').strip())}</h4>")
        elif items and raw.startswith(("  ", "\t")):
            items[-1] += " " + line
        else:
            if items:
                flush()
            para.append(line)
    flush()
    return "\n".join(out)


def version_of(tag):
    return tag.lstrip("v").split("-")[0]


def changelog_body(rels):
    full = [r for r in rels if not r["prerelease"]]
    betas = [r for r in rels if r["prerelease"]]
    latest = full[0] if full else None
    parts = []

    def card(r, beta=False):
        name = r.get("name") or r["tag"]
        badge = '<span class="pill pill-quiet">Beta</span>' if beta else (
            '<span class="pill">Current</span>' if r is latest else "")
        notes = md_block(r.get("body", "")) or "<p>No notes for this one.</p>"
        return f"""        <article class="rel" id="{attr(r['tag'])}">
          <header class="rel-head">
            <h3>{escape(name, quote=False)}{" " + badge if badge else ""}</h3>
            <time datetime="{r['date'][:10]}">{long_date(r['date'])}</time>
          </header>
          <div class="rel-notes">
{notes}
          </div>
          <a class="rel-link" href="{attr(r['url'])}">Release on GitHub {icon('arrow')}</a>
        </article>"""

    # Betas newer than the current release: grouped by the version they lead to, folded away.
    newer = [b for b in betas if not latest or b["date"] > latest["date"]]
    if newer:
        groups = {}
        for b in newer:
            groups.setdefault(version_of(b["tag"]), []).append(b)
        for ver, bs in groups.items():
            parts.append(f"""      <section class="pg-section" aria-labelledby="beta-{attr(ver)}">
        <h2 id="beta-{attr(ver)}">In beta: {escape(ver)}</h2>
        <p>These builds go to people who turned on Early updates in the app (Glideball › Settings › Updates › Early updates). They become the next release once they've had some use.</p>
        <details class="rel-betas">
          <summary>{len(bs)} beta build{'s' if len(bs) != 1 else ''} of {escape(ver)}, newest first {icon('chevron')}</summary>
          <div class="rel-list">
{chr(10).join(card(b, beta=True) for b in bs)}
          </div>
        </details>
      </section>""")

    old_betas = [b for b in betas if b not in newer]
    parts.append(f"""      <section class="pg-section" aria-labelledby="releases-h">
        <h2 id="releases-h">Releases</h2>
        <div class="rel-list">
{chr(10).join(card(r) for r in full)}
        </div>
      </section>""")
    if old_betas:
        parts.append(f"""      <section class="pg-section">
        <details class="rel-betas">
          <summary>Older beta builds ({len(old_betas)}) {icon('chevron')}</summary>
          <div class="rel-list">
{chr(10).join(card(b, beta=True) for b in old_betas)}
          </div>
        </details>
      </section>""")
    parts.append(f"""      <section class="pg-section prose">
        <p>Glideball was called Glide until 2.8, so the older releases use that name. Every release, with its files and checksums, is on <a href="https://github.com/{REPO}/releases">GitHub</a>.</p>
      </section>""")
    return "\n".join(parts) + "\n", latest


def changelog_page(rels):
    body, latest = changelog_body(rels)
    newest = rels[0]["date"][:10] if rels else date.today().isoformat()
    ver = (latest.get("name") or latest["tag"]).replace("Glideball ", "").replace("Glide ", "") if latest else ""
    meta = {
        "title": "What's New in Glideball",
        "description": (f"Release notes for every version of Glideball, the free Mac app for Kensington trackballs. "
                        f"The current release is {ver}."),
        "path": "/changelog/",
        "crumb": "What's new",
        "nav": "changelog",
        "kicker": "Changelog",
        "h1": "What's new in Glideball",
        "lede": (f"The current release is <strong>{escape(ver)}</strong>. Glideball checks for updates by itself, "
                 "and a button with the new version number shows up at the top of the window when one is out."),
        "updated": newest,
        "source": "scripts/build_pages.py (GitHub releases)",
        "head": f'\n  <link rel="alternate" type="application/atom+xml" title="Glideball releases" href="https://github.com/{REPO}/releases.atom">',
    }
    return meta, body


# ------------------------------------------------------------------ shared nav/footer in hand-written pages
def sync_markers(file, current=None, home=False, footer=True, nav=True):
    full = os.path.join(WEB, file)
    with open(full, encoding="utf-8") as f:
        text = f.read()
    new = text
    if nav:
        new = re.sub(r"(<!-- site-nav -->\n).*?(\n\s*<!-- /site-nav -->)",
                     lambda m: m.group(1) + "  " + nav_html(current, home) + m.group(2), new, flags=re.S)
    if footer:
        new = re.sub(r"(<!-- site-footer -->\n).*?(\n\s*<!-- /site-footer -->)",
                     lambda m: m.group(1) + "  " + footer_html() + m.group(2), new, flags=re.S)
    if "<!-- site-footer -->" not in new and footer:
        print(f"note: {file} has no <!-- site-footer --> markers; left alone")
    if new != text:
        with open(full, "w", encoding="utf-8") as f:
            f.write(new)
        print(f"updated nav/footer in {file}")


# ------------------------------------------------------------------ sitemap
def write_sitemap(built):
    """built: {path: lastmod}. Entries already in the sitemap that this script
    doesn't build (the home page, /feedback/) keep their lastmod."""
    file = os.path.join(WEB, "sitemap.xml")
    existing = {}
    if os.path.exists(file):
        with open(file, encoding="utf-8") as f:
            for loc, mod in re.findall(r"<loc>([^<]+)</loc>\s*<lastmod>([^<]+)</lastmod>", f.read()):
                existing[loc[len(SITE):] if loc.startswith(SITE) else loc] = mod
    merged = dict(existing)
    merged.update(built)
    order = ["/", "/kensingtonworks-alternative/", "/trackballs/", "/help/"]
    paths = sorted(merged, key=lambda p: (order.index(p) if p in order else len(order),
                                          not p.startswith("/help/"), p))
    xml = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
    for p in paths:
        xml += ["  <url>", f"    <loc>{SITE}{p}</loc>", f"    <lastmod>{merged[p]}</lastmod>", "  </url>"]
    xml.append("</urlset>\n")
    text = "\n".join(xml)
    if not os.path.exists(file) or open(file, encoding="utf-8").read() != text:
        with open(file, "w", encoding="utf-8") as f:
            f.write(text)
        print("wrote sitemap.xml")


# ------------------------------------------------------------------ main
def main():
    pages = []
    for dirpath, _, files in os.walk(PAGES):
        for name in sorted(files):
            if name.endswith(".html"):
                pages.append(parse_page(os.path.join(dirpath, name)))
    by_path = {m["path"]: m for m, _ in pages}
    for m, _ in pages:
        if m.get("parent") and m["parent"] not in by_path:
            sys.exit(f"{m['source']}: parent {m['parent']} isn't a page in website/_pages")

    built = {}
    for meta, body in pages:
        write(meta["path"], render(meta, body, trail_for(meta, by_path)))
        if indexed(meta):
            built[meta["path"]] = meta["updated"]

    cmeta, cbody = changelog_page(releases())
    write(cmeta["path"], render(cmeta, cbody, [("Glideball", "/"), (cmeta["crumb"], cmeta["path"])]))
    built[cmeta["path"]] = cmeta["updated"]

    sync_markers("index.html", home=True)
    sync_markers("feedback/index.html", current="feedback")
    sync_markers("404.html")
    write_sitemap(built)


if __name__ == "__main__":
    main()
