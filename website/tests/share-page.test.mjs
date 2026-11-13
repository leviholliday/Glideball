// The shared-setup page (website/s/): its decoder against the shared fixtures
// (docs/SHARE-FORMAT.md), the words it uses, and a scan of its files for anything
// that could turn a payload into markup or code.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateRawSync } from 'node:zlib';
import {
  decodePayload, describeAction, scrollLine, glideballLink, lookColors, summary, cleanText, LIMITS,
} from '../s/share-decode.js';

const here = dirname(fileURLToPath(import.meta.url));
const fixtures = join(here, 'fixtures', 'share');
const site = join(here, '..');

function load(name) {
  return JSON.parse(readFileSync(join(fixtures, name), 'utf8')).cases;
}

async function checkCase(c) {
  const got = await decodePayload(c.d);
  if (c.refuse) {
    assert.equal(got.ok, false, `${c.name}: should be refused`);
    return;
  }
  assert.equal(got.ok, true, `${c.name}: refused (${got.reason})`);
  const s = got.share;
  const e = c.expect;
  assert.deepEqual(s.parts, e.parts, `${c.name}: parts`);
  assert.equal(s.from, e.from ?? null, `${c.name}: from`);
  if ('trackingSpeed' in e) assert.equal(s.pointer?.trackingSpeed, e.trackingSpeed, `${c.name}: pointer speed`);
  if ('scrollMode' in e) assert.equal(s.scrolling?.scroll?.scrollMode, e.scrollMode, `${c.name}: scroll mode`);
  if ('theme' in e) assert.equal(s.look?.theme, e.theme, `${c.name}: theme`);
  if ('apps' in e) assert.deepEqual(s.apps.map((a) => a.bundleID), e.apps, `${c.name}: apps`);
  if ('buttons' in e) {
    const kinds = Object.fromEntries(Object.entries(s.buttons || {}).map(([k, a]) => [k, a.type]));
    assert.deepEqual(kinds, e.buttons, `${c.name}: buttons`);
  }
  // Whatever got through obeys the limits.
  if (s.pointer?.trackingSpeed !== undefined) assert.ok(s.pointer.trackingSpeed >= 0.5 && s.pointer.trackingSpeed <= 80);
  if (s.pointer?.precisionSpeed !== undefined) assert.ok(s.pointer.precisionSpeed >= 0.25 && s.pointer.precisionSpeed <= 3);
  assert.ok(!s.buttons || !('0' in s.buttons), `${c.name}: the primary button was read`);
  assert.ok(!s.from || [...s.from].length <= LIMITS.maxFrom, `${c.name}: name too long`);
  assert.ok((s.chords || []).length <= LIMITS.maxChords);
  for (const a of s.apps) assert.match(a.bundleID, /^[A-Za-z0-9._-]+$/);
  if (s.look?.custom) for (const h of s.look.custom) assert.match(h, /^[0-9A-F]{6}$/);
  for (const h of lookColors(s.look)) assert.match(h, /^[0-9A-F]{6}$/);
  assert.equal(typeof summary(s), 'string');
}

for (const file of ['js-made.json', 'hostile.json']) {
  test(`fixtures: ${file}`, async () => {
    const cases = load(file);
    assert.ok(cases.length > 5);
    for (const c of cases) await checkCase(c);
  });
}

test('fixtures: swift-made.json (made by the Mac app)', async (t) => {
  if (!existsSync(join(fixtures, 'swift-made.json'))) {
    t.skip('not made yet: scripts/import-sim/run.sh --write-fixtures');
    return;
  }
  const cases = load('swift-made.json');
  for (const c of cases) await checkCase(c);
});

test('a share right at the inflate cap is refused, just under it is read', async () => {
  const json = JSON.stringify({ format: 'glideball-share', version: 1, kind: 'parts', parts: ['pointer'], trackingSpeed: 4 });
  const pad = (n) => Buffer.from(json + ' '.repeat(n - json.length));
  const d = (buf) => deflateRawSync(buf, { level: 9 }).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  assert.equal((await decodePayload(d(pad(65_535)))).ok, true);
  assert.equal((await decodePayload(d(pad(65_536)))).ok, false);
});

test('the app’s words', () => {
  assert.equal(describeAction({ type: 'shortcut', keyCode: 8, modifiers: 1048576, keyName: 'C' }), 'Copy (⌘C)');
  assert.equal(describeAction({ type: 'holdShortcut', keyCode: 49, modifiers: 262144, keyName: 'Space' }), 'Wispr Flow (⌃Space)');
  assert.equal(describeAction({ type: 'holdShortcut', keyCode: 1, modifiers: 1048576 | 524288, keyName: 'S' }), 'Hold ⌥⌘S');
  assert.equal(describeAction({ type: 'shortcut', keyCode: 1, modifiers: 262144 | 131072, keyName: 'K' }), '⌃⇧K');
  assert.equal(describeAction({ type: 'system' }, 1), 'Right click');
  assert.equal(describeAction({ type: 'system' }, 5), 'Default');
  assert.equal(describeAction({ type: 'modifiedClick', button: 0, modifiers: 262144 }), 'Control-click');
  assert.equal(describeAction({ type: 'openApp', bundleID: 'com.apple.Notes' }), 'Open com.apple.Notes');
  assert.equal(describeAction({ type: 'gesture', steps: {
    up: { action: { type: 'shortcut', keyCode: 126, modifiers: 262144, keyName: '↑' } },
    left: { action: { type: 'media', key: 18 } },
  }, tap: { type: 'media', key: 16 } }), 'Gesture: ↑ Mission Control (⌃↑), ← Previous Track, tap: Play or Pause');
  const s = { scrollMode: 'flywheel', flyGlide: 0.35, flyDistance: 4, nativeScrollSpeed: 0.5, scrollDistance: 14 };
  assert.equal(scrollLine(s), 'Flywheel, glide 81 ms, 4 pt a slow turn');
  assert.equal(scrollLine({ ...s, scrollMode: 'follow' }), 'Follow, 14 pt a tick');
  assert.equal(scrollLine({ ...s, scrollMode: 'native' }), 'Native, speed 0.50');
  assert.equal(cleanText('  a\u0000b​c\u2028  ', 10), 'abc');
});

test('the glideball:// link is built only from a clean payload', () => {
  assert.equal(glideballLink('abc_-09'), 'glideball://import?d=abc_-09');
  for (const bad of ['', 'a b', 'a"onload', 'javascript:x', '<x>', 'A'.repeat(2049), null, 42]) assert.equal(glideballLink(bad), null);
});

test('the page never turns text into markup or code', () => {
  const dir = join(site, 's');
  for (const f of readdirSync(dir).filter((n) => n.endsWith('.js'))) {
    const src = readFileSync(join(dir, f), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
    for (const bad of [/\.innerHTML/, /\.outerHTML/, /insertAdjacentHTML/, /document\.write/, /\beval\s*\(/, /new\s+Function/,
      /setAttribute\(\s*['"](style|on\w+|href|src)/i, /\.style\.(?!setProperty)\w+\s*=/, /createContextualFragment/, /DOMParser/]) {
      assert.doesNotMatch(src, bad, `${f} uses ${bad}`);
    }
  }
  const html = readFileSync(join(dir, 'index.html'), 'utf8');
  assert.doesNotMatch(html, /\sstyle\s*=/i, 'inline style= in s/index.html');
  assert.doesNotMatch(html, /\son[a-z]+\s*=/i, 'inline on*= in s/index.html');
  for (const m of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
    assert.equal(m[2].trim(), '', 'inline script in s/index.html');
    assert.match(m[1], /src="\/[^"]+"/, 'a script that isn’t one of the site’s files');
  }
  assert.match(html, /<meta name="robots" content="noindex/);
  assert.match(html, /<meta name="referrer" content="no-referrer">/);
});

test('/s/ is kept out of search and analytics', () => {
  const toml = readFileSync(join(site, 'netlify.toml'), 'utf8');
  const block = toml.split('[[headers]]').find((b) => /for = "\/s\/\*"/.test(b));
  assert.ok(block, 'no headers for /s/*');
  assert.match(block, /X-Robots-Tag = "noindex, nofollow"/);
  assert.match(block, /Referrer-Policy = "no-referrer"/);
  assert.match(block, /script-src 'self';/);
  assert.match(block, /connect-src 'none'/);
  assert.doesNotMatch(readFileSync(join(site, 'sitemap.xml'), 'utf8'), /\/s\//);
});
