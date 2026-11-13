/* Glideball: reading a shared setup's link (https://glideball.netlify.app/s/#<d>).
   The format, and every check below, is docs/SHARE-FORMAT.md; the Mac app's
   SharedSetup.swift follows the same document, and both are tested against the
   same fixtures (website/tests/fixtures/share/).

   The payload is hostile until proven otherwise. Nothing here touches the page:
   it turns `d` into a plain, checked object (or a reason it was refused), and
   the words the app uses for each setting. share.js puts those on the page as
   text. No DOM, so Node's tests run the same code. */

export const LIMITS = Object.freeze({
  maxPayload: 2048,          // characters of d
  maxInflated: 65535,        // bytes of JSON; reaching 65,536 is refused
  maxDepth: 32,
  maxChords: 24,
  maxApps: 64,
  maxDisplays: 16,
  maxDisplayKey: 120,
  maxName: 80,
  maxFrom: 40,
  maxKeyName: 12,
  maxWrittenBy: 24,
});

export const FORMAT = 'glideball-share';
const PART_ORDER = ['pointer', 'displays', 'scrolling', 'buttons', 'combos', 'gestures', 'app', 'look', 'sounds'];
const FIXED_PARTS = new Set(['pointer', 'displays', 'scrolling', 'buttons', 'combos', 'gestures', 'look', 'sounds']);
const LEGACY_KINDS = new Set(['everything', 'app-setup', 'pointer', 'scrolling', 'buttons', 'look']);

const RANGES = {
  trackingSpeed: [0.5, 80],
  precisionSpeed: [0.25, 3],
  nativeScrollSpeed: [0, 5],
  flyDistance: [1, 20],
  flyAcceleration: [0, 1.5],
  unit: [0, 1],
  scrollDistance: [1, 40],
  ballScrollSpeed: [0.25, 4],
};

const SCROLL_DEFAULTS = Object.freeze({
  scrollMode: 'flywheel', nativeScrollSpeed: 0.5, flyDistance: 4, flyAcceleration: 0.5, flyGlide: 0.35,
  flyReach: 0.5, smoothScrolling: true, scrollDistance: 14, scrollSmoothness: 0.4, scrollAcceleration: 0.5,
  throwEnabled: true, throwAmount: 0.4, reverseScroll: false, shiftScrollsHorizontally: true,
});
const SCROLL_RANGES = {
  nativeScrollSpeed: RANGES.nativeScrollSpeed, flyDistance: RANGES.flyDistance, flyAcceleration: RANGES.flyAcceleration,
  flyGlide: RANGES.unit, flyReach: RANGES.unit, scrollDistance: RANGES.scrollDistance, scrollSmoothness: RANGES.unit,
  scrollAcceleration: RANGES.unit, throwAmount: RANGES.unit,
};
const SCROLL_BOOLS = ['smoothScrolling', 'throwEnabled', 'reverseScroll', 'shiftScrollsHorizontally'];
const SCROLL_MODES = new Set(['native', 'flywheel', 'follow']);

export const THEME_IDS = ['orb', 'ember', 'sunset', 'ocean', 'forest', 'graphite', 'classic', 'custom'];
export const SOUND_KINDS = ['pauseResume', 'modes', 'ticks', 'milestones', 'buttons'];
const GESTURE_DISTANCES = new Set(['short', 'normal', 'long']);
const MEDIA_KEYS = new Set([0, 1, 7, 16, 17, 18]);
const SIMPLE_ACTIONS = new Set(['system', 'leftClick', 'rightClick', 'middleClick', 'back', 'forward', 'disabled',
  'precisionHold', 'precisionToggle', 'ballScrollHold', 'dragLock']);

// macOS modifier bits (CGEventFlags).
export const MOD = Object.freeze({ shift: 0x20000, control: 0x40000, option: 0x80000, command: 0x100000, fn: 0x800000 });
const ALLOWED_MODS = 0x20000n | 0x40000n | 0x80000n | 0x100000n | 0x800000n;

// ------------------------------------------------------------------ small checks

const own = (o, k) => o !== null && typeof o === 'object' && Object.prototype.hasOwnProperty.call(o, k);
const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isNum = (v) => typeof v === 'number' && Number.isFinite(v);
const clamp = (v, [lo, hi]) => Math.min(Math.max(v, lo), hi);
/** A finite number clamped into range, or undefined ("not given"). */
const num = (v, range) => (isNum(v) ? clamp(v, range) : undefined);

const INVISIBLE = /[\p{Cc}\p{Cf}\u2028\u2029]/gu;
const segmenter = typeof Intl !== 'undefined' && Intl.Segmenter ? new Intl.Segmenter('en', { granularity: 'grapheme' }) : null;

/** Text from outside, safe to show: no control or invisible characters, trimmed, at most `max` characters. */
export function cleanText(s, max) {
  if (typeof s !== 'string') return '';
  // Far more than can survive the cut, but never megabytes of work.
  let out = s.slice(0, max * 64).replace(INVISIBLE, '').trim();
  const chars = segmenter ? Array.from(segmenter.segment(out), (g) => g.segment) : Array.from(out);
  if (chars.length > max) out = chars.slice(0, max).join('');
  return out;
}

/** "com.apple.Safari": letters, digits, dots, hyphens and underscores, 1–155 bytes. */
export function isBundleID(s) {
  return typeof s === 'string' && s.length >= 1 && s.length <= 155 && /^[A-Za-z0-9._-]+$/.test(s)
    && !s.startsWith('.') && !s.endsWith('.') && !s.includes('..');
}

const HEX6 = /^[0-9A-Fa-f]{6}$/;

// ------------------------------------------------------------------ the payload

function unbase64url(d) {
  if (typeof d !== 'string' || d.length === 0 || !/^[A-Za-z0-9_-]+$/.test(d)) return null;
  if (d.length % 4 === 1) return null;
  let b = d.replace(/-/g, '+').replace(/_/g, '/');
  while (b.length % 4) b += '=';
  try {
    const bin = atob(b);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

/** Whether this browser can read a share at all. */
export function canInflate() {
  if (typeof DecompressionStream !== 'function') return false;
  try {
    new DecompressionStream('deflate-raw');
    return true;
  } catch {
    return false;
  }
}

/** Raw deflate, read chunk by chunk and stopped the moment it reaches the cap. */
async function inflate(bytes, limit) {
  const ds = new DecompressionStream('deflate-raw');
  const writer = ds.writable.getWriter();
  const reader = ds.readable.getReader();
  writer.write(bytes).catch(() => {});
  writer.close().catch(() => {});
  const chunks = [];
  let total = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > limit) {
        reader.cancel().catch(() => {});
        return { tooBig: true };
      }
      chunks.push(value);
    }
  } catch {
    return null;
  }
  if (total === 0) return null;
  const out = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) { out.set(c, at); at += c.byteLength; }
  return { bytes: out };
}

/** Brackets nest no deeper than `limit` (strings skipped), checked before parsing. */
export function depthIsWithin(bytes, limit = LIMITS.maxDepth) {
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (const b of bytes) {
    if (inString) {
      if (escaped) escaped = false;
      else if (b === 0x5c) escaped = true;
      else if (b === 0x22) inString = false;
      continue;
    }
    if (b === 0x22) inString = true;
    else if (b === 0x7b || b === 0x5b) { if (++depth > limit) return false; }
    else if (b === 0x7d || b === 0x5d) depth--;
  }
  return true;
}

/**
 * d → { ok: true, share } or { ok: false, reason }. `reason` is one of Glideball's own
 * words (tooBig, notBase64, notDeflate, tooDeep, notJSON, notAShare, unsupportedVersion,
 * missingPart, noBrowserSupport), never text from the payload.
 */
export async function decodePayload(d) {
  if (typeof d !== 'string' || d.length === 0) return { ok: false, reason: 'empty' };
  if (d.length > LIMITS.maxPayload) return { ok: false, reason: 'tooBig' };
  const packed = unbase64url(d);
  if (!packed) return { ok: false, reason: 'notBase64' };
  if (!canInflate()) return { ok: false, reason: 'noBrowserSupport' };
  const inflated = await inflate(packed, LIMITS.maxInflated);
  if (!inflated) return { ok: false, reason: 'notDeflate' };
  if (inflated.tooBig) return { ok: false, reason: 'tooBig' };
  return decodeJSONBytes(inflated.bytes);
}

export function decodeJSONBytes(bytes) {
  if (!depthIsWithin(bytes)) return { ok: false, reason: 'tooDeep' };
  let raw;
  try {
    raw = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  } catch {
    return { ok: false, reason: 'notJSON' };
  }
  return readShare(raw);
}

// ------------------------------------------------------------------ actions

/** A checked action, as a plain object ({ type, … }), or null when there's nothing safe to keep. */
export function readAction(v, nested = false) {
  if (!isObject(v)) return null;
  const keys = Object.keys(v);
  if (keys.length !== 1) return null;
  const type = keys[0];
  const body = v[type];
  if (!isObject(body)) return null;
  if (SIMPLE_ACTIONS.has(type)) return { type };
  switch (type) {
    case 'shortcut':
    case 'holdShortcut': {
      const s = body._0;
      if (!isObject(s) || !Number.isInteger(s.keyCode) || s.keyCode < 0 || s.keyCode > 127) return null;
      if (!Number.isSafeInteger(s.modifiers) || s.modifiers < 0 || typeof s.keyName !== 'string') return null;
      const keyName = cleanText(s.keyName, LIMITS.maxKeyName) || '?';
      return { type, keyCode: s.keyCode, modifiers: Number(BigInt(s.modifiers) & ALLOWED_MODS), keyName };
    }
    case 'modifiedClick':
      if (!Number.isInteger(body.button) || body.button < 0 || body.button > 4) return null;
      if (!Number.isSafeInteger(body.modifiers) || body.modifiers < 0) return null;
      return { type, button: body.button, modifiers: Number(BigInt(body.modifiers) & ALLOWED_MODS) };
    case 'media':
      return MEDIA_KEYS.has(body._0) ? { type, key: body._0 } : null;
    case 'openApp':
      return isBundleID(body.bundleID) ? { type, bundleID: body.bundleID } : null;
    case 'gesture': {
      if (nested || !isObject(body._0)) return null;
      const g = body._0;
      const out = { type, steps: {}, tap: { type: 'system' } };
      for (const dir of ['up', 'down', 'left', 'right']) {
        const step = g[dir];
        if (!isObject(step)) continue;
        const action = readAction(step.action, true);
        if (!action) continue;
        const repeats = step.repeats === true;
        out.steps[dir] = { action, repeats, once: !repeats && step.once === true };
      }
      if (own(g, 'tap')) out.tap = readAction(g.tap, true) || { type: 'system' };
      if (GESTURE_DISTANCES.has(g.distance)) out.distance = g.distance;
      return out;
    }
    default:
      return null;   // a newer Glideball's action: that button isn't set
  }
}

/** Buttons 1–7 only (0, the primary button, is never read). */
function readButtons(v) {
  if (!isObject(v)) return null;
  const out = {};
  for (const k of Object.keys(v)) {
    if (!/^[1-7]$/.test(k)) continue;
    const a = readAction(v[k]);
    if (a) out[k] = a;
  }
  return out;
}

function readChords(v) {
  if (!Array.isArray(v)) return null;
  const out = [];
  const seen = new Set();
  for (const c of v) {
    if (out.length >= LIMITS.maxChords) break;
    if (!isObject(c) || !Array.isArray(c.buttons)) continue;
    const list = c.buttons;
    if (!list.every((b) => Number.isInteger(b))) continue;
    const set = new Set(list.filter((b) => b >= 0 && b <= 7));
    if (set.size < 2 || set.size > 4 || set.size !== list.length) continue;
    const sorted = [...set].sort((a, b) => a - b);
    const key = sorted.join(',');
    if (seen.has(key)) continue;
    const action = readAction(c.action);
    if (!action) continue;
    seen.add(key);
    out.push({ buttons: sorted, action });
  }
  return out;
}

function readScroll(v) {
  if (!isObject(v)) return null;
  const out = { ...SCROLL_DEFAULTS };
  if (own(v, 'scrollMode')) {
    if (!SCROLL_MODES.has(v.scrollMode)) return null;
    out.scrollMode = v.scrollMode;
  }
  for (const [k, range] of Object.entries(SCROLL_RANGES)) {
    const n = num(v[k], range);
    if (n !== undefined) out[k] = n;
  }
  for (const k of SCROLL_BOOLS) if (typeof v[k] === 'boolean') out[k] = v[k];
  return out;
}

function readApp(v) {
  if (!isObject(v) || !isBundleID(v.bundleID)) return null;
  const app = { bundleID: v.bundleID, name: cleanText(v.name, LIMITS.maxName) || v.bundleID };
  const speed = num(v.trackingSpeed, RANGES.trackingSpeed);
  if (speed !== undefined) app.trackingSpeed = speed;
  const scroll = readScroll(v.scroll);
  if (scroll) app.scroll = scroll;
  const buttons = readButtons(v.buttons);
  if (buttons) app.buttons = buttons;
  const chords = readChords(v.chords);
  if (chords) app.chords = chords;
  return app;
}

function readApps(v) {
  if (!Array.isArray(v)) return [];
  const out = [];
  const seen = new Set();
  for (const a of v) {
    if (out.length >= LIMITS.maxApps) break;
    const app = readApp(a);
    if (!app || seen.has(app.bundleID)) continue;
    seen.add(app.bundleID);
    out.push(app);
  }
  return out;
}

function readDisplays(v) {
  if (!isObject(v)) return null;
  const speeds = isObject(v.speeds) ? v.speeds : {};
  const names = isObject(v.names) ? v.names : {};
  const list = [];
  for (const key of Object.keys(speeds).sort()) {
    if (list.length >= LIMITS.maxDisplays) break;
    const chars = segmenter ? [...segmenter.segment(key)].length : [...key].length;
    if (!key || chars > LIMITS.maxDisplayKey || !isNum(speeds[key])) continue;
    const name = own(names, key) ? cleanText(names[key], LIMITS.maxName) : '';
    list.push({ key, name, speed: clamp(speeds[key], RANGES.trackingSpeed) });
  }
  return { enabled: v.enabled === true, list };
}

function readLook(v) {
  if (!isObject(v) || !THEME_IDS.includes(v.theme)) return null;
  if (v.theme !== 'custom') return { theme: v.theme };
  const colors = (Array.isArray(v.custom) ? v.custom : []).filter((c) => typeof c === 'string' && HEX6.test(c)).map((c) => c.toUpperCase());
  return colors.length === 3 ? { theme: 'custom', custom: colors } : null;
}

function readSounds(v) {
  if (!isObject(v) || typeof v.on !== 'boolean') return null;
  const volume = num(v.volume, [0, 1]);
  const kinds = {};
  if (isObject(v.kinds)) for (const k of SOUND_KINDS) if (typeof v.kinds[k] === 'boolean') kinds[k] = v.kinds[k];
  return { on: v.on, volume: volume === undefined ? 1 : volume, kinds };
}

/** Buttons 1–7 with every missing one as Default (beta 12 replaced the whole map). */
function filledButtons(map) {
  const out = {};
  for (let k = 1; k <= 7; k++) out[k] = map[k] || { type: 'system' };
  return out;
}

// ------------------------------------------------------------------ the share

function readShare(raw) {
  if (!isObject(raw)) return { ok: false, reason: 'notJSON' };
  if (raw.format !== FORMAT) return { ok: false, reason: 'notAShare' };
  if (!Number.isInteger(raw.version)) return { ok: false, reason: 'notJSON' };
  if (raw.version < 1 || raw.version > 2) return { ok: false, reason: 'unsupportedVersion' };
  const kind = raw.kind;
  if (kind !== 'parts' && !LEGACY_KINDS.has(kind)) return { ok: false, reason: 'notAShare' };

  // Every field, read and checked the same way whichever kind it is.
  const f = {};
  f.trackingSpeed = num(raw.trackingSpeed, RANGES.trackingSpeed);
  f.precisionSpeed = num(raw.precisionSpeed, RANGES.precisionSpeed);
  f.displays = readDisplays(raw.displaySpeeds);
  f.scroll = readScroll(raw.scroll);
  f.ballScrollSpeed = num(raw.ballScrollSpeed, RANGES.ballScrollSpeed);
  f.buttons = readButtons(raw.buttons);
  f.chords = readChords(raw.chords);
  f.gesturesEnabled = typeof raw.gesturesEnabled === 'boolean' ? raw.gesturesEnabled : undefined;
  f.gestureDistance = GESTURE_DISTANCES.has(raw.gestureDistance) ? raw.gestureDistance : undefined;
  f.gestureSteadyHands = typeof raw.gestureSteadyHands === 'boolean' ? raw.gestureSteadyHands : undefined;
  f.apps = readApps(raw.apps);
  f.look = readLook(raw.look);
  f.sounds = readSounds(raw.sounds);

  let wanted;   // part ids, in the order given
  if (kind === 'parts') {
    if (!Array.isArray(raw.parts)) return { ok: false, reason: 'notAShare' };
    wanted = raw.parts.filter((p) => typeof p === 'string');
  } else {
    wanted = legacy(kind, raw, f);
    if (!wanted) return { ok: false, reason: 'missingPart' };
  }

  const share = {
    version: raw.version,
    legacyKind: kind === 'parts' ? null : kind,
    from: null,
    writtenBy: cleanText(raw.writtenBy, LIMITS.maxWrittenBy) || null,
    parts: [],
  };
  if (kind === 'parts') share.from = cleanText(raw.from, LIMITS.maxFrom) || null;

  const buttonEntries = f.buttons || {};
  const plain = Object.fromEntries(Object.entries(buttonEntries).filter(([, a]) => a.type !== 'gesture'));
  const gestureButtons = Object.fromEntries(Object.entries(buttonEntries).filter(([, a]) => a.type === 'gesture'));
  const has = {
    pointer: f.trackingSpeed !== undefined || f.precisionSpeed !== undefined,
    displays: f.displays !== null,
    scrolling: f.scroll !== null || f.ballScrollSpeed !== undefined,
    buttons: Object.keys(plain).length > 0,
    combos: f.chords !== null,
    gestures: Object.keys(gestureButtons).length > 0 || f.gesturesEnabled !== undefined
      || f.gestureDistance !== undefined || f.gestureSteadyHands !== undefined,
    look: f.look !== null,
    sounds: f.sounds !== null,
  };

  const seen = new Set();
  const picked = [];
  for (const id of wanted) {
    if (seen.has(id)) continue;
    seen.add(id);
    if (FIXED_PARTS.has(id)) {
      if (has[id]) picked.push(id);
    } else if (id.startsWith('app:')) {
      const bundle = id.slice(4);
      if (f.apps.some((a) => a.bundleID === bundle)) picked.push(id);
    }
    // anything else: a newer Glideball's part, ignored
  }
  if (!picked.length) return { ok: false, reason: 'missingPart' };
  picked.sort((a, b) => partRank(a) - partRank(b));
  share.parts = picked;

  const inc = (p) => picked.includes(p);
  if (inc('pointer')) share.pointer = { trackingSpeed: f.trackingSpeed, precisionSpeed: f.precisionSpeed };
  if (inc('displays')) share.displays = f.displays;
  if (inc('scrolling')) share.scrolling = { scroll: f.scroll, ballScrollSpeed: f.ballScrollSpeed };
  if (inc('buttons') || inc('gestures')) {
    share.buttons = {};
    if (inc('buttons')) Object.assign(share.buttons, plain);
    if (inc('gestures')) Object.assign(share.buttons, gestureButtons);
  }
  if (inc('combos')) share.chords = f.chords;
  if (inc('gestures')) {
    share.gestures = { enabled: f.gesturesEnabled, distance: f.gestureDistance, steadyHands: f.gestureSteadyHands };
  }
  const appIDs = picked.filter((p) => p.startsWith('app:')).map((p) => p.slice(4));
  share.apps = appIDs.map((id) => f.apps.find((a) => a.bundleID === id));
  if (inc('look')) share.look = f.look;
  if (inc('sounds')) share.sounds = f.sounds;
  return { ok: true, share };
}

function partRank(id) {
  const i = PART_ORDER.indexOf(id.startsWith('app:') ? 'app' : id);
  return i;
}

/** Beta 12's kinds, read as checklist parts (docs/SHARE-FORMAT.md, "Beta 12 shares"). Fills `f` in. */
function legacy(kind, raw, f) {
  switch (kind) {
    case 'pointer': return ['pointer'];
    case 'scrolling': return f.scroll ? ['scrolling'] : null;
    case 'look': return ['look'];
    case 'buttons': {
      const parts = [];
      if (f.buttons) {
        f.buttons = filledButtons(f.buttons);
        parts.push('buttons', 'gestures');
      } else if (f.gesturesEnabled !== undefined) {
        parts.push('gestures');
      }
      if (f.chords) parts.push('combos');
      return parts.length ? parts : null;
    }
    case 'app-setup': {
      const app = readApp(raw.appSetup);
      if (!app) return null;
      f.apps = [app];
      return ['app:' + app.bundleID];
    }
    case 'everything': {
      const c = raw.config;
      if (!isObject(c)) return null;
      f.trackingSpeed = num(c.trackingSpeed, RANGES.trackingSpeed) ?? 4;
      f.precisionSpeed = num(c.precisionSpeed, RANGES.precisionSpeed) ?? 1;
      f.scroll = readScroll(c) || { ...SCROLL_DEFAULTS };
      f.ballScrollSpeed = num(c.ballScrollSpeed, RANGES.ballScrollSpeed) ?? 1;
      f.buttons = filledButtons(readButtons(c.buttons) || {});
      f.chords = readChords(c.chords) || [];
      f.gesturesEnabled = typeof c.gesturesEnabled === 'boolean' ? c.gesturesEnabled : true;
      f.gestureDistance = GESTURE_DISTANCES.has(c.gestureDistance) ? c.gestureDistance : 'normal';
      f.gestureSteadyHands = typeof c.gestureSteadyHands === 'boolean' ? c.gestureSteadyHands : false;
      f.displays = null;   // never the per-display speeds it also carried
      f.sounds = null;
      f.apps = readApps(c.appProfiles);
      const parts = ['pointer', 'scrolling', 'buttons', 'gestures', 'combos', ...f.apps.map((a) => 'app:' + a.bundleID)];
      if (f.look) parts.push('look');
      return parts;
    }
    default: return null;
  }
}

/** glideball://import?d=…, built only from a payload that passed (call after decodePayload). */
export function glideballLink(d) {
  if (typeof d !== 'string' || !d || d.length > LIMITS.maxPayload || !/^[A-Za-z0-9_-]+$/.test(d)) return null;
  return 'glideball://import?d=' + d;
}

// ------------------------------------------------------------------ the app's words

const SHIFT = 0x20000, CTRL = 0x40000, ALT = 0x80000, CMD = 0x100000;

/** "⌃⌥⇧⌘" then the key, as Glideball writes a shortcut. */
export function shortcutText(s) {
  let out = '';
  if (s.modifiers & CTRL) out += '⌃';
  if (s.modifiers & ALT) out += '⌥';
  if (s.modifiers & SHIFT) out += '⇧';
  if (s.modifiers & CMD) out += '⌘';
  return out + s.keyName;
}

const sc = (keyCode, keyName, modifiers) => ({ keyCode, keyName, modifiers });
// ButtonAction.presets (Config.swift): the shortcuts and clicks with their own names.
const SHORTCUT_PRESETS = [
  ['Browser Back', sc(33, '[', CMD)], ['Browser Forward', sc(30, ']', CMD)], ['New Tab', sc(17, 'T', CMD)],
  ['Close Tab', sc(13, 'W', CMD)], ['Reopen Closed Tab', sc(17, 'T', CMD | SHIFT)], ['Next Tab', sc(48, '⇥', CTRL)],
  ['Previous Tab', sc(48, '⇥', CTRL | SHIFT)], ['Reload', sc(15, 'R', CMD)], ['Zoom In', sc(24, '=', CMD)],
  ['Zoom Out', sc(27, '-', CMD)], ['Previous Space', sc(123, '←', CTRL)], ['Next Space', sc(124, '→', CTRL)],
  ['Mission Control', sc(126, '↑', CTRL)], ['App Exposé', sc(125, '↓', CTRL)], ['Last Used App', sc(48, '⇥', CMD)],
  ['Minimize Window', sc(46, 'M', CMD)], ['Full Screen', sc(3, 'F', CTRL | CMD)], ['Spotlight', sc(49, 'Space', CMD)],
  ['Lock Screen', sc(12, 'Q', CTRL | CMD)], ['Copy', sc(8, 'C', CMD)], ['Paste', sc(9, 'V', CMD)], ['Cut', sc(7, 'X', CMD)],
  ['Undo', sc(6, 'Z', CMD)], ['Redo', sc(6, 'Z', CMD | SHIFT)], ['Select All', sc(0, 'A', CMD)], ['Save', sc(1, 'S', CMD)],
  ['Find', sc(3, 'F', CMD)], ['Screenshot', sc(21, '4', CMD | SHIFT)], ['Screenshot and Recording', sc(23, '5', CMD | SHIFT)],
  ['Emoji & Symbols', sc(49, 'Space', CTRL | CMD)],
];
const HOLD_PRESETS = [['Wispr Flow', sc(49, 'Space', CTRL)]];
const CLICK_PRESETS = [
  ['Control-click', 0, CTRL], ['Control-right-click', 1, CTRL], ['Command-click', 0, CMD],
  ['Shift-click', 0, SHIFT], ['Option-click', 0, ALT],
];
const SIMPLE_TITLES = {
  system: 'Default', leftClick: 'Left click', rightClick: 'Right click', middleClick: 'Middle click', back: 'Back',
  forward: 'Forward', disabled: 'Do nothing', precisionHold: 'Precision (hold)', precisionToggle: 'Precision (toggle)',
  ballScrollHold: 'Scroll with ball (hold)', dragLock: 'Drag lock',
};
export const MEDIA_TITLES = { 0: 'Volume Up', 1: 'Volume Down', 7: 'Mute', 16: 'Play or Pause', 17: 'Next Track', 18: 'Previous Track' };
const sameKeys = (a, b) => a.keyCode === b.keyCode && a.modifiers === b.modifiers && a.keyName === b.keyName;

/** What a button does without Glideball. */
export function normalTitle(button) {
  return ['Left click', 'Right click', 'Middle click', 'Back'][button] || 'Default';
}

export function isNormal(action, button) {
  if (!action || action.type === 'system') return true;
  const normal = ['leftClick', 'rightClick', 'middleClick', 'back'][button];
  return normal !== undefined && action.type === normal;
}

/** An action in the app's words (ImportReview.describe). `button` says what Default means. */
export function describeAction(a, button) {
  if (!a) return 'Default';
  if (a.type === 'system' && button !== undefined) return normalTitle(button);
  if (SIMPLE_TITLES[a.type]) return SIMPLE_TITLES[a.type];
  switch (a.type) {
    case 'shortcut':
    case 'holdShortcut': {
      const keys = shortcutText(a);
      const list = a.type === 'shortcut' ? SHORTCUT_PRESETS : HOLD_PRESETS;
      const preset = list.find(([, s]) => sameKeys(s, a));
      if (preset && preset[0] !== keys) return `${preset[0]} (${keys})`;
      return a.type === 'holdShortcut' ? `Hold ${keys}` : keys;
    }
    case 'modifiedClick': {
      const p = CLICK_PRESETS.find(([, b, m]) => b === a.button && m === a.modifiers);
      return p ? p[0] : 'Custom';
    }
    case 'media': return MEDIA_TITLES[a.key] || 'Custom';
    case 'openApp': return `Open ${a.bundleID}`;
    case 'gesture': {
      const parts = [];
      for (const [dir, arrow] of [['up', '↑'], ['down', '↓'], ['left', '←'], ['right', '→']]) {
        if (a.steps[dir]) parts.push(`${arrow} ${describeAction(a.steps[dir].action)}`);
      }
      if (a.tap && a.tap.type !== 'system') parts.push(`tap: ${describeAction(a.tap)}`);
      return parts.length ? `Gesture: ${parts.join(', ')}` : 'Gesture';
    }
    default: return 'Custom';
  }
}

/** Opens an app or presses keys: worth pointing out. */
export function needsCaution(a) {
  if (!a) return false;
  if (a.type === 'openApp' || a.type === 'shortcut' || a.type === 'holdShortcut') return true;
  if (a.type === 'gesture') return Object.values(a.steps).some((s) => needsCaution(s.action)) || needsCaution(a.tap);
  return false;
}

export function buttonName(b) {
  return ['Bottom left', 'Bottom right', 'Top left', 'Top right'][b] || `Button ${b + 1}`;
}

export function comboName(buttons) {
  return buttons.map(buttonName).join(' + ');
}

/** 4, 6.5, 0.25: as Swift's `formatted()` writes them. */
export function fmt(v) {
  return String(Math.round(v * 1000) / 1000);
}
export const twoDigits = (v) => String(Number(v.toPrecision(2)));
export const percent = (v) => `${Math.trunc(Math.round(v * 1e6) / 1e4)}%`;
export const glideMs = (glide) => Math.trunc((0.04 + Math.min(Math.max(glide, 0), 1) * 0.12) * 1000);
export const MODE_TITLES = { native: 'Native', flywheel: 'Flywheel', follow: 'Follow' };

/** "Flywheel, glide 82 ms, 4 pt a slow turn": one line about a scroll feel. */
export function scrollLine(s) {
  switch (s.scrollMode) {
    case 'native': return `Native, speed ${s.nativeScrollSpeed.toFixed(2)}`;
    case 'follow': return `Follow, ${Math.trunc(s.scrollDistance)} pt a tick`;
    default: return `Flywheel, glide ${glideMs(s.flyGlide)} ms, ${Math.trunc(s.flyDistance)} pt a slow turn`;
  }
}

/** Every scroll setting that matters in its mode, as [title, value] rows. */
export function scrollRows(s) {
  const onOff = (b) => (b ? 'On' : 'Off');
  const rows = [['Scroll mode', MODE_TITLES[s.scrollMode]]];
  if (s.scrollMode === 'native') {
    rows.push(['Native speed', s.nativeScrollSpeed.toFixed(2)]);
  } else if (s.scrollMode === 'flywheel') {
    rows.push(['Glide', `${glideMs(s.flyGlide)} ms`], ['Slow-turn distance', `${Math.trunc(s.flyDistance)} pt`],
      ['Spin power', percent(s.flyAcceleration)], ['Fast-spin reach', percent(s.flyReach)]);
  } else {
    rows.push(['Distance per tick', `${Math.trunc(s.scrollDistance)} pt`], ['Smoothness', percent(s.scrollSmoothness)],
      ['Acceleration', percent(s.scrollAcceleration)], ['Throw', s.throwEnabled ? percent(s.throwAmount) : 'Off']);
  }
  rows.push(['Smooth scrolling', onOff(s.smoothScrolling)], ['Reverse direction', onOff(s.reverseScroll)],
    ['⇧ scrolls sideways', onOff(s.shiftScrollsHorizontally)]);
  return rows;
}

export const THEME_TITLES = {
  orb: 'Orb', ember: 'Ember', sunset: 'Sunset', ocean: 'Ocean', forest: 'Forest', graphite: 'Graphite',
  classic: 'Classic red', custom: 'Custom',
};
export const DISTANCE_TITLES = { short: 'Short', normal: 'Normal', long: 'Long' };
export const SOUND_TITLES = {
  pauseResume: 'Pause and resume', modes: 'Modes on and off', ticks: 'Slider and switch ticks',
  milestones: 'Milestones and records', buttons: 'Button presses on the Buttons page',
};

// The ball's colors: light, mid, low and accent (BallTheme.curated in Theme.swift).
const THEMES = {
  orb: ['35D6FF', '3D6BFF', '8A5CFF', 'F056D8'],
  ember: ['FFC24D', 'FF6A1F', 'B0141E', 'FF3D73'],
  sunset: ['FFC873', 'FF6B66', '7A2FA6', 'FF5FB4'],
  ocean: ['4DF2E6', '0D8CD9', '142E99', '66FFB3'],
  forest: ['B8F26B', '26A659', '0D4D40', 'F2CC4D'],
  graphite: ['DDE0E6', '80858F', '383A42', 'B3B8C2'],
  classic: ['FF6B57', 'D9141A', '73050D', 'FF4033'],
};

function mix(a, b, t) {
  const pa = [0, 2, 4].map((i) => parseInt(a.slice(i, i + 2), 16));
  const pb = [0, 2, 4].map((i) => parseInt(b.slice(i, i + 2), 16));
  return pa.map((x, i) => Math.round(x + (pb[i] - x) * t).toString(16).padStart(2, '0')).join('').toUpperCase();
}

/** The four colors a (checked) look throws, as six-digit hex. Unknown: the Orb. */
export function lookColors(look) {
  if (look && look.theme === 'custom' && Array.isArray(look.custom) && look.custom.length === 3
      && look.custom.every((c) => HEX6.test(c))) {
    const [light, mid, low] = look.custom;
    return [light, mid, low, mix(mix(mid, light, 0.5), 'FFFFFF', 0.2)];
  }
  return THEMES[look && look.theme] || THEMES.orb;
}

/** "Pointer feel", "Safari setup"… for a part id. */
export function partTitle(id, share) {
  if (id.startsWith('app:')) {
    const app = share && share.apps && share.apps.find((a) => 'app:' + a.bundleID === id);
    return app ? `${app.name} setup` : 'An app setup';
  }
  return {
    pointer: 'Pointer feel', displays: 'Per-display speeds', scrolling: 'Scroll feel', buttons: 'Buttons',
    combos: 'Combos', gestures: 'Gestures', look: 'Ball color and look', sounds: 'Sounds',
  }[id] || id;
}

/** "Pointer feel, scroll feel, buttons and 2 app setups" */
export function summary(share) {
  const names = [];
  let apps = 0;
  for (const p of share.parts) {
    if (p.startsWith('app:')) { apps += 1; continue; }
    names.push(partTitle(p).toLowerCase());
  }
  if (apps === 1) names.push(`the ${share.apps[0].name} setup`);
  else if (apps > 1) names.push(`${apps} app setups`);
  if (!names.length) return '';
  const text = names.length === 1 ? names[0] : `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`;
  return text.charAt(0).toUpperCase() + text.slice(1);
}
