#!/usr/bin/env python3
"""Checks Glide's translations against the strings in the code.

    scripts/l10n/check.py                 report every language; exit 1 on problems
    scripts/l10n/check.py --lang de       just one language
    scripts/l10n/check.py --keys          list every key the code uses (and where)
    scripts/l10n/check.py --json FILE     write the keys, comments and locations as JSON
    scripts/l10n/check.py --audit         list string literals that look like UI text
                                          but aren't localized (to catch misses)

What counts as a key (see README.md next to this file):
  * the first unlabeled string literal of SwiftUI initializers and modifiers
    that take a LocalizedStringKey: Text("…"), Button("…"), .help("…")…
  * String(localized: "…"), LocalizedStringKey("…"), LocalizedStringResource("…")
  * literals passed to Glide's own components where they take a
    LocalizedStringKey (COMPONENTS below), e.g. GlassCard(title: "…")
Literals in a ternary (`a ? "x" : "y"`) count; literals inside nested calls or
closures are checked by their own call. Interpolations become format
specifiers the way Swift builds the key: Int → %lld, Double → %lf, anything
else (String, formatted numbers, dates, Text) → %@, and a literal "%" becomes
"%%" once there's an interpolation. Swift's types aren't visible here, so Int
interpolations are recognized by shape (INT_PATTERNS): Int(…), ….count, or a
name in INT_NAMES. Keep Int interpolations in one of those shapes (or add the
name), and format Doubles to a String first (they should be locale-formatted
anyway).

Problems that fail the check: a key missing from a language, a translation
whose format specifiers don't match the key's (count, types and order — a
translation may reorder them with %1$@, %2$lld…), and files that don't parse.
Unused translations are reported but don't fail it.

Python 3 standard library only, plus /usr/bin/plutil.
"""
from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "Sources"
RESOURCES = ROOT / "Resources"
LANGUAGES = ["es", "fr", "de", "it", "pt-BR", "ja", "ko", "zh-Hans"]
DEVELOPMENT = "en"

# SwiftUI / Charts calls whose first unlabeled argument is a LocalizedStringKey.
SWIFTUI_CALLS = {
    "Text", "Button", "Label", "Toggle", "Section", "Menu", "Picker", "TextField",
    "SecureField", "Link", "LabeledContent", "ContentUnavailableView", "Tab",
    "SharePreview", "help", "accessibilityLabel", "accessibilityHint",
    "accessibilityValue", "navigationTitle", "confirmationDialog", "alert",
    "chartXAxisLabel", "chartYAxisLabel", "value",
    "LocalizedStringKey", "LocalizedStringResource",
}

# Glide's own views and helpers that take a LocalizedStringKey: call name →
# argument labels (or positions, for unlabeled arguments) that are localized.
COMPONENTS: dict[str, set] = {
    "GlassCard": {"title"},
    "TuningSlider": {"title", "lowLabel", "highLabel"},
    "ToggleRow": {"title", "subtitle"},
    "StatusPill": {"text"},
    "ModePill": {"text"},
    "StatTile": {"title"},
    "OverrideSection": {"title"},
    "caption": {0},                      # OverviewView
    "legend": {0, "text"},               # OverviewView, PointerView
    "labeled": {0},                      # FeedbackView
    "sendButton": {"title"},             # FeedbackView
    "permissionButton": {"on", "off"},   # RootView
    "header": {1, 2},                    # WelcomeTourView
    "feature": {1},                      # WelcomeTourView
    "permissionRow": {0, "detail"},      # WelcomeTourView
}

# Interpolations that are Int (→ %lld). Everything else is %@ unless it has
# `specifier:`. Matched against the whole interpolated expression.
INT_NAMES = {
    "n", "i", "b", "pct", "more", "remapped", "code", "maxAttachments",
}
INT_PATTERNS = [
    r"Int\(.*\)",                        # Int(x) — but not Int(x).formatted(): see specifier()
    r".*\.count",                        # things.count
    r".*\.count\s*[-+]\s*\d+",
    r"[\w.]+\s*[-+]\s*1",                # index + 1, step.rawValue + 1
    r".*maxUserFiles",
    r"limit\s*/\s*1_000_000",
    r"v\.as\(Int\.self\)\s*\?\?\s*0",
]
# A few names are Int in one file and something else in another.
FILE_INT_NAMES = {
    "Config.swift": {"version"},
}

IGNORE_MARK = "l10n:ignore"


# ---------------------------------------------------------------- Swift scanning

class Literal:
    def __init__(self, segments, start, end, line):
        self.segments = segments    # list of str (text) or ("interp", expr)
        self.start, self.end, self.line = start, end, line

    @property
    def has_interpolation(self):
        return any(isinstance(s, tuple) for s in self.segments)


ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}


def scan_string(src: str, i: int):
    """Parses a string literal starting at src[i] (a quote, or # for raw).
    Returns (Literal-like segments, end index)."""
    hashes = 0
    while src[i] == "#":
        hashes += 1
        i += 1
    multiline = src.startswith('"""', i)
    i += 3 if multiline else 1
    close = ('"""' if multiline else '"') + "#" * hashes
    esc = "\\" + "#" * hashes
    segments, buf = [], []
    while i < len(src):
        if src.startswith(close, i):
            i += len(close)
            break
        if src.startswith(esc, i):
            j = i + len(esc)
            c = src[j]
            if c == "(":
                depth, k = 1, j + 1
                while k < len(src) and depth:
                    ch = src[k]
                    if ch == '"' or (ch == "#" and src[k:k + 2] in ('#"', "##")):
                        _, k = scan_string(src, k)
                        continue
                    if ch == "(":
                        depth += 1
                    elif ch == ")":
                        depth -= 1
                    k += 1
                if buf:
                    segments.append("".join(buf))
                    buf = []
                segments.append(("interp", src[j + 1:k - 1]))
                i = k
                continue
            if c == "u" and src[j + 1] == "{":
                k = src.index("}", j)
                buf.append(chr(int(src[j + 2:k], 16)))
                i = k + 1
                continue
            if c == "\n":   # line continuation in multi-line strings
                i = j + 1
                continue
            buf.append(ESCAPES.get(c, c))
            i = j + 1
            continue
        buf.append(src[i])
        i += 1
    if buf:
        segments.append("".join(buf))
    # (Multi-line strings keep their indentation here; they're never keys.)
    return segments, i


def strip_comments(src: str) -> str:
    """Blanks out comments (keeping offsets and newlines) so they're never scanned."""
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '"' or (c == "#" and src[i:i + 2] in ('#"', "##")):
            _, j = scan_string(src, i)
            i = j
            continue
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j == -1 else j
            if IGNORE_MARK not in src[i:j]:
                for k in range(i, j):
                    out[k] = " "
            i = j
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j == -1 else j + 2
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
            continue
        i += 1
    return "".join(out)


IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


class Call:
    def __init__(self, name, open_idx, close_idx):
        self.name, self.open, self.close = name, open_idx, close_idx


def find_calls(src: str):
    """Every `name(` … `)` in the file, with balanced parentheses, skipping strings."""
    calls, stack = [], []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '"' or (c == "#" and src[i:i + 2] in ('#"', "##")):
            _, i = scan_string(src, i)
            continue
        if c == "(":
            j = i - 1
            while j >= 0 and src[j] in " \t":
                j -= 1
            k = j
            while k >= 0 and (src[k].isalnum() or src[k] == "_"):
                k -= 1
            name = src[k + 1:j + 1] if j >= 0 and j != k else ""
            # Generic call: `Name<T>(`… not used for keys; ignore.
            stack.append((name, i))
        elif c == ")":
            if stack:
                name, start = stack.pop()
                if name:
                    calls.append(Call(name, start, i))
        i += 1
    return calls


def split_args(src: str, open_idx: int, close_idx: int):
    """Top-level arguments of a call: list of (label or None, start, end)."""
    args, depth, start = [], 0, open_idx + 1
    i = open_idx + 1
    while i < close_idx:
        c = src[i]
        if c == '"' or (c == "#" and src[i:i + 2] in ('#"', "##")):
            _, i = scan_string(src, i)
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            args.append((start, i))
            start = i + 1
        i += 1
    if src[start:close_idx].strip():
        args.append((start, close_idx))
    out = []
    for s, e in args:
        text = src[s:e]
        m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*:(?!:)", text)
        # `a ? b : c` has no label: a label is the very first thing in the argument.
        if m and not re.match(r"\s*[A-Za-z_][A-Za-z0-9_.]*\s*\?", text):
            out.append((m.group(1), s + m.end(), e))
        else:
            out.append((None, s, e))
    return out


def top_level_literals(src: str, s: int, e: int):
    """String literals directly in an argument (also in ternaries), not inside
    nested calls, subscripts or closures."""
    lits, depth, i = [], 0, s
    while i < e:
        c = src[i]
        if c == '"' or (c == "#" and src[i:i + 2] in ('#"', "##")):
            segs, j = scan_string(src, i)
            if depth == 0:
                lits.append(Literal(segs, i, j, src.count("\n", 0, i) + 1))
            i = j
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        i += 1
    return lits


# ---------------------------------------------------------------- keys

def closing_paren(text: str, open_idx: int) -> int:
    depth = 0
    for i in range(open_idx, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return i
    return -1


def specifier(expr: str, filename: str) -> str:
    e = expr.strip()
    m = re.search(r',\s*specifier:\s*"([^"]+)"', e)
    if m:
        return m.group(1)
    if re.search(r",\s*(format|style):", e):
        return "%@"
    if e.startswith("Int(") and closing_paren(e, 3) != len(e) - 1:
        return "%@"      # Int(x).formatted(), Int(x).description…: a String
    if re.search(r"\.(formatted|description|display\w*|title|name)\b[^.]*$", e):
        return "%@"
    names = INT_NAMES | FILE_INT_NAMES.get(filename, set())
    if e in names or any(re.fullmatch(p, e) for p in INT_PATTERNS):
        return "%lld"
    return "%@"


def key_for(lit: Literal, filename: str) -> str:
    if not lit.has_interpolation:
        return "".join(lit.segments)
    out = []
    for s in lit.segments:
        if isinstance(s, tuple):
            out.append(specifier(s[1], filename))
        else:
            out.append(s.replace("%", "%%"))
    return "".join(out)


def is_placeholder_only(key: str) -> bool:
    return re.fullmatch(r"(\s|%[-+ #0-9.$]*(lld|ld|llu|lu|lf|d|u|f|@|%))*", key) is not None


def extract_keys():
    """key → {"comments": set, "where": [file:line]}"""
    keys: dict[str, dict] = {}
    for path in sorted(SOURCES.rglob("*.swift")):
        raw = path.read_text(encoding="utf-8")
        src = strip_comments(raw)
        lines = raw.split("\n")
        rel = path.relative_to(ROOT)
        for call in find_calls(src):
            wanted: set | None = None
            comment = None
            if call.name == "String":
                args = split_args(src, call.open, call.close)
                if not args or args[0][0] != "localized":
                    continue
                for label, s, e in args:
                    if label == "comment":
                        lits = top_level_literals(src, s, e)
                        comment = "".join(x for x in lits[0].segments if isinstance(x, str)) if lits else None
                wanted = {"localized"}
            elif call.name in SWIFTUI_CALLS:
                wanted = {0}
                args = split_args(src, call.open, call.close)
                # Only the first argument, and only if it's unlabeled.
                args = args[:1]
            elif call.name in COMPONENTS:
                wanted = COMPONENTS[call.name]
                args = split_args(src, call.open, call.close)
            else:
                continue
            position = 0
            for label, s, e in args:
                this = label if label is not None else position
                if label is None:
                    position += 1
                if this not in wanted:
                    continue
                for lit in top_level_literals(src, s, e):
                    line = src.count("\n", 0, lit.start) + 1
                    if IGNORE_MARK in lines[line - 1]:
                        continue
                    key = key_for(lit, path.name)
                    if not key.strip() or is_placeholder_only(key):
                        continue
                    entry = keys.setdefault(key, {"comments": set(), "where": []})
                    if comment:
                        entry["comments"].add(comment)
                    entry["where"].append(f"{rel}:{line}")
    return keys


# ---------------------------------------------------------------- translations

def lint(path: Path) -> str | None:
    r = subprocess.run(["/usr/bin/plutil", "-lint", str(path)], capture_output=True, text=True)
    return None if r.returncode == 0 else (r.stdout + r.stderr).strip()


def load_strings(path: Path) -> dict[str, str]:
    r = subprocess.run(["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise ValueError(r.stderr.strip())
    return json.loads(r.stdout) if r.stdout.strip() else {}


def load_stringsdict(path: Path) -> dict[str, dict]:
    with open(path, "rb") as f:
        return plistlib.load(f)


SPEC = re.compile(r"%(?:(\d+)\$)?(?:(#@\w+@)|[-+ #0]*\d*(?:\.\d+)?(lld|ld|llu|lu|lf|hhd|hd|d|u|f|@|%))")


def kind_of(m: re.Match) -> str:
    return m.group(2) or m.group(3)


def specifiers(text: str):
    """The argument types a format uses, in argument order: ['@', 'lld', …]."""
    by_pos, nxt = {}, 1
    for m in SPEC.finditer(text):
        kind = kind_of(m)
        if kind == "%":
            continue
        pos = int(m.group(1)) if m.group(1) else nxt
        if not m.group(1):
            nxt += 1
        by_pos[pos] = kind
    return [by_pos.get(i) for i in range(1, max(by_pos, default=0) + 1)]


def normalize(kinds):
    alias = {"ld": "lld", "lu": "llu", "d": "d", "hd": "d", "hhd": "d"}
    return [alias.get(k, k) for k in kinds]


def stringsdict_problems(key: str, entry: dict) -> list[str]:
    """Checks one .stringsdict entry against its key's specifiers."""
    problems = []
    fmt = entry.get("NSStringLocalizedFormatKey")
    if not isinstance(fmt, str):
        return ["no NSStringLocalizedFormatKey"]
    want = normalize(specifiers(key))
    # Expand each %#@var@ to its variable's value type.
    got, nxt = {}, 1
    for m in SPEC.finditer(fmt):
        kind = kind_of(m)
        if kind == "%":
            continue
        pos = int(m.group(1)) if m.group(1) else nxt
        if not m.group(1):
            nxt += 1
        if kind.startswith("#@"):
            var = entry.get(kind[2:-1])
            if not isinstance(var, dict):
                problems.append(f"variable {kind[2:-1]!r} is missing")
                continue
            vt = var.get("NSStringFormatValueTypeKey", "")
            got[pos] = vt
            for rule in ("zero", "one", "two", "few", "many", "other"):
                text = var.get(rule)
                if text is None:
                    continue
                inner = [k for k in normalize(specifiers(text)) if k]
                # A variant may show the number (with the variable's type) or not.
                bad = [k for k in inner if k not in (normalize([vt])[0], *want)]
                if bad:
                    problems.append(f"{kind[2:-1]}.{rule} uses %{bad[0]}")
            if "other" not in var:
                problems.append(f"{kind[2:-1]} has no 'other' form")
        else:
            got[pos] = kind
    have = normalize([got.get(i) for i in range(1, max(got, default=0) + 1)])
    if have != want:
        problems.append(f"specifiers {have} ≠ key's {want}")
    return problems


def check_language(lang: str, keys: dict, plural_keys: set) -> tuple[int, list[str]]:
    lproj = RESOURCES / f"{lang}.lproj"
    report, failures = [], 0
    strings_path, dict_path = lproj / "Localizable.strings", lproj / "Localizable.stringsdict"
    table: dict[str, str] = {}
    plurals: dict[str, dict] = {}
    for p in (strings_path, dict_path):
        if p.exists():
            err = lint(p)
            if err:
                failures += 1
                report.append(f"  ✗ {p.relative_to(ROOT)} doesn't parse: {err}")
    if strings_path.exists():
        try:
            table = load_strings(strings_path)
        except ValueError as e:
            failures += 1
            report.append(f"  ✗ {strings_path.relative_to(ROOT)}: {e}")
    if dict_path.exists():
        try:
            plurals = load_stringsdict(dict_path)
        except Exception as e:  # noqa: BLE001
            failures += 1
            report.append(f"  ✗ {dict_path.relative_to(ROOT)}: {e}")

    wanted = set(plural_keys) if lang == DEVELOPMENT else set(keys)
    missing = sorted(k for k in wanted if k not in table and k not in plurals)
    if lang != DEVELOPMENT:
        missing_plurals = sorted(k for k in plural_keys if k not in plurals and k in table)
        for k in missing_plurals:
            report.append(f"  ! {k!r} is a plural in English but a plain string here (fine if this language doesn't inflect)")
    unused = sorted(k for k in (set(table) | set(plurals)) if k not in keys)

    mismatched = []
    for k, v in table.items():
        if k in keys and normalize(specifiers(v)) != normalize(specifiers(k)):
            mismatched.append(f"{k!r} → {v!r}: {normalize(specifiers(v))} ≠ {normalize(specifiers(k))}")
    for k, entry in plurals.items():
        if k in keys:
            for p in stringsdict_problems(k, entry):
                mismatched.append(f"{k!r} (stringsdict): {p}")

    for k in missing:
        report.append(f"  ✗ missing: {k!r}   ({keys[k]['where'][0]})" if k in keys else f"  ✗ missing plural: {k!r}")
    for m in mismatched:
        report.append(f"  ✗ format mismatch: {m}")
    for k in unused:
        report.append(f"  · unused: {k!r}")
    failures += len(missing) + len(mismatched)
    total = len(wanted)
    done = total - len(missing)
    head = f"{lang:8} {done}/{total} keys" + (f", {len(mismatched)} mismatched" if mismatched else "") \
        + (f", {len(unused)} unused" if unused else "")
    return failures, [head] + report


# ---------------------------------------------------------------- audit

LOOKS_LIKE_UI = re.compile(r"[A-Za-z]{2,}.*\s.*[A-Za-z]|^[A-Z][a-z]+…?$")
AUDIT_SKIP = re.compile(
    r"diagnostics\??\.record|NSLog|forKey|forHTTPHeaderField|UserDefaults|systemName|systemImage|"
    r"Notification|DispatchQueue\(label|URL\(string|appendingPathComponent|Process|arguments|"
    r"queryItems|request\(|\.init\(name: \"|json\[|info\?\[|\[\"|hasPrefix|hasSuffix|"
    r"range\(of|NSSound|Bundle\.main\.url|frameAutosaveName|setFrame|Logger|print\(|"
    r"verbatim:|accessibilityDescription|keyEquivalent|withExtension|forResource|kHISymbolic|"
    r"case \"|== \"|!= \"|fatalError|precondition|assert")


def audit(keys: dict):
    known = set()
    for entry in keys.values():
        known.update(entry["where"])
    for path in sorted(SOURCES.rglob("*.swift")):
        raw = path.read_text(encoding="utf-8")
        src = strip_comments(raw)
        lines = raw.split("\n")
        i = 0
        while i < len(src):
            c = src[i]
            if c == '"' or (c == "#" and src[i:i + 2] in ('#"', "##")):
                segs, j = scan_string(src, i)
                line = src.count("\n", 0, i) + 1
                text = "".join(s if isinstance(s, str) else "…" for s in segs)
                where = f"{path.relative_to(ROOT)}:{line}"
                code = lines[line - 1]
                if (where not in known and LOOKS_LIKE_UI.search(text) and not AUDIT_SKIP.search(code)
                        and IGNORE_MARK not in code and "localized:" not in code):
                    print(f"{where}: {text!r}")
                i = j
                continue
            i += 1


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lang", action="append", help="check only this language (repeatable)")
    ap.add_argument("--keys", action="store_true", help="list the keys the code uses")
    ap.add_argument("--json", metavar="FILE", help="write keys, comments and locations as JSON")
    ap.add_argument("--audit", action="store_true", help="list literals that look like unlocalized UI text")
    ap.add_argument("--quiet", action="store_true", help="only the summary line per language")
    args = ap.parse_args()

    keys = extract_keys()
    if args.keys:
        for k in sorted(keys, key=str.lower):
            print(f"{k!r}\t{keys[k]['where'][0]}")
        print(f"{len(keys)} keys", file=sys.stderr)
        return 0
    if args.json:
        Path(args.json).write_text(json.dumps(
            {k: {"comments": sorted(v["comments"]), "where": v["where"]} for k, v in sorted(keys.items())},
            ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"wrote {len(keys)} keys to {args.json}")
        return 0
    if args.audit:
        audit(keys)
        return 0

    en_dict = RESOURCES / f"{DEVELOPMENT}.lproj" / "Localizable.stringsdict"
    plural_keys = set(load_stringsdict(en_dict)) if en_dict.exists() else set()
    stale = sorted(k for k in plural_keys if k not in keys)

    failures = 0
    print(f"{len(keys)} keys in the code ({len(plural_keys)} with plural forms)")
    for k in stale:
        print(f"  · en plural not used by the code: {k!r}")
    for lang in [DEVELOPMENT] + LANGUAGES:
        if args.lang and lang not in args.lang:
            continue
        f, lines = check_language(lang, keys, plural_keys)
        failures += f
        print(lines[0])
        if not args.quiet:
            for line in lines[1:]:
                print(line)
    if failures:
        print(f"\n✗ {failures} problem(s)")
        return 1
    print("\n✓ all languages complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
