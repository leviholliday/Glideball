// Writes the shared-setup fixtures made on the JavaScript side (docs/SHARE-FORMAT.md):
//   tests/fixtures/share/js-made.json   good shares, compressed with Node's zlib
//   tests/fixtures/share/hostile.json   shares both decoders must refuse, or accept only cleaned and clamped
// Both the page's decoder (tests/share-page.test.mjs) and the Mac app's
// (scripts/import-sim) check them. Run from website/: node tests/make-share-fixtures.mjs
import { deflateRawSync } from 'node:zlib';
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, 'fixtures', 'share');
mkdirSync(out, { recursive: true });

const b64url = (buf) => Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const pack = (obj) => b64url(deflateRawSync(Buffer.from(typeof obj === 'string' ? obj : JSON.stringify(obj), 'utf8')));

const CMD = 1048576, CTRL = 262144, SHIFT = 131072;
const sc = (keyCode, keyName, modifiers) => ({ shortcut: { _0: { keyCode, modifiers, keyName } } });
const base = (parts, extra) => ({ format: 'glideball-share', version: 1, kind: 'parts', parts, writtenBy: '2.10-beta.13', ...extra });
const scroll = {
  scrollMode: 'follow', nativeScrollSpeed: 0.5, flyDistance: 4, flyAcceleration: 0.5, flyGlide: 0.35, flyReach: 0.5,
  smoothScrolling: true, scrollDistance: 22, scrollSmoothness: 0.4, scrollAcceleration: 0.5, throwEnabled: true,
  throwAmount: 0.7, reverseScroll: false, shiftScrollsHorizontally: true,
};
const media = { gesture: { _0: {
  up: { action: { media: { _0: 0 } }, repeats: true }, down: { action: { media: { _0: 1 } }, repeats: true },
  left: { action: { media: { _0: 18 } }, repeats: false }, right: { action: { media: { _0: 17 } }, repeats: false, once: true },
  tap: { media: { _0: 16 } }, distance: 'short',
} } };
const allButtons = { 1: { rightClick: {} }, 2: sc(8, 'C', CMD), 3: media, 4: { system: {} }, 5: { back: {} }, 6: { system: {} }, 7: { holdShortcut: { _0: { keyCode: 49, modifiers: CTRL, keyName: 'Space' } } } };

const good = [];
const bad = [];
const add = (name, obj, expect) => good.push({ name, d: pack(obj), expect });
const refuse = (name, d) => bad.push({ name, d, refuse: true });

// ---------------------------------------------------------------- good: every part
add('everything, with a name and a custom color', base(
  ['pointer', 'displays', 'scrolling', 'buttons', 'combos', 'gestures', 'app:com.apple.Safari', 'app:com.apple.dt.Xcode', 'look', 'sounds'],
  {
    version: 2, from: 'Levi',
    trackingSpeed: 6.5, precisionSpeed: 1,
    displaySpeeds: { enabled: true, speeds: { '1552-41234-0': 8, 'uuid-ABC': 3.5 }, names: { '1552-41234-0': 'LG UltraFine', 'uuid-ABC': 'Built-in Display' } },
    scroll, ballScrollSpeed: 1.5,
    buttons: allButtons,
    chords: [{ buttons: [2, 3], action: { openApp: { bundleID: 'com.apple.Notes' } } }, { buttons: [0, 1], action: sc(126, '↑', CTRL) }],
    gesturesEnabled: true, gestureDistance: 'normal', gestureSteadyHands: true,
    apps: [
      { bundleID: 'com.apple.Safari', name: 'Safari', trackingSpeed: 3, buttons: { 2: { back: {} }, 3: { forward: {} } } },
      { bundleID: 'com.apple.dt.Xcode', name: 'Xcode', scroll: { ...scroll, scrollMode: 'native', nativeScrollSpeed: 1.2 }, chords: [{ buttons: [1, 2], action: sc(15, 'R', CMD) }] },
    ],
    look: { theme: 'custom', custom: ['FFE070', '2EC99A', '2B3A9E'] },
    sounds: { on: true, volume: 0.8, kinds: { pauseResume: true, modes: true, ticks: false, milestones: true, buttons: true } },
  }),
{
  parts: ['pointer', 'displays', 'scrolling', 'buttons', 'combos', 'gestures', 'app:com.apple.Safari', 'app:com.apple.dt.Xcode', 'look', 'sounds'],
  from: 'Levi', trackingSpeed: 6.5, scrollMode: 'follow', theme: 'custom', apps: ['com.apple.Safari', 'com.apple.dt.Xcode'],
  buttons: { 1: 'rightClick', 2: 'shortcut', 3: 'gesture', 4: 'system', 5: 'back', 6: 'system', 7: 'holdShortcut' },
});
add('pointer only', base(['pointer'], { trackingSpeed: 12, precisionSpeed: 0.5 }), { parts: ['pointer'], from: null, trackingSpeed: 12 });
add('scroll feel only', base(['scrolling'], { scroll, ballScrollSpeed: 1 }), { parts: ['scrolling'], from: null, scrollMode: 'follow' });
add('buttons without gestures (the gesture button stays out)', base(['buttons'], {
  buttons: { 1: { rightClick: {} }, 2: sc(8, 'C', CMD), 4: { system: {} }, 5: { system: {} }, 6: { system: {} }, 7: { system: {} } },
}), { parts: ['buttons'], from: null, buttons: { 1: 'rightClick', 2: 'shortcut', 4: 'system', 5: 'system', 6: 'system', 7: 'system' } });
add('gestures only', base(['gestures'], { buttons: { 3: media }, gesturesEnabled: true, gestureDistance: 'long', gestureSteadyHands: false }),
  { parts: ['gestures'], from: null, buttons: { 3: 'gesture' } });
add('no combos (an empty list)', base(['combos'], { chords: [] }), { parts: ['combos'], from: null });
add('one app setup', base(['app:com.microsoft.VSCode'], { apps: [{ bundleID: 'com.microsoft.VSCode', name: 'Visual Studio Code', trackingSpeed: 5 }] }),
  { parts: ['app:com.microsoft.VSCode'], from: null, apps: ['com.microsoft.VSCode'] });
add('ball color', base(['look'], { look: { theme: 'sunset' } }), { parts: ['look'], from: null, theme: 'sunset' });
add('sounds off', base(['sounds'], { sounds: { on: false, volume: 0.25, kinds: {} } }), { parts: ['sounds'], from: null });
add('per-display speeds', base(['displays'], { version: 2, displaySpeeds: { enabled: true, speeds: { '1-2-3': 9 }, names: { '1-2-3': 'Studio Display' } } }),
  { parts: ['displays'], from: null });
add('a name with an emoji, RTL marks and spaces to clean', base(['look'], { from: '  ‮L​evi 🎱⁦  ', look: { theme: 'ocean' } }),
  { parts: ['look'], from: 'Levi 🎱', theme: 'ocean' });
add('a name over 40 characters is cut', base(['look'], { from: 'A'.repeat(60), look: { theme: 'orb' } }),
  { parts: ['look'], from: 'A'.repeat(40), theme: 'orb' });
add('parts out of order and repeated come back in order', base(['look', 'pointer', 'look'], { trackingSpeed: 4, look: { theme: 'forest' } }),
  { parts: ['pointer', 'look'], from: null, trackingSpeed: 4, theme: 'forest' });
add('an unknown part from a newer Glideball is ignored', base(['pointer', 'hologram'], { trackingSpeed: 4, hologram: { x: 1 } }),
  { parts: ['pointer'], from: null, trackingSpeed: 4 });

// ---------------------------------------------------------------- good: beta 12 shares
const legacy = (kind, extra) => ({ format: 'glideball-share', version: 1, kind, writtenBy: '2.10-beta.12', ...extra });
add('beta 12: scroll feel', legacy('scrolling', { scroll, ballScrollSpeed: 1 }), { parts: ['scrolling'], from: null, scrollMode: 'follow' });
add('beta 12: pointer', legacy('pointer', { trackingSpeed: 9.5, precisionSpeed: 1 }), { parts: ['pointer'], from: null, trackingSpeed: 9.5 });
add('beta 12: buttons and gestures (missing buttons are Default)', legacy('buttons', {
  version: 2, buttons: { 2: sc(8, 'C', CMD), 3: media }, chords: [{ buttons: [2, 3], action: { openApp: { bundleID: 'com.apple.Notes' } } }], gesturesEnabled: true,
}), { parts: ['buttons', 'combos', 'gestures'], from: null,
  buttons: { 1: 'system', 2: 'shortcut', 3: 'gesture', 4: 'system', 5: 'system', 6: 'system', 7: 'system' } });
add('beta 12: one app setup', legacy('app-setup', { name: 'Xcode', appSetup: { bundleID: 'com.apple.dt.Xcode', name: 'Xcode', trackingSpeed: 3.5 } }),
  { parts: ['app:com.apple.dt.Xcode'], from: null, apps: ['com.apple.dt.Xcode'] });
add('beta 12: ball color', legacy('look', { look: { theme: 'ember' } }), { parts: ['look'], from: null, theme: 'ember' });
add('beta 12: everything', legacy('everything', {
  version: 2,
  config: { enabled: true, trackingSpeed: 7, precisionSpeed: 1, scrollMode: 'flywheel', flyGlide: 0.5, buttons: { 1: { rightClick: {} }, 3: media },
    chords: [], appProfiles: [{ bundleID: 'com.apple.Safari', name: 'Safari', trackingSpeed: 3 }],
    displaySpeeds: { enabled: true, speeds: { '1-2-3': 9 }, names: {} }, globalShortcuts: {} },
  look: { theme: 'classic' },
}), { parts: ['pointer', 'scrolling', 'buttons', 'combos', 'gestures', 'app:com.apple.Safari', 'look'], from: null,
  trackingSpeed: 7, scrollMode: 'flywheel', theme: 'classic', apps: ['com.apple.Safari'],
  buttons: { 1: 'rightClick', 2: 'system', 3: 'gesture', 4: 'system', 5: 'system', 6: 'system', 7: 'system' } });

// ---------------------------------------------------------------- hostile: accepted, but cleaned and clamped
const hostileGood = [];
const addH = (name, obj, expect) => hostileGood.push({ name, d: pack(obj), expect });
addH('script and img tags stay plain text', base(['app:com.evil.app', 'buttons'], {
  from: '<script>alert(1)</script>',
  apps: [{ bundleID: 'com.evil.app', name: '<img src=x onerror=alert(1)>' }],
  buttons: { 2: sc(8, '<b>x</b>', CMD) },
}), { parts: ['buttons', 'app:com.evil.app'], from: '<script>alert(1)</script>'.slice(0, 40), apps: ['com.evil.app'], buttons: { 2: 'shortcut' } });
addH('huge numbers are clamped', base(['pointer', 'scrolling'], {
  trackingSpeed: 1e308, precisionSpeed: -1e308, scroll: { ...scroll, flyDistance: 1e308, throwAmount: -5 }, ballScrollSpeed: 99,
}), { parts: ['pointer', 'scrolling'], from: null, trackingSpeed: 80, scrollMode: 'follow' });
addH('buttons 0, 8 and -1 are ignored', base(['buttons'], {
  buttons: { 0: { rightClick: {} }, 8: { rightClick: {} }, '-1': { rightClick: {} }, 2: { middleClick: {} } },
}), { parts: ['buttons'], from: null, buttons: { 2: 'middleClick' } });
addH('a gesture inside a gesture is dropped, the rest stays', base(['gestures'], {
  buttons: { 3: { gesture: { _0: { up: { action: media, repeats: false }, down: { action: { back: {} }, repeats: false }, tap: media } } } },
}), { parts: ['gestures'], from: null, buttons: { 3: 'gesture' } });
addH('bad bundle IDs and javascript: in Open are dropped', base(['buttons', 'combos', 'app:com.ok.app'], {
  buttons: { 2: { openApp: { bundleID: 'javascript:alert(1)' } }, 3: { openApp: { bundleID: '../../etc' } }, 1: { openApp: { bundleID: 'com.apple.Notes' } } },
  chords: [{ buttons: [2, 3], action: { openApp: { bundleID: 'java script:x' } } }, { buttons: [1, 1], action: { back: {} } }, { buttons: [1, 9], action: { back: {} } }],
  apps: [{ bundleID: 'not a bundle id', name: 'x' }, { bundleID: 'com.ok.app', name: '' }],
}), { parts: ['buttons', 'combos', 'app:com.ok.app'], from: null, apps: ['com.ok.app'], buttons: { 1: 'openApp' } });
addH('a ball color with one bad hex out of four still has three good ones', base(['look', 'pointer'], {
  trackingSpeed: 4, look: { theme: 'custom', custom: ['FFFFFF', 'url(x)', '000000', '123ABC'] },
}), { parts: ['pointer', 'look'], from: null, theme: 'custom', trackingSpeed: 4 });
addH('a bad ball color drops just that part', base(['look', 'pointer'], {
  trackingSpeed: 4, look: { theme: 'custom', custom: ['red', '#000000', 'expression(alert(1))'] },
}), { parts: ['pointer'], from: null, trackingSpeed: 4 });

// ---------------------------------------------------------------- hostile: refused
refuse('empty', '');
refuse('invalid base64 characters', 'abc$%^&*()');
refuse('base64 of something that is not deflate', b64url(Buffer.from('hello, this is not compressed at all')));
refuse('d over 2,048 characters', 'A'.repeat(2049));
{
  // A 1.5 MB deflate bomb that fits in a link (and a 2 MB one that doesn't).
  const bomb = b64url(deflateRawSync(Buffer.alloc(1_500_000, 0x20), { level: 9 }));
  if (bomb.length > 2048) throw new Error(`the bomb doesn't fit in a link (${bomb.length})`);
  refuse('a 1.5 MB deflate bomb that fits in a link', bomb);
  refuse('a 2 MB deflate bomb', b64url(deflateRawSync(Buffer.alloc(2_000_000, 0x5b), { level: 9 })));
  // Just over the cap: valid JSON padded with spaces to 70 KB.
  const big = JSON.stringify(base(['pointer'], { trackingSpeed: 4 })) + ' '.repeat(70_000);
  refuse('valid JSON over 64 KB', b64url(deflateRawSync(Buffer.from(big), { level: 9 })));
}
refuse('nesting 40 deep', pack(`{"format":"glideball-share","version":1,"kind":"parts","parts":["pointer"],"trackingSpeed":4,"x":${'['.repeat(40)}${']'.repeat(40)}}`));
refuse('not JSON', pack('{"format": "glideball-share", '));
refuse('a JSON array', pack('[1,2,3]'));
refuse('invalid UTF-8', b64url(deflateRawSync(Buffer.from([0x7b, 0x22, 0xff, 0xfe, 0x22, 0x7d]))));
refuse('wrong format', pack({ ...base(['pointer'], { trackingSpeed: 4 }), format: 'glideball-settings' }));
refuse('version 3', pack({ ...base(['pointer'], { trackingSpeed: 4 }), version: 3 }));
refuse('version 0', pack({ ...base(['pointer'], { trackingSpeed: 4 }), version: 0 }));
refuse('unknown kind', pack({ ...base(['pointer'], { trackingSpeed: 4 }), kind: 'telepathy' }));
refuse('only unknown parts', pack(base(['hologram', 'teleport'], { trackingSpeed: 4 })));
refuse('a part without its fields', pack(base(['pointer', 'look'], {})));
refuse('numbers as strings leave nothing', pack(base(['pointer'], { trackingSpeed: '9999', precisionSpeed: 'NaN' })));
refuse('an app part without its app', pack(base(['app:com.apple.Safari'], { apps: [{ bundleID: 'com.apple.Notes', name: 'Notes' }] })));
refuse('beta 12: an app setup with a bad bundle ID', pack(legacy('app-setup', { appSetup: { bundleID: '<script>', name: 'x' } })));
refuse('beta 12: everything without its config', pack(legacy('everything', { look: { theme: 'orb' } })));

const note = 'Made by website/tests/make-share-fixtures.mjs (docs/SHARE-FORMAT.md). Do not edit by hand.';
writeFileSync(join(out, 'js-made.json'), JSON.stringify({ note, cases: good }, null, 1) + '\n');
writeFileSync(join(out, 'hostile.json'), JSON.stringify({ note, cases: [...hostileGood, ...bad] }, null, 1) + '\n');
console.log(`js-made.json: ${good.length} cases; hostile.json: ${hostileGood.length + bad.length} cases`);
