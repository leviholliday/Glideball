/* Glideball: the shared-setup page, /s/#<payload>.
   share-decode.js checks the payload (docs/SHARE-FORMAT.md); this file shows it.
   Everything from the payload goes on the page as text (textContent) and nothing
   else: no markup, no URLs, no images, no styles, except the ball's three checked
   hex colors, set as CSS custom properties. The glideball:// link is built from
   the payload only after it passed every check. Nothing here sends anything
   anywhere (the page's CSP has connect-src 'none'). */
import {
  decodePayload, canInflate, glideballLink, describeAction, isNormal, needsCaution, buttonName, comboName,
  scrollRows, scrollLine, lookColors, partTitle, summary, fmt, twoDigits, percent, MODE_TITLES, THEME_TITLES,
  DISTANCE_TITLES, SOUND_TITLES, SOUND_KINDS,
} from './share-decode.js';

const root = document.querySelector('[data-share]');
const $ = (sel) => root.querySelector(sel);

/** A new element with a class and text; children appended in order. */
function el(tag, cls, text, ...kids) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined && text !== null) n.textContent = String(text);
  for (const k of kids) if (k) n.append(k);
  return n;
}

const PART_TONE = {
  pointer: 'ball', displays: 'ball', scrolling: 'ring', buttons: 'buttons', combos: 'buttons',
  gestures: 'buttons', look: 'orb', sounds: 'plain',
};

// ------------------------------------------------------------------ the ball's colors
function useColors(look) {
  const [light, mid, low, accent] = lookColors(look);
  const s = document.documentElement.style;
  s.setProperty('--sb-light', '#' + light);
  s.setProperty('--sb-mid', '#' + mid);
  s.setProperty('--sb-low', '#' + low);
  s.setProperty('--sb-accent', '#' + accent);
}

// ------------------------------------------------------------------ rows and cards
function rows(list) {
  const dl = el('dl', 'sh-rows');
  for (const [title, value, opts = {}] of list) {
    const row = el('div', 'sh-row' + (opts.caution ? ' sh-row-caution' : '') + (opts.dim ? ' sh-row-dim' : ''));
    row.append(el('dt', null, title), el('dd', null, value));
    if (opts.caution) row.append(el('span', 'sh-caution', 'Opens an app or presses keys'));
    dl.append(row);
  }
  return dl;
}

function card(id, share, ...body) {
  const tone = PART_TONE[id] || (id.startsWith('app:') ? 'plain' : 'plain');
  const c = el('article', `card sh-card sh-tone-${tone}`);
  const head = el('header', 'sh-card-head');
  head.append(el('span', 'sh-dot', null), el('h2', 'sh-card-h', partTitle(id, share)));
  c.append(head, ...body.filter(Boolean));
  return c;
}

const onOff = (b) => (b ? 'On' : 'Off');

function pointerCard(share) {
  const p = share.pointer;
  const list = [];
  if (p.trackingSpeed !== undefined) list.push(['Pointer speed', fmt(p.trackingSpeed)]);
  if (p.precisionSpeed !== undefined) list.push(['Precision speed', fmt(p.precisionSpeed)]);
  const big = p.trackingSpeed !== undefined
    ? el('p', 'sh-big', null, el('span', 'sh-big-n', fmt(p.trackingSpeed)), el('span', 'sh-big-l', 'pointer speed'))
    : null;
  return card('pointer', share, big, rows(list));
}

function displaysCard(share) {
  const d = share.displays;
  const list = [['Per-display speeds', onOff(d.enabled)]];
  for (const x of d.list) list.push([x.name || 'A display', fmt(x.speed)]);
  return card('displays', share, rows(list),
    el('p', 'sh-note', 'These only match the same displays, so they’re mostly for moving a setup to another of your own Macs.'));
}

function scrollingCard(share) {
  const s = share.scrolling;
  const list = s.scroll ? scrollRows(s.scroll) : [];
  if (s.ballScrollSpeed !== undefined) list.push(['Scroll with ball speed', '×' + twoDigits(s.ballScrollSpeed)]);
  const big = s.scroll
    ? el('p', 'sh-big', null, el('span', 'sh-big-n', MODE_TITLES[s.scroll.scrollMode]), el('span', 'sh-big-l', 'scroll mode'))
    : null;
  return card('scrolling', share, big, rows(list));
}

/** The trackball seen from above, with what each corner does. `short`: a gesture is just
    "Gesture" here, because the Gestures card spells it out. */
function diagram(buttons, short) {
  const wrap = el('div', 'sh-map');
  const corners = [[2, 'tl'], [3, 'tr'], [0, 'bl'], [1, 'br']];
  const art = el('div', 'sh-map-art');
  art.setAttribute('aria-hidden', 'true');
  art.append(el('div', 'sh-map-body'));
  for (const [b, pos] of corners) {
    const changed = b !== 0 && buttons[b] && !isNormal(buttons[b], b);
    art.append(el('div', `sh-map-pad sh-map-${pos}` + (changed ? ' on' : '')));
  }
  art.append(el('div', 'sh-map-ring'), el('div', 'sh-map-ball'));
  wrap.append(art);
  for (const [b, pos] of corners) {
    const a = b === 0 ? { type: 'leftClick' } : buttons[b];
    const label = el('div', `sh-map-label sh-map-label-${pos}` + (b !== 0 && a && !isNormal(a, b) ? ' on' : ''));
    const gestureHere = short && a && a.type === 'gesture';
    const what = !a ? 'Stays as it is' : gestureHere ? 'Gesture (see Gestures)' : describeAction(a, b);
    label.append(el('span', 'sh-map-what', what),
      el('span', 'sh-map-where', b === 0 ? 'Bottom left, always a left click' : buttonName(b)));
    if (b !== 0 && a && needsCaution(a) && !gestureHere) label.append(el('span', 'sh-caution', 'Opens an app or presses keys'));
    wrap.append(label);
  }
  return wrap;
}

function buttonsCard(share, gesturesToo) {
  const buttons = share.buttons || {};
  const list = [];
  for (let b = 4; b <= 7; b++) {
    const a = buttons[b];
    if (a && !isNormal(a, b)) list.push([buttonName(b), describeAction(a, b), { caution: needsCaution(a) }]);
  }
  const id = share.parts.includes('buttons') ? 'buttons' : 'gestures';
  const body = [diagram(buttons, !gesturesToo && share.parts.includes('gestures'))];
  if (list.length) body.push(rows(list));
  if (gesturesToo && share.gestures) body.push(gestureSettings(share.gestures));
  return card(id, share, ...body);
}

function gestureSettings(g) {
  const list = [];
  if (g.enabled !== undefined) list.push(['Gestures', onOff(g.enabled)]);
  if (g.distance !== undefined) list.push(['Gesture distance', DISTANCE_TITLES[g.distance]]);
  if (g.steadyHands !== undefined) list.push(['Steady hands', onOff(g.steadyHands)]);
  return list.length ? rows(list) : null;
}

function gesturesCard(share) {
  const buttons = share.buttons || {};
  const list = [];
  for (let b = 1; b <= 7; b++) {
    const a = buttons[b];
    if (a && a.type === 'gesture') list.push([buttonName(b), describeAction(a, b), { caution: needsCaution(a) }]);
  }
  return card('gestures', share, list.length ? rows(list) : null, gestureSettings(share.gestures));
}

function combosCard(share) {
  const list = share.chords.map((c) => [comboName(c.buttons), describeAction(c.action), { caution: needsCaution(c.action) }]);
  if (!list.length) return card('combos', share, el('p', 'sh-note', 'No combos. Importing this removes yours.'));
  return card('combos', share, rows(list));
}

function appCard(id, share) {
  const app = share.apps.find((a) => 'app:' + a.bundleID === id);
  const list = [['App', app.bundleID]];
  if (app.trackingSpeed !== undefined) list.push(['Pointer speed', fmt(app.trackingSpeed)]);
  if (app.scroll) list.push(['Scrolling', scrollLine(app.scroll)]);
  for (const [b, a] of Object.entries(app.buttons || {})) {
    if (!isNormal(a, Number(b))) list.push([buttonName(Number(b)), describeAction(a, Number(b)), { caution: needsCaution(a) }]);
  }
  for (const c of app.chords || []) list.push([comboName(c.buttons), describeAction(c.action), { caution: needsCaution(c.action) }]);
  if (list.length === 1) list.push(['Everything else', 'Same as the main setup']);
  return card(id, share, rows(list));
}

function lookCard(share) {
  const colors = lookColors(share.look);
  const swatches = el('div', 'sh-swatches');
  swatches.setAttribute('aria-hidden', 'true');
  colors.forEach((_, i) => swatches.append(el('span', `sh-swatch sh-swatch-${i}`)));
  return card('look', share, el('p', 'sh-big', null, el('span', 'sh-big-n', THEME_TITLES[share.look.theme]), el('span', 'sh-big-l', 'ball color')),
    swatches,
    share.look.theme === 'custom' ? rows([['Colors', share.look.custom.map((h) => '#' + h).join(', ')]]) : null);
}

function soundsCard(share) {
  const s = share.sounds;
  const list = [['Sounds', onOff(s.on)], ['Volume', percent(s.volume)]];
  for (const k of SOUND_KINDS) if (k in s.kinds) list.push([SOUND_TITLES[k], onOff(s.kinds[k]), { dim: !s.on }]);
  return card('sounds', share, rows(list));
}

function partCards(share) {
  const out = [];
  const has = (p) => share.parts.includes(p);
  for (const id of share.parts) {
    if (id === 'pointer') out.push(pointerCard(share));
    else if (id === 'displays') out.push(displaysCard(share));
    else if (id === 'scrolling') out.push(scrollingCard(share));
    else if (id === 'buttons') out.push(buttonsCard(share, false));
    else if (id === 'combos') out.push(combosCard(share));
    else if (id === 'gestures') out.push(has('buttons') ? gesturesCard(share) : buttonsCard(share, true));
    else if (id.startsWith('app:')) out.push(appCard(id, share));
    else if (id === 'look') out.push(lookCard(share));
    else if (id === 'sounds') out.push(soundsCard(share));
  }
  return out;
}

// ------------------------------------------------------------------ the page's states
function setText(sel, text) {
  const n = $(sel);
  if (n) n.textContent = text;
}

function showShare(d, share) {
  root.dataset.state = 'share';
  useColors(share.look);
  setText('[data-eyebrow]', 'A shared Glideball setup');
  const title = share.from ? `${share.from}’s Glideball setup` : 'A Glideball setup, shared with you';
  setText('[data-title]', title);
  document.title = `${title} · Glideball`;
  const from = $('[data-from]');
  if (share.from) {
    from.replaceChildren(el('span', 'sh-from-label', 'From'), el('b', 'sh-from-name', share.from),
      el('span', 'sh-from-why', 'That’s the name they typed in Glideball. Nobody checks it, so trust the link only if you trust where it came from.'));
    from.hidden = false;
  } else {
    from.hidden = true;
  }
  const count = share.parts.length;
  setText('[data-lede]', `${summary(share)}. ${count === 1 ? 'That’s the one part' : `Those are the ${count} parts`} in this link; everything else stays as you have it.`);

  const link = glideballLink(d);
  const imp = $('[data-import]');
  if (link) imp.href = link;
  $('[data-actions]').hidden = !link;
  $('[data-import-note]').hidden = !link;
  $('[data-fallback]').hidden = !!link;

  const parts = $('[data-parts]');
  const head = el('div', 'sh-parts-head');
  head.append(el('h2', 'sh-parts-h', 'What’s in it'),
    el('p', 'sh-parts-sub', 'In Glideball you’ll see each of these next to what you have now, and you can leave any of them out.'));
  const grid = el('div', 'sh-grid');
  grid.append(...partCards(share));
  parts.replaceChildren(head, grid);
  parts.hidden = false;
}

const PROBLEMS = {
  empty: ['There’s no setup in this link', 'Someone shares a setup from Glideball with Share…, and the link they send has the settings after a #. This one doesn’t have any, so there’s nothing to show.'],
  noBrowserSupport: ['This browser can’t read the setup', 'The settings in this link are compressed, and this browser is too old to unpack them. Open the link in a current Safari, Chrome or Firefox, or open it in Glideball.'],
  tooBig: ['This link is too big to be a setup', 'A shared setup fits in a couple of thousand characters, and this one is far bigger, so it wasn’t read. Ask whoever sent it to send the settings file instead.'],
  default: ['This link doesn’t look right', 'It might have been cut short when it was copied, or it isn’t a Glideball setup at all. Ask whoever sent it to copy the link again, or to send the settings file instead.'],
};

function showProblem(reason) {
  root.dataset.state = 'problem';
  useColors(null);
  const [title, text] = PROBLEMS[reason] || PROBLEMS.default;
  setText('[data-eyebrow]', 'A shared Glideball setup');
  setText('[data-title]', title);
  setText('[data-lede]', text);
  document.title = `${title} · Glideball`;
  $('[data-from]').hidden = true;
  $('[data-actions]').hidden = true;
  $('[data-import-note]').hidden = true;
  $('[data-fallback]').hidden = false;
  $('[data-parts]').hidden = true;
}

/** The payload from the address: everything after #, with an optional "d=". */
function payloadFromHash() {
  let h = location.hash.slice(1);
  if (h.startsWith('d=')) h = h.slice(2);
  return h;
}

let generation = 0;
async function render() {
  const mine = ++generation;
  const d = payloadFromHash();
  if (!d) return showProblem('empty');
  if (!canInflate()) return showProblem('noBrowserSupport');
  let result;
  try {
    result = await decodePayload(d);
  } catch {
    result = { ok: false, reason: 'default' };
  }
  if (mine !== generation) return;   // the address changed while it was reading
  if (result.ok) showShare(d, result.share);
  else showProblem(result.reason);
}

// ------------------------------------------------------------------ copy link
function initCopy() {
  const button = $('[data-copy]');
  const label = $('[data-copy-label]');
  let timer = 0;
  button.addEventListener('click', async () => {
    let ok = false;
    try {
      await navigator.clipboard.writeText(location.href);
      ok = true;
    } catch {
      // Older browsers: select a hidden field and copy that.
      const field = document.createElement('textarea');
      field.value = location.href;
      field.setAttribute('readonly', '');
      field.className = 'sr-only';
      document.body.append(field);
      field.select();
      try { ok = document.execCommand('copy'); } catch { ok = false; }
      field.remove();
    }
    label.textContent = ok ? 'Copied' : 'Couldn’t copy';
    button.classList.toggle('copied', ok);
    clearTimeout(timer);
    timer = setTimeout(() => { label.textContent = 'Copy link'; button.classList.remove('copied'); }, 2200);
  });
}

initCopy();
window.addEventListener('hashchange', render);
render();
