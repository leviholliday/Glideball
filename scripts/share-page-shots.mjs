#!/usr/bin/env node
// Screenshots of the shared-setup page (website/s/) with a few payloads, at 1440
// and 390 wide, full page, through headless Chrome (no window). Serves website/
// on 127.0.0.1 itself; nothing leaves this Mac.
//
//   node scripts/share-page-shots.mjs [out-dir]     (default: build/share-page-shots)
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join, extname, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateRawSync } from 'node:zlib';
import { tmpdir } from 'node:os';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const site = join(repo, 'website');
const out = resolve(process.argv[2] || join(repo, 'build', 'share-page-shots'));
const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
await mkdir(out, { recursive: true });

const pack = (o) => deflateRawSync(Buffer.from(JSON.stringify(o))).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const CMD = 1048576, CTRL = 262144;
const sc = (keyCode, keyName, modifiers) => ({ shortcut: { _0: { keyCode, modifiers, keyName } } });
const scroll = { scrollMode: 'flywheel', nativeScrollSpeed: 0.5, flyDistance: 6, flyAcceleration: 0.7, flyGlide: 0.55, flyReach: 0.6,
  smoothScrolling: true, scrollDistance: 14, scrollSmoothness: 0.4, scrollAcceleration: 0.5, throwEnabled: true, throwAmount: 0.4,
  reverseScroll: false, shiftScrollsHorizontally: true };
const media = { gesture: { _0: { up: { action: { media: { _0: 0 } }, repeats: true }, down: { action: { media: { _0: 1 } }, repeats: true },
  left: { action: { media: { _0: 18 } }, repeats: false }, right: { action: { media: { _0: 17 } }, repeats: false }, tap: { media: { _0: 16 } } } } };
const spaces = { gesture: { _0: { up: { action: sc(126, '↑', CTRL), repeats: false }, down: { action: sc(125, '↓', CTRL), repeats: false },
  left: { action: sc(123, '←', CTRL), repeats: false }, right: { action: sc(124, '→', CTRL), repeats: false }, tap: { system: {} } } } };
const base = { format: 'glideball-share', version: 2, kind: 'parts', writtenBy: '2.10-beta.13' };

const shots = {
  everything: pack({ ...base, from: 'Levi',
    parts: ['pointer', 'scrolling', 'buttons', 'combos', 'gestures', 'app:com.apple.Safari', 'app:com.apple.dt.Xcode', 'look', 'sounds'],
    trackingSpeed: 9.5, precisionSpeed: 0.75, scroll, ballScrollSpeed: 1.5,
    buttons: { 1: { rightClick: {} }, 2: sc(8, 'C', CMD), 3: media, 4: { system: {} }, 5: { system: {} }, 6: { system: {} }, 7: { system: {} } },
    chords: [{ buttons: [2, 3], action: { openApp: { bundleID: 'com.apple.Notes' } } }, { buttons: [0, 1], action: sc(126, '↑', CTRL) }],
    gesturesEnabled: true, gestureDistance: 'normal', gestureSteadyHands: false,
    apps: [{ bundleID: 'com.apple.Safari', name: 'Safari', trackingSpeed: 6, buttons: { 2: { back: {} }, 3: { forward: {} } } },
      { bundleID: 'com.apple.dt.Xcode', name: 'Xcode', scroll: { ...scroll, scrollMode: 'follow', scrollDistance: 22 } }],
    look: { theme: 'custom', custom: ['FFE070', '2EC99A', '2B3A9E'] },
    sounds: { on: true, volume: 0.6, kinds: { pauseResume: true, modes: true, ticks: false, milestones: true, buttons: true } } }),
  'scroll-beta12': pack({ format: 'glideball-share', version: 1, kind: 'scrolling', writtenBy: '2.10-beta.12',
    scroll: { ...scroll, scrollMode: 'follow', scrollDistance: 22, throwAmount: 0.7 }, ballScrollSpeed: 1 }),
  buttons: pack({ ...base, from: 'Sam <script>alert(1)</script>', parts: ['buttons', 'combos', 'gestures', 'look'],
    buttons: { 1: { rightClick: {} }, 2: spaces, 3: sc(13, 'W', CMD), 4: { system: {} }, 5: { back: {} }, 6: { system: {} }, 7: { system: {} } },
    chords: [{ buttons: [2, 3], action: { holdShortcut: { _0: { keyCode: 49, modifiers: CTRL, keyName: 'Space' } } } }],
    gesturesEnabled: true, gestureDistance: 'short', gestureSteadyHands: true, look: { theme: 'ember' } }),
  invalid: 'not-a-real-payload_' + 'A'.repeat(40),
  empty: '',
};

const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.svg': 'image/svg+xml',
  '.png': 'image/png', '.webp': 'image/webp', '.ico': 'image/x-icon' };
const server = createServer(async (req, res) => {
  let path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (path.endsWith('/')) path += 'index.html';
  const file = join(site, path);
  if (!file.startsWith(site) || !existsSync(file)) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'content-type': types[extname(file)] || 'application/octet-stream' });
  res.end(await readFile(file));
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const origin = `http://127.0.0.1:${server.address().port}`;

const profile = join(tmpdir(), `glide-shots-${process.pid}`);
const proc = spawn(chrome, ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--hide-scrollbars',
  '--no-first-run', '--no-default-browser-check', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const wsURL = await new Promise((resolveURL, reject) => {
  let buf = '';
  proc.stderr.on('data', (d) => { buf += d; const m = buf.match(/ws:\/\/[^\s]+/); if (m) resolveURL(m[0]); });
  setTimeout(() => reject(new Error('Chrome did not start')), 15000);
});
const targets = await (await fetch(wsURL.replace('ws://', 'http://').replace(/\/devtools\/.*/, '/json'))).json();
const page = targets.find((t) => t.type === 'page');
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r, { once: true }));
let id = 0;
const waiting = new Map();
ws.addEventListener('message', (e) => {
  const m = JSON.parse(e.data);
  if (m.id && waiting.has(m.id)) { waiting.get(m.id)(m); waiting.delete(m.id); }
});
const send = (method, params = {}) => new Promise((r) => { const n = ++id; waiting.set(n, r); ws.send(JSON.stringify({ id: n, method, params })); });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

for (const [name, d] of Object.entries(shots)) {
  for (const width of [1440, 390]) {
    await send('Emulation.setDeviceMetricsOverride', { width, height: width === 390 ? 844 : 900, deviceScaleFactor: width === 390 ? 2 : 1, mobile: width === 390 });
    await send('Page.navigate', { url: 'about:blank' });
    await sleep(100);
    await send('Page.navigate', { url: `${origin}/s/${d ? '#' + d : ''}` });
    await sleep(1200);
    const { result } = await send('Runtime.evaluate', { expression: 'JSON.stringify([document.documentElement.scrollHeight, document.documentElement.scrollWidth])', returnByValue: true });
    const [h, w] = JSON.parse(result.result.value);
    if (w > width) console.log(`! ${name} at ${width}: the page is ${w} px wide`);
    const shot = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true, clip: { x: 0, y: 0, width, height: h, scale: 1 } });
    const file = join(out, `${name}-${width}.png`);
    await writeFile(file, Buffer.from(shot.result.data, 'base64'));
    console.log(`${file} (${width}×${h})`);
  }
}
ws.close();
proc.kill();
server.close();
