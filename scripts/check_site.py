#!/usr/bin/env python3
"""Checks the website's pages before a deploy:
  - every internal link and asset points at something that exists,
  - every #anchor exists on the page it points at,
  - every JSON-LD block parses,
  - no inline style= or on*= attributes, and no inline scripts other than JSON-LD
    (the Content-Security-Policy in website/netlify.toml would block them).

    python3 scripts/check_site.py
"""
import json
import os
import re
import sys
from html.parser import HTMLParser
from urllib.parse import urljoin

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "website"))
SKIP_DIRS = {"node_modules", "_pages", "netlify", "admin"}
# Added at runtime by the analytics notice (a Netlify snippet), so not in the files.
RUNTIME_IDS = {"cg-website-privacy", "cg-analytics-settings"}


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links, self.assets, self.ids, self.ld, self.bad = [], [], set(), [], []
        self._script = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if a.get("id"):
            self.ids.add(a["id"])
        for k in a:
            if k == "style" or k.startswith("on"):
                self.bad.append(f"inline {k}= on <{tag}>")
        if tag == "a" and a.get("href"):
            self.links.append(a["href"])
        if tag in ("img", "script", "source", "link") and (a.get("src") or (tag == "link" and a.get("rel") in ("stylesheet", "icon", "apple-touch-icon", "preload"))):
            self.assets.append(a.get("src") or a.get("href"))
        if a.get("srcset"):
            self.assets += [s.strip().split()[0] for s in a["srcset"].split(",") if s.strip()]
        if tag == "script":
            self._script = a
            self._buf = []

    def handle_data(self, data):
        if self._script is not None:
            self._buf.append(data)

    def handle_endtag(self, tag):
        if tag == "script" and self._script is not None:
            body = "".join(self._buf).strip()
            if self._script.get("type") == "application/ld+json":
                self.ld.append(body)
            elif body:
                self.bad.append("inline <script>")
            self._script = None


pages = {}
for dirpath, dirs, files in os.walk(ROOT):
    dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
    for f in files:
        if f.endswith(".html"):
            rel = "/" + os.path.relpath(os.path.join(dirpath, f), ROOT).replace(os.sep, "/")
            url = rel[: -len("index.html")] if rel.endswith("/index.html") else rel
            p = Page()
            with open(os.path.join(dirpath, f), encoding="utf-8") as fh:
                p.feed(fh.read())
            pages[url] = p


def exists(path):
    path = path.split("?")[0]
    full = os.path.join(ROOT, path.lstrip("/"))
    if path.endswith("/"):
        return os.path.isfile(os.path.join(full, "index.html"))
    return os.path.isfile(full)


with open(os.path.join(ROOT, "netlify.toml"), encoding="utf-8") as fh:
    redirects = set(re.findall(r'from = "([^"]+)"', fh.read()))

problems = []
for url, p in sorted(pages.items()):
    problems += [f"{url}: {b}" for b in p.bad]
    for i, block in enumerate(p.ld):
        try:
            json.loads(block)
        except ValueError as e:
            problems.append(f"{url}: JSON-LD block {i + 1} doesn't parse: {e}")
    for href in p.links:
        if href.startswith(("http://", "https://", "mailto:")):
            continue
        path, _, frag = href.partition("#")
        path = urljoin(url, path.split("?")[0]) if path else url
        if path in redirects:
            continue
        if not exists(path):
            problems.append(f"{url}: broken link {href}")
            continue
        if frag:
            target = pages.get(path)
            if target is not None and frag not in target.ids and frag not in RUNTIME_IDS:
                problems.append(f"{url}: #{frag} isn't on {path}")
    for a in p.assets:
        if not a or a.startswith(("http", "data:")):
            continue
        if not exists(urljoin(url, a)):
            problems.append(f"{url}: missing asset {a}")

for line in problems:
    print(line)
print(f"{len(pages)} pages, {sum(len(p.links) for p in pages.values())} links, {len(problems)} problems")
sys.exit(1 if problems else 0)
