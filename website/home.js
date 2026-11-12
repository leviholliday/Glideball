/* Glideball home page: the trackball lights the room, and the page is the demo.
   Vanilla JS, no dependencies, no tracking, nothing stored or sent.

   One rule for motion: nothing runs while you're not doing anything. Input bumps
   a few light values (ball blue, ring pink, button amber) and velocities; one
   requestAnimationFrame loop runs only while any of them is above zero, lets
   them glide back down, and then stops itself. Toys sleep while off screen. */
(() => {
  'use strict';

  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)');
  const coarse = window.matchMedia('(pointer: coarse)');
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  const fmt = (n) => Math.round(n).toLocaleString('en-US');
  const $ = (sel, el = document) => el.querySelector(sel);
  const $$ = (sel, el = document) => Array.from(el.querySelectorAll(sel));
  // Scroll right now, whatever html's scroll-behavior says. ("instant" as a behavior is
  // newer than some Safari versions, so smooth scrolling is turned off for this one call.)
  const jumpTo = (top) => {
    const st = document.documentElement.style;
    st.scrollBehavior = 'auto';
    window.scrollTo(0, top);
    st.scrollBehavior = '';
  };
  const glideTo = (top) => { if (reduce.matches) jumpTo(top); else window.scrollTo({ top, behavior: 'smooth' }); };
  const params = new URLSearchParams(location.search);
  const demo = params.get('demo') || ''; // screenshot states, e.g. ?demo=roll (harmless otherwise)

  const PART_RGB = { ball: '77, 168, 255', ring: '255, 92, 168', buttons: '255, 179, 64' };
  const CORNER = { tl: 'Top left', tr: 'Top right', bl: 'Bottom left', br: 'Bottom right' };
  const ACTIONS = {
    mission: 'Mission Control',
    spotlight: 'Spotlight',
    next: 'Next Space',
    prev: 'Previous Space',
    right: 'Right click',
    none: 'Do nothing',
  };
  // An example setup. The Buttons section below changes it.
  const assign = { tl: 'mission', tr: 'next', br: 'right', bl: 'left' };
  const combos = { 'br+tr': 'mission', 'tl+tr': 'spotlight' };
  const comboKey = (a, b) => [a, b].sort((x, y) => ['br', 'tl', 'tr', 'bl'].indexOf(x) - ['br', 'tl', 'tr', 'bl'].indexOf(y)).join('+');

  const hero = $('.hero');
  const hx = $('[data-hx]');
  const stage = $('[data-tb-stage]');
  if (!hero || !hx || !stage) return;

  /* ============================================================ The light engine */
  const light = { ball: 0, ring: 0, amber: 0 };
  const LIGHT_TAU = { ball: 520, ring: 560, amber: 380 };
  const BALL_TAU = 650;   // how long a rolled ball coasts
  const PAGE_TAU = 300;   // how long a flicked ring keeps the page gliding
  const K = 0.2;          // degrees of ring per pixel of page (one 6° notch ≈ 30 px)

  let frozen = false;     // set by ?demo= so a screenshot holds still
  let heroVisible = true;
  let raf = 0;
  let lastT = 0;

  // Ball
  let rx = 0; let ry = 0; let vx = 0; let vy = 0;
  let ballDrag = false;
  let aimX = 0; let aimY = 0; let lx = 0; let ly = 0;
  // Ring
  let angle = 0;
  let ringDrag = false;
  let pageV = 0;          // px per ms, from a flicked ring
  let sweepDir = 1;
  // Dock
  let dockV = 0;

  const bump = (k, v) => { light[k] = Math.max(light[k], clamp(v, 0, 1)); wake(); };
  const wake = () => { if (!raf) { lastT = performance.now(); raf = requestAnimationFrame(frame); } };

  const sweep = $('.tb-sweep', stage);
  const dock = $('[data-dock]');
  let orbSize = 0;
  const measure = () => { orbSize = $('.tb-orb', stage).getBoundingClientRect().width || 280; };
  measure();
  window.addEventListener('resize', measure, { passive: true });

  function apply() {
    if (heroVisible) {
      const tile = orbSize * 1.6;
      const s = hero.style;
      s.setProperty('--l-ball', light.ball.toFixed(3));
      s.setProperty('--l-ring', light.ring.toFixed(3));
      s.setProperty('--l-amber', light.amber.toFixed(3));
      s.setProperty('--lx', lx.toFixed(3));
      s.setProperty('--ly', ly.toFixed(3));
      const st = stage.style;
      st.setProperty('--rx', (((rx % tile) + tile) % tile).toFixed(1));
      st.setProperty('--ry', (((ry % tile) + tile) % tile).toFixed(1));
      const sp = Math.hypot(vx, vy);
      st.setProperty('--sx', clamp(vx / 2.5, -1, 1).toFixed(3));
      st.setProperty('--sy', clamp(vy / 2.5, -1, 1).toFixed(3));
      st.setProperty('--ss', clamp(sp / 3, 0, 1).toFixed(3));
      st.setProperty('--sa', `${(Math.atan2(vy, vx) * 180 / Math.PI).toFixed(1)}deg`);
      hero.style.setProperty('--ring', `${angle.toFixed(2)}deg`);
      if (sweep) sweep.classList.toggle('rev', sweepDir < 0);
    }
    if (dock) dock.style.setProperty('--dv', dockV.toFixed(3));
    if (liveEl && liveVisible) {
      const s = liveEl.style;
      s.setProperty('--l-ball', light.ball.toFixed(3));
      s.setProperty('--l-ring', light.ring.toFixed(3));
      s.setProperty('--l-amber', light.amber.toFixed(3));
    }
  }
  // The Overview cluster further down shares these lights while it's on screen.
  const liveEl = $('[data-live]');
  let liveVisible = false;

  function frame(t) {
    const dt = clamp(t - lastT, 1, 64);
    lastT = t;
    let active = ballDrag || ringDrag;

    if (!ballDrag && !frozen) {
      if (Math.abs(vx) + Math.abs(vy) > 0.002) {
        const k = Math.exp(-dt / BALL_TAU);
        rx += vx * BALL_TAU * (1 - k);
        ry += vy * BALL_TAU * (1 - k);
        vx *= k; vy *= k;
        active = true;
      } else { vx = 0; vy = 0; }
    }

    if (pageV && !ringDrag) {
      const k = Math.exp(-dt / PAGE_TAU);
      const d = pageV * PAGE_TAU * (1 - k);
      pageV *= k;
      const before = window.scrollY;
      jumpTo(window.scrollY + d);
      if (Math.abs(pageV) < 0.01 || window.scrollY === before) pageV = 0;
      else active = true;
    }

    if (!frozen) {
      for (const key of ['ball', 'ring', 'amber']) {
        if (light[key] > 0.003) { light[key] *= Math.exp(-dt / LIGHT_TAU[key]); active = true; }
        else light[key] = 0;
      }
      if (dockV > 0.003) { dockV *= Math.exp(-dt / 500); active = true; } else dockV = 0;
    }

    const f = 1 - Math.exp(-dt / 140);
    lx += (aimX - lx) * f;
    ly += (aimY - ly) * f;
    if (Math.abs(aimX - lx) + Math.abs(aimY - ly) > 0.002) active = true;

    apply();
    raf = active ? requestAnimationFrame(frame) : 0;
  }

  if ('IntersectionObserver' in window) {
    new IntersectionObserver(([e]) => {
      heroVisible = e.isIntersecting;
      if (dock) {
        const past = !e.isIntersecting && e.boundingClientRect.top < 0;
        dock.hidden = false;
        dock.classList.toggle('show', past || demo === 'dock');
      }
      if (heroVisible) wake();
    }, { rootMargin: '80px 0px' }).observe(hx);
  }

  /* ============================================================ The live line under the trackball */
  const nowEl = $('[data-tb-now]');
  const nowText = $('[data-tb-now-text]');
  const live = $('[data-tb-live]');
  const DEFAULT_NOW = nowText ? nowText.textContent : '';
  let nowTimer = 0;
  function say(label, text, tone, { announce = false, hold = 3200 } = {}) {
    if (!nowText) return;
    nowText.textContent = '';
    if (label) {
      const b = document.createElement('b');
      b.textContent = label;
      nowText.append(b, document.createTextNode(` ${text}`));
    } else nowText.textContent = text;
    nowEl.dataset.tone = tone || '';
    if (announce && live) live.textContent = `${label ? `${label} ` : ''}${text}`;
    clearTimeout(nowTimer);
    if (hold && !frozen) nowTimer = setTimeout(() => { nowText.textContent = DEFAULT_NOW; nowEl.dataset.tone = ''; }, hold);
  }
  const chip = (k, on) => {
    const c = $(`[data-chip="${k}"]`, hx);
    const l = $(`[data-line="${k}"]`, hx);
    if (c) c.classList.toggle('on', on);
    if (l) l.classList.toggle('on', on);
  };

  /* ============================================================ The ball: drag it, or just move your mouse */
  let speedName = 'Turbo';
  let speedRatio = 2.5; // the pointer page's setting, relative to System Settings' fastest
  const ballEl = $('[data-tb-ball]', stage);
  {
    let trail = [];
    let px = 0; let py = 0;
    let id = null;
    ballEl.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;
      e.preventDefault();
      id = e.pointerId;
      try { ballEl.setPointerCapture(id); } catch (_) { /* ignore */ }
      ballDrag = true;
      stage.classList.add('grabbing');
      vx = 0; vy = 0;
      px = e.clientX; py = e.clientY;
      trail = [{ t: e.timeStamp, x: 0, y: 0 }];
      chip('ball', true);
      wake();
    });
    let sx = 0; let sy = 0;
    ballEl.addEventListener('pointermove', (e) => {
      if (!ballDrag || e.pointerId !== id) return;
      const dx = e.clientX - px;
      const dy = e.clientY - py;
      px = e.clientX; py = e.clientY;
      rx += dx; ry += dy;
      sx += dx; sy += dy;
      trail.push({ t: e.timeStamp, x: sx, y: sy });
      while (trail.length > 2 && e.timeStamp - trail[0].t > 90) trail.shift();
      const a = trail[0];
      const span = Math.max(8, e.timeStamp - a.t);
      vx = (sx - a.x) / span; vy = (sy - a.y) / span;
      const sp = Math.hypot(vx, vy);
      bump('ball', 0.25 + sp / 2.2);
      aimX = clamp(vx / 2, -1, 1); aimY = clamp(vy / 2, -1, 1);
      readout(sp);
    });
    const end = (e) => {
      if (!ballDrag || e.pointerId !== id) return;
      ballDrag = false;
      stage.classList.remove('grabbing');
      chip('ball', false);
      if (!trail.length || e.timeStamp - trail[trail.length - 1].t > 80) { vx = 0; vy = 0; }
      readout(Math.hypot(vx, vy), true);
      aimX = 0; aimY = 0;
      wake();
    };
    ballEl.addEventListener('pointerup', end);
    ballEl.addEventListener('pointercancel', end);
    ballEl.addEventListener('keydown', (e) => {
      const map = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] };
      const d = map[e.key];
      if (!d) return;
      e.preventDefault();
      vx += d[0] * 1.6; vy += d[1] * 1.6;
      bump('ball', 0.7);
      readout(Math.hypot(vx, vy), true);
      wake();
    });
  }
  let readoutShown = 0;
  function readout(sp, final) {
    // A flick of the ball, as the pointer speed it would give at the Pointer section's setting.
    const v = Math.round((sp * 1000 * speedRatio) / 10) * 10;
    if (!final && Math.abs(v - readoutShown) < 40) return;
    readoutShown = v;
    say(`Pointer at ${speedName}:`, `${fmt(v)} px/s`, 'ball', { announce: !!final, hold: final ? 3600 : 1200 });
  }

  // The visitor's own mouse or trackball rolls the ball, a little, while the hero is in view.
  let lastMove = 0;
  window.addEventListener('pointermove', (e) => {
    if (e.pointerType !== 'mouse' || ballDrag || ringDrag || !heroVisible || reduce.matches) return;
    const dt = Math.max(8, e.timeStamp - (lastMove || e.timeStamp - 16));
    lastMove = e.timeStamp;
    const dx = e.movementX || 0;
    const dy = e.movementY || 0;
    if (!dx && !dy) return;
    rx += dx * 0.55; ry += dy * 0.55;
    // Light leans toward where the pointer is, relative to the ball.
    const r = stage.getBoundingClientRect();
    const reach = Math.max(window.innerWidth, window.innerHeight) * 0.5;
    aimX = clamp((e.clientX - (r.left + r.width / 2)) / reach, -1, 1);
    aimY = clamp((e.clientY - (r.top + r.height / 2)) / reach, -1, 1);
    const sp = Math.hypot(dx, dy) / dt;
    vx = vx * 0.6 + (dx * 0.55 / dt) * 0.4 * 0.5;
    vy = vy * 0.6 + (dy * 0.55 / dt) * 0.4 * 0.5;
    if (sp > 0.4) bump('ball', Math.min(0.55, (sp - 0.4) / 5));
    wake();
  }, { passive: true });

  /* ============================================================ The ring: page scroll turns it; flick it to scroll */
  const ringEl = $('[data-tb-ring]', stage);
  let lastY = window.scrollY;
  let lastScrollT = performance.now();
  window.addEventListener('scroll', () => {
    const y = window.scrollY;
    const t = performance.now();
    const dy = y - lastY;
    const dt = Math.max(t - lastScrollT, 8);
    lastY = y; lastScrollT = t;
    const v = Math.abs(dy) / dt; // px per ms
    if (dock) dockV = Math.max(dockV, clamp(v / 4, 0, 1));
    if (!ringDrag && dy) {
      angle += dy * K;
      sweepDir = dy > 0 ? 1 : -1;
      if (heroVisible && !reduce.matches) bump('ring', v / 3);
    }
    updateDock();
    wake();
  }, { passive: true });
  // A wheel at the very top (or bottom) can't scroll the page, but it still turns the ring.
  window.addEventListener('wheel', (e) => {
    if (!heroVisible || e.ctrlKey) return;
    const atTop = window.scrollY <= 0 && e.deltaY < 0;
    if (!atTop) return;
    angle += e.deltaY * K;
    sweepDir = -1;
    bump('ring', Math.min(1, Math.abs(e.deltaY) / 120));
  }, { passive: true });
  {
    let id = null;
    let cx = 0; let cy = 0; let prevA = 0; let acc = 0;
    let trail = [];
    ringEl.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;
      e.preventDefault();
      id = e.pointerId;
      try { ringEl.setPointerCapture(id); } catch (_) { /* ignore */ }
      const r = stage.getBoundingClientRect();
      cx = r.left + r.width / 2; cy = r.top + r.height / 2;
      prevA = Math.atan2(e.clientY - cy, e.clientX - cx);
      ringDrag = true; pageV = 0; acc = 0;
      trail = [{ t: e.timeStamp, a: 0 }];
      stage.classList.add('grabbing');
      chip('ring', true);
      wake();
    });
    ringEl.addEventListener('pointermove', (e) => {
      if (!ringDrag || e.pointerId !== id) return;
      const a = Math.atan2(e.clientY - cy, e.clientX - cx);
      let d = a - prevA;
      if (d > Math.PI) d -= 2 * Math.PI;
      if (d < -Math.PI) d += 2 * Math.PI;
      prevA = a;
      const deg = d * 180 / Math.PI;
      angle += deg; acc += deg;
      sweepDir = deg >= 0 ? 1 : -1;
      jumpTo(window.scrollY + deg / K);
      trail.push({ t: e.timeStamp, a: acc });
      while (trail.length > 2 && e.timeStamp - trail[0].t > 100) trail.shift();
      const w = (acc - trail[0].a) / Math.max(8, e.timeStamp - trail[0].t); // degrees per ms
      bump('ring', 0.3 + Math.abs(w) / 1.2);
      say('Ring:', `${fmt(Math.abs(w) * 1000 / 6)} notches a second`, 'ring', { hold: 1400 });
    });
    const end = (e) => {
      if (!ringDrag || e.pointerId !== id) return;
      ringDrag = false;
      stage.classList.remove('grabbing');
      chip('ring', false);
      const a = trail[0];
      const b = trail[trail.length - 1];
      if (a && b && b.t > a.t && e.timeStamp - b.t < 80) {
        const w = (b.a - a.a) / (b.t - a.t);
        pageV = clamp(w / K, -14, 14);
        if (Math.abs(pageV) > 0.5) say('Ring:', 'flicked. The page glides to a stop, like Flywheel.', 'ring', { hold: 2600 });
      }
      wake();
    };
    ringEl.addEventListener('pointerup', end);
    ringEl.addEventListener('pointercancel', end);
    ringEl.addEventListener('keydown', (e) => {
      const d = { ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1 }[e.key];
      if (!d) return;
      e.preventDefault();
      pageV = clamp(pageV + d * 2.2, -14, 14);
      bump('ring', 0.8);
      wake();
    });
  }

  /* ============================================================ The four buttons */
  const padArt = {};
  $$('[data-pad-art]', stage).forEach((g) => { padArt[g.dataset.padArt] = g; });
  // Where each corner is on the room light (the aurora is centered on the ball).
  const padPos = { tl: ['40.5%', '38.5%'], tr: ['59.5%', '38.5%'], bl: ['40.5%', '61.5%'], br: ['59.5%', '61.5%'] };
  const litTimers = {};
  function lightPad(k, ms = 220) {
    const g = padArt[k];
    if (g) g.classList.add('lit');
    chip(k, true);
    $$(`[data-key-row="${k}"]`).forEach((r) => r.classList.add('lit'));
    hero.style.setProperty('--bx', padPos[k][0]);
    hero.style.setProperty('--by', padPos[k][1]);
    bump('amber', 1);
    clearTimeout(litTimers[k]);
    if (!frozen) {
      litTimers[k] = setTimeout(() => {
        if (g && !held.has(k)) g.classList.remove('lit');
        if (!held.has(k)) chip(k, false);
        $$(`[data-key-row="${k}"]`).forEach((r) => r.classList.remove('lit'));
      }, ms);
    }
  }
  const held = new Set();
  function setHeld(k, on) {
    if (on) held.add(k); else held.delete(k);
    if (padArt[k]) { padArt[k].classList.toggle('held', on); if (!on) padArt[k].classList.remove('lit'); }
    chip(k, on);
  }

  function fire(k, from) {
    lightPad(k);
    const a = k === 'bl' ? 'left' : assign[k];
    const label = `${CORNER[k]}:`;
    if (a === 'left') {
      ripple(from);
      say(label, 'Left click. It always stays one, so you can’t lock yourself out.', 'buttons', { announce: true, hold: 3600 });
      return;
    }
    say(label, ACTIONS[a] || 'Do nothing', 'buttons', { announce: true });
    run(a, from, k);
  }
  function fireCombo(a, b, from) {
    const key = comboKey(a, b);
    lightPad(a, 420); lightPad(b, 420);
    $$(`[data-combo-row="${key}"]`).forEach((r) => { r.classList.add('lit'); setTimeout(() => r.classList.remove('lit'), 600); });
    const act = combos[key];
    const names = `${CORNER[a]} + ${CORNER[b].toLowerCase()}:`;
    if (!act) {
      say(names, 'no combo on these two yet. In the app, Quick assign sets one up in two presses.', 'buttons', { announce: true, hold: 4200 });
      return;
    }
    say(names, ACTIONS[act], 'buttons', { announce: true });
    run(act, from);
  }
  function run(a, from, k) {
    if (a === 'mission') openMC('mc', from);
    else if (a === 'spotlight') openMC('spot', from);
    else if (a === 'next') space(1);
    else if (a === 'prev') space(-1);
    else if (a === 'right') openCtx(from, k);
  }

  const downPads = new Map();
  $$('[data-pad]', stage).forEach((btn) => {
    const k = btn.dataset.pad;
    let comboed = false;
    btn.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;
      // Two pads down at once (two fingers): that's a combo.
      const other = [...downPads.keys()].find((o) => o !== k);
      downPads.set(k, e.pointerId);
      lightPad(k, 260);
      if (other) {
        comboed = true;
        const ob = $(`[data-pad="${other}"]`, stage);
        if (ob) ob.dataset.comboed = '1';
        fireCombo(other, k, btn);
      }
    });
    const up = () => { downPads.delete(k); };
    btn.addEventListener('pointerup', up);
    btn.addEventListener('pointercancel', up);
    btn.addEventListener('pointerleave', up);
    btn.addEventListener('pointerenter', (e) => { if (e.pointerType === 'mouse' && padArt[k]) padArt[k].classList.add('hover'); });
    btn.addEventListener('pointerleave', () => { if (padArt[k]) padArt[k].classList.remove('hover'); });
    btn.addEventListener('focus', () => { if (padArt[k]) padArt[k].classList.add('focus'); });
    btn.addEventListener('blur', () => { if (padArt[k]) padArt[k].classList.remove('focus'); });
    btn.addEventListener('click', (e) => {
      if (comboed || btn.dataset.comboed) { comboed = false; delete btn.dataset.comboed; return; }
      // Shift-click holds a button down, so the next one makes a combo.
      if (e.shiftKey) {
        if (held.has(k)) { setHeld(k, false); say('', 'Let go.', 'buttons', { hold: 1500 }); return; }
        held.forEach((o) => setHeld(o, false));
        setHeld(k, true);
        lightPad(k);
        say(`Holding ${CORNER[k].toLowerCase()}.`, 'Press another corner for a combo.', 'buttons', { announce: true, hold: 0 });
        return;
      }
      const other = [...held][0];
      if (other && other !== k) {
        setHeld(other, false);
        fireCombo(other, k, btn);
        return;
      }
      if (other === k) setHeld(k, false);
      fire(k, btn);
    });
  });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && held.size) { held.forEach((o) => setHeld(o, false)); say('', 'Let go.', 'buttons', { hold: 1500 }); }
  });

  // The visitor's real mouse buttons light the matching corners (left, right, middle, back),
  // and two held together show their combo, the way the app would see them. Nothing fires.
  // (mousedown, not pointerdown: a second button pressed while one is down is still a mousedown.)
  const BUTTON_PAD = { 0: 'bl', 2: 'br', 1: 'tl', 3: 'tr', 4: 'tr' };
  const realDown = new Set();
  let lastTouch = -1e9;
  window.addEventListener('pointerdown', (e) => { if (e.pointerType !== 'mouse') lastTouch = e.timeStamp; }, { passive: true, capture: true });
  window.addEventListener('mousedown', (e) => {
    if (e.timeStamp - lastTouch < 1000 || !heroVisible || stage.contains(e.target)) return;
    const k = BUTTON_PAD[e.button];
    if (!k) return;
    realDown.add(k);
    lightPad(k, 200);
    if (realDown.size === 2) {
      const [a, b] = [...realDown];
      const act = combos[comboKey(a, b)];
      say(`${CORNER[a]} + ${CORNER[b].toLowerCase()}:`, act ? ACTIONS[act] : 'no combo on these two yet.', 'buttons', { hold: 2600 });
    }
  }, { passive: true, capture: true });
  window.addEventListener('mouseup', (e) => { realDown.delete(BUTTON_PAD[e.button]); }, { passive: true, capture: true });
  window.addEventListener('blur', () => realDown.clear());

  /* ============================================================ What the buttons do, on the page */
  function centerOf(el) {
    if (!el || !el.getBoundingClientRect) return { x: window.innerWidth / 2, y: window.innerHeight / 2 };
    const r = el.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  }
  function ripple(from) {
    if (reduce.matches) return;
    const p = centerOf(from);
    const el = document.createElement('span');
    el.className = 'ripple';
    el.style.left = `${p.x}px`;
    el.style.top = `${p.y}px`;
    document.body.append(el);
    el.addEventListener('animationend', () => el.remove(), { once: true });
  }

  // Next and Previous Space: slide the whole page to the next section, like switching Spaces.
  function sectionTops() {
    return $$('main > section, .parts > section').map((s) => s.getBoundingClientRect().top + window.scrollY - 84);
  }
  function space(dir) {
    const tops = sectionTops();
    const y = window.scrollY + 4;
    let target;
    if (dir > 0) target = tops.find((t) => t > y + 20);
    else target = [...tops].reverse().find((t) => t < y - 20);
    if (target === undefined) target = dir > 0 ? tops[tops.length - 1] : 0;
    target = Math.max(0, target);
    const go = () => jumpTo(target);
    if (document.startViewTransition && !reduce.matches) {
      const cls = dir > 0 ? 'vt-next' : 'vt-prev';
      document.documentElement.classList.add(cls);
      const vt = document.startViewTransition(go);
      vt.finished.finally(() => document.documentElement.classList.remove(cls));
    } else {
      glideTo(target);
    }
  }

  // Mission Control and Spotlight: the page's sections as tiles to jump to.
  const mc = $('[data-mc-layer]');
  const mcGrid = $('[data-mc-grid]');
  const mcSearch = $('[data-mc-search]');
  const mcTitle = $('[data-mc-title]');
  let mcReturn = null;
  const sections = $$('[data-mc]').map((s) => ({
    el: s,
    label: s.dataset.mc,
    title: ($('h2', s) || {}).textContent || s.dataset.mc,
    rgb: PART_RGB[s.dataset.part] || '150, 170, 255',
  }));
  function fillMC(q) {
    mcGrid.textContent = '';
    const query = (q || '').trim().toLowerCase();
    const list = sections.filter((s) => !query || `${s.label} ${s.title}`.toLowerCase().includes(query));
    list.forEach((s, i) => {
      const li = document.createElement('li');
      const a = document.createElement('a');
      a.href = s.el.id ? `#${s.el.id}` : '#';
      a.style.setProperty('--tc', s.rgb);
      a.style.setProperty('--i', String(i));
      const small = document.createElement('small');
      small.textContent = s.label;
      const b = document.createElement('b');
      b.textContent = s.title;
      a.append(small, b);
      a.addEventListener('click', (e) => {
        e.preventDefault();
        closeMC(false);
        const top = s.el.getBoundingClientRect().top + window.scrollY - 84;
        glideTo(top);
        const h = $('h2', s.el);
        if (h) { h.setAttribute('tabindex', '-1'); h.focus({ preventScroll: true }); }
      });
      li.append(a);
      mcGrid.append(li);
    });
    const first = $('a', mcGrid);
    if (first && mc.classList.contains('spot')) first.classList.add('sel');
  }
  function openMC(mode, from) {
    if (!mc) return;
    mcReturn = document.activeElement;
    mc.classList.toggle('spot', mode === 'spot');
    mcTitle.textContent = mode === 'spot' ? 'Spotlight' : 'Mission Control';
    mcSearch.hidden = mode !== 'spot';
    mcSearch.value = '';
    fillMC('');
    mc.hidden = false;
    if (mode === 'spot') mcSearch.focus();
    else { const a = $('a', mcGrid); if (a) a.focus({ preventScroll: true }); }
  }
  function closeMC(restore = true) {
    if (!mc || mc.hidden) return;
    mc.hidden = true;
    if (restore && mcReturn && mcReturn.focus) mcReturn.focus({ preventScroll: true });
  }
  if (mc) {
    mc.addEventListener('click', (e) => { if (e.target === mc) closeMC(); });
    mcSearch.addEventListener('input', () => fillMC(mcSearch.value));
    mc.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') { e.preventDefault(); closeMC(); return; }
      const tiles = $$('a', mcGrid);
      if (mc.classList.contains('spot') && (e.key === 'ArrowDown' || e.key === 'ArrowUp' || e.key === 'Enter')) {
        let i = tiles.findIndex((t) => t.classList.contains('sel'));
        if (e.key === 'Enter') { if (tiles[Math.max(0, i)]) { e.preventDefault(); tiles[Math.max(0, i)].click(); } return; }
        e.preventDefault();
        tiles.forEach((t) => t.classList.remove('sel'));
        i = clamp(i + (e.key === 'ArrowDown' ? 1 : -1), 0, tiles.length - 1);
        if (tiles[i]) tiles[i].classList.add('sel');
        return;
      }
      if (e.key === 'Tab') {
        const f = (mcSearch.hidden ? [] : [mcSearch]).concat(tiles);
        const i = f.indexOf(document.activeElement);
        e.preventDefault();
        const n = f[(i + (e.shiftKey ? -1 : 1) + f.length) % f.length];
        if (n) n.focus();
      }
    });
  }

  // Right click: a small menu by the button.
  const ctx = $('[data-ctx]');
  let ctxReturn = null;
  function openCtx(from) {
    if (!ctx) return;
    ctxReturn = document.activeElement;
    const p = centerOf(from);
    ctx.hidden = false;
    const w = ctx.offsetWidth;
    const h = ctx.offsetHeight;
    ctx.style.left = `${clamp(p.x, 8, window.innerWidth - w - 8)}px`;
    ctx.style.top = `${clamp(p.y, 8, window.innerHeight - h - 8)}px`;
    const first = $('a', ctx);
    if (first) first.focus({ preventScroll: true });
  }
  function closeCtx(restore = true) {
    if (!ctx || ctx.hidden) return;
    ctx.hidden = true;
    if (restore && ctxReturn && ctxReturn.focus) ctxReturn.focus({ preventScroll: true });
  }
  if (ctx) {
    ctx.addEventListener('click', (e) => { if (e.target.closest('a')) closeCtx(false); });
    ctx.addEventListener('keydown', (e) => {
      const items = $$('a', ctx);
      const i = items.indexOf(document.activeElement);
      if (e.key === 'Escape') { e.preventDefault(); closeCtx(); }
      else if (e.key === 'ArrowDown') { e.preventDefault(); items[(i + 1) % items.length].focus(); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); items[(i - 1 + items.length) % items.length].focus(); }
      else if (e.key === 'Tab') closeCtx(false);
    });
    document.addEventListener('pointerdown', (e) => { if (!ctx.hidden && !ctx.contains(e.target)) closeCtx(false); });
    window.addEventListener('scroll', () => closeCtx(false), { passive: true });
  }

  /* ============================================================ The docked ball */
  const dockProg = dock && $('[data-dock-prog]', dock);
  function updateDock() {
    if (!dock) return;
    const max = document.documentElement.scrollHeight - window.innerHeight;
    const p = max > 0 ? clamp(window.scrollY / max, 0, 1) : 0;
    dock.style.setProperty('--dp', (p * 100).toFixed(1));
    if (dockProg) dockProg.style.strokeDasharray = `${(p * 100).toFixed(1)} 100`;
  }
  if (dock && 'IntersectionObserver' in window) {
    // Lit in the color of the part you're reading about.
    const io = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) dock.style.setProperty('--dc', PART_RGB[e.target.dataset.part] || '140, 150, 255');
      });
    }, { rootMargin: '-45% 0px -45% 0px' });
    $$('main > section, .parts > section').forEach((s) => io.observe(s));
    dock.addEventListener('click', (e) => {
      e.preventDefault();
      glideTo(0);
      const brand = $('.brand');
      if (brand) brand.focus({ preventScroll: true });
    });
    updateDock();
  }

  /* ============================================================ Numbers that roll once (odometer) */
  function initOdometers() {
    const els = $$('[data-odo]');
    els.forEach((el) => {
      const text = el.textContent.trim();
      el.setAttribute('aria-label', text);
      el.textContent = '';
      for (const ch of text) {
        if (!/\d/.test(ch)) { const s = document.createElement('span'); s.textContent = ch; s.setAttribute('aria-hidden', 'true'); el.append(s); continue; }
        const d = document.createElement('span');
        d.className = 'odo-d';
        d.setAttribute('aria-hidden', 'true');
        const col = document.createElement('span');
        col.className = 'odo-col';
        for (let i = 0; i < 20; i++) { const n = document.createElement('span'); n.textContent = String(i % 10); col.append(n); }
        // At rest it shows the real digit; rolling spins it once around to the same digit.
        col.style.transform = `translateY(-${ch}em)`;
        col.dataset.to = String(10 + Number(ch));
        d.append(col);
        el.append(d);
      }
    });
    const roll = (el) => $$('.odo-col', el).forEach((c, i) => {
      c.style.transitionDelay = `${i * 120}ms`;
      c.style.transform = `translateY(-${c.dataset.to}em)`;
    });
    if (!('IntersectionObserver' in window) || reduce.matches || demo) { els.forEach(roll); return; }
    const io = new IntersectionObserver((entries) => entries.forEach((e) => {
      if (!e.isIntersecting) return;
      io.unobserve(e.target);
      roll(e.target);
    }), { threshold: 0.3 });
    els.forEach((el) => io.observe(el));
  }

  /* ============================================================ Ball section: a working Pointer tab + one flick, three displays */
  function initPointer() {
    const range = $('[data-pt-speed]');
    if (!range) return;
    const valOut = $('[data-pt-val]');
    const hint = $('[data-pt-hint]');
    const line = $('[data-pt-line]');
    const fill = $('[data-pt-fill]');
    const presets = $$('[data-pt-preset]');
    const nameOut = $('[data-flick-name]');
    const NAMES = { 1.5: 'Precise', 3: 'macOS', 5: 'Fast', 7.5: 'Turbo' };
    const hintFor = (s) => {
      const r = s / 3;
      if (Math.abs(r - 1) < 0.02) return 'The same as System Settings’ fastest speed.';
      if (r < 1) return `${Math.round(r * 100)}% of System Settings’ fastest speed.`;
      return `${r.toFixed(1)}× System Settings’ fastest speed.`;
    };
    const curve = (s) => {
      const g = (s / 3) * 0.3;
      let d = '';
      for (let i = 0; i <= 30; i++) {
        const x = i / 30;
        const y = 108 - Math.min(1.06, g * (0.18 * x + 0.82 * x * x) / 0.5 * 0.5 * 2) * 100;
        d += `${i ? 'L' : 'M'}${(x * 300).toFixed(1)} ${y.toFixed(1)}`;
      }
      return d;
    };
    const set = (s, fromRange) => {
      s = clamp(Number(s) || 3, 0.5, 80);
      if (!fromRange) range.value = String(s);
      const p = ((s - 0.5) / 79.5) * 100;
      range.style.setProperty('--p', `${p.toFixed(2)}%`);
      valOut.textContent = s % 1 ? s.toFixed(1) : String(s);
      hint.textContent = hintFor(s);
      const d = curve(s);
      line.setAttribute('d', d);
      fill.setAttribute('d', `${d}L300 110L0 110Z`);
      presets.forEach((b) => b.setAttribute('aria-pressed', String(Number(b.dataset.ptPreset) === s)));
      speedRatio = s / 3;
      speedName = NAMES[s] || `speed ${valOut.textContent}`;
      if (nameOut) nameOut.textContent = NAMES[s] || `speed ${valOut.textContent}`;
    };
    range.addEventListener('input', () => set(range.value, true));
    presets.forEach((b) => b.addEventListener('click', () => set(b.dataset.ptPreset)));
    set(7.5);

    // One flick, three displays
    const toy = $('[data-flick]');
    if (!toy) return;
    const go = $('[data-flick-go]', toy);
    const note = $('[data-flick-note]', toy);
    const lanes = $$('[data-lane]', toy).map((lane) => ({
      lane,
      cursor: $('[data-cursor]', lane),
      screens: $$('.screens span', lane),
      box: $('.screens', lane),
    }));
    const BASE = 1.1; // displays crossed at System Settings' fastest, for this flick
    let t0 = 0;
    let running = false;
    const TAU = 230;
    const HALVES = { 1: 'one display', 1.5: 'one and a half displays', 2: 'two displays', 2.5: 'two and a half displays', 3: 'three displays' };
    const words = (n) => {
      if (n >= 2.92) return 'all three displays';
      if (n < 0.75) return `${Math.round(n * 100)}% of a display`;
      return `about ${HALVES[Math.round(n * 2) / 2]}`;
    };
    const place = (L, frac, disp) => {
      const w = L.box.clientWidth - 24;
      L.cursor.style.transform = `translate3d(${(frac * w).toFixed(1)}px, 0, 0)`;
      L.screens.forEach((s, i) => s.classList.toggle('hit', disp > i + 0.02));
    };
    let power = 1; // 1 is the button's flick; a drag scales it by how fast it was let go
    const targets = () => [BASE * power, BASE * power * speedRatio];
    const step = (t) => {
      const e = reduce.matches ? 1 : 1 - Math.exp(-(t - t0) / TAU);
      targets().forEach((D, i) => {
        const disp = Math.min(3, D * e);
        place(lanes[i], disp / 3, disp);
      });
      if (e < 0.998) requestAnimationFrame(step);
      else {
        running = false;
        const [a, b] = targets();
        note.textContent = `Same flick: ${words(Math.min(3, a))} at System Settings’ fastest, and ${words(Math.min(3, b))} with Glideball at ${speedName}.`;
      }
    };
    const fire = (p) => {
      power = p;
      lanes.forEach((L) => place(L, 0, 0));
      t0 = performance.now();
      if (!running) { running = true; requestAnimationFrame(step); }
      bump('ball', 0.4);
    };
    go.addEventListener('click', () => fire(1));

    // Drag across the screens and let go: the flick's strength is the speed of the last moments of the drag.
    const pad = $('[data-flick-pad]', toy);
    const REF = 1.3; // px per ms that equals the button's flick
    let drag = null;
    if (pad) {
      pad.addEventListener('pointerdown', (e) => {
        if (e.button > 0 || !e.isPrimary) return;
        drag = { id: e.pointerId, x0: e.clientX, pts: [[performance.now(), e.clientX]] };
        pad.classList.add('grabbing');
        try { pad.setPointerCapture(e.pointerId); } catch (_) {}
        e.preventDefault();
      });
      pad.addEventListener('pointermove', (e) => {
        if (!drag || e.pointerId !== drag.id) return;
        const now = performance.now();
        drag.pts.push([now, e.clientX]);
        while (drag.pts.length > 2 && now - drag.pts[0][0] > 90) drag.pts.shift();
        // The cursors ride along with the finger (a little, so the result is still the surprise).
        const dx = Math.max(0, e.clientX - drag.x0);
        lanes.forEach((L, i) => {
          const f = Math.min(0.2, dx / Math.max(1, L.box.clientWidth) * 0.5);
          place(L, f * (i ? Math.min(speedRatio, 3) / 3 + 0.35 : 0.35), 0);
        });
      });
      const end = (e, cancelled) => {
        if (!drag || e.pointerId !== drag.id) return;
        const now = performance.now();
        const [t1, x1] = drag.pts[0];
        const dx = e.clientX - drag.x0;
        const v = (e.clientX - x1) / Math.max(16, now - t1);
        drag = null;
        pad.classList.remove('grabbing');
        if (cancelled) { lanes.forEach((L) => place(L, 0, 0)); return; }
        if (dx < 24 || v <= 0) {
          lanes.forEach((L) => place(L, 0, 0));
          note.textContent = 'Drag to the right and let go while still moving, or press Try a flick.';
          return;
        }
        fire(Math.min(2.2, Math.max(0.3, v / REF)));
      };
      pad.addEventListener('pointerup', (e) => end(e, false));
      pad.addEventListener('pointercancel', (e) => end(e, true));
      // A gentle nudge once, the first time the toy scrolls into view.
      if (!reduce.matches && 'IntersectionObserver' in window) {
        const io = new IntersectionObserver((es) => {
          if (!es.some((x) => x.isIntersecting)) return;
          io.disconnect();
          toy.classList.add('hinting');
          setTimeout(() => toy.classList.remove('hinting'), 2200);
        }, { threshold: 0.6 });
        io.observe(toy);
      }
    }
    if (demo === 'flick') { t0 = performance.now() - 5000; step(performance.now()); }
  }

  /* ============================================================ Ring section: same spin, three modes */
  function initRing() {
    const rt = $('[data-rt]');
    if (!rt) return;
    const track = $('[data-rt-track]', rt);
    const knob = $('[data-rt-knob]', rt);
    const lineEl = $('[data-rt-line]');
    const tickEl = $('[data-rt-ticksline]');
    const hint = $('[data-rm-hint]');
    const modeBtns = $$('[data-rm-mode]');
    const spinBtn = $('[data-rt-spin]');
    const HINTS = {
      native: 'Glideball steps aside and macOS scrolls the ring itself. Only the speed is adjustable.',
      flywheel: 'Every tick pushes the page and friction slows it down: gentle turns barely coast, hard spins fly.',
      follow: 'The page follows the ring exactly and stops when you stop. A hard flick can still throw it.',
    };
    for (let i = 0; i < 80; i++) {
      const li = document.createElement('li');
      li.textContent = `Row ${i + 1}`;
      li.append(document.createElement('i'));
      track.append(li);
    }
    const ROW = 30;
    const maxPos = 80 * ROW - 150;
    let mode = 'flywheel';
    let pos = 0; let v = 0; let target = 0;
    let ka = 0; let glow = 0;
    const notchTimes = [];
    const hist = []; // [t, pos]
    const ticks = []; // t
    let raf2 = 0; let last = 0; let quiet = 0;

    const setMode = (m) => {
      mode = m;
      modeBtns.forEach((b) => b.setAttribute('aria-checked', String(b.dataset.rmMode === m)));
      hint.textContent = HINTS[m];
      v = 0; target = pos;
    };
    modeBtns.forEach((b) => b.addEventListener('click', () => setMode(b.dataset.rmMode)));
    // Arrow keys move between the three modes, like a native radio group.
    modeBtns.forEach((b, i) => b.addEventListener('keydown', (e) => {
      const d = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[e.key];
      if (!d) return;
      e.preventDefault();
      const n = modeBtns[(i + d + modeBtns.length) % modeBtns.length];
      n.focus(); setMode(n.dataset.rmMode);
    }));

    const notch = (dir, t = performance.now()) => {
      notchTimes.push(t);
      while (notchTimes.length && t - notchTimes[0] > 250) notchTimes.shift();
      const rate = notchTimes.length / 0.25; // notches a second
      ticks.push(t);
      ka += dir * 12;
      glow = Math.min(1, glow + 0.25);
      if (mode === 'native') pos = clamp(pos + dir * ROW, 0, maxPos);
      else if (mode === 'flywheel') v += (dir * 14 * (1 + rate / 14)) / 82;
      else target = clamp(target + dir * 26, 0, maxPos);
      wake2();
    };
    const render = () => {
      track.style.transform = `translate3d(0, ${(-pos).toFixed(1)}px, 0)`;
      knob.style.setProperty('--ka', `${ka.toFixed(1)}deg`);
      knob.style.setProperty('--k', glow.toFixed(3));
    };
    const draw = (t) => {
      const W = 3000;
      while (hist.length > 2 && t - hist[0][0] > W + 100) hist.shift();
      while (ticks.length && t - ticks[0] > W) ticks.shift();
      let d = '';
      hist.forEach(([ht, hp], i) => {
        const x = 300 - ((t - ht) / W) * 300;
        const y = 56 - (hp / Math.max(600, maxPos * 0.5)) * 52 % 52;
        d += `${i ? 'L' : 'M'}${x.toFixed(1)} ${clamp(y, 2, 58).toFixed(1)}`;
      });
      lineEl.setAttribute('d', hist.length > 1 ? d : 'M0 56L300 56');
      tickEl.setAttribute('d', ticks.map((tt) => { const x = (300 - ((t - tt) / W) * 300).toFixed(1); return `M${x} 60V52`; }).join('') || 'M0 60');
    };
    const loop = (t) => {
      const dt = clamp(t - last, 1, 64);
      last = t;
      const before = pos;
      if (mode === 'flywheel' && v) {
        const k = Math.exp(-dt / 82);
        let next = pos + v * 82 * (1 - k);
        v *= k;
        if (next <= 0 || next >= maxPos) { next = clamp(next, 0, maxPos); v = 0; }
        if (Math.abs(v) < 0.002) v = 0;
        pos = next;
      } else if (mode === 'follow') {
        pos += (target - pos) * (1 - Math.exp(-dt / 45));
        if (Math.abs(target - pos) < 0.3) pos = target;
        if (v) { // a thrown flick
          const k = Math.exp(-dt / 120);
          target = clamp(target + v * 120 * (1 - k), 0, maxPos);
          v *= k;
          if (Math.abs(v) < 0.01) v = 0;
        }
      }
      glow *= Math.exp(-dt / 300);
      hist.push([t, pos]);
      render();
      draw(t);
      quiet = (Math.abs(pos - before) < 0.05 && !v && glow < 0.01 && !dragging) ? quiet + dt : 0;
      raf2 = quiet > 3100 ? 0 : requestAnimationFrame(loop);
    };
    const wake2 = () => { quiet = 0; if (!raf2) { last = performance.now(); raf2 = requestAnimationFrame(loop); } };

    // Turn the knob with the pointer: one notch every 12°.
    let dragging = false;
    let id = null; let cx = 0; let cy = 0; let prevA = 0; let acc = 0; let trail = [];
    knob.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;
      e.preventDefault();
      id = e.pointerId;
      try { knob.setPointerCapture(id); } catch (_) { /* ignore */ }
      const r = knob.getBoundingClientRect();
      cx = r.left + r.width / 2; cy = r.top + r.height / 2;
      prevA = Math.atan2(e.clientY - cy, e.clientX - cx);
      dragging = true; acc = 0; trail = [{ t: e.timeStamp, a: 0 }];
      wake2();
    });
    knob.addEventListener('pointermove', (e) => {
      if (!dragging || e.pointerId !== id) return;
      const a = Math.atan2(e.clientY - cy, e.clientX - cx);
      let d = a - prevA;
      if (d > Math.PI) d -= 2 * Math.PI;
      if (d < -Math.PI) d += 2 * Math.PI;
      prevA = a;
      acc += d * 180 / Math.PI;
      trail.push({ t: e.timeStamp, a: acc });
      while (trail.length > 2 && e.timeStamp - trail[0].t > 100) trail.shift();
      while (acc >= 12) { acc -= 12; notch(1); trail.forEach((p) => { p.a -= 12; }); }
      while (acc <= -12) { acc += 12; notch(-1); trail.forEach((p) => { p.a += 12; }); }
    });
    const end = (e) => {
      if (!dragging || e.pointerId !== id) return;
      dragging = false;
      // Follow: a real flick can still throw the page.
      const a = trail[0]; const b = trail[trail.length - 1];
      if (mode === 'follow' && a && b && b.t > a.t) {
        const w = (b.a - a.a) / (b.t - a.t); // deg per ms
        if (Math.abs(w) > 0.9) v = (w / 12) * 26 * 0.5;
      }
      wake2();
    };
    knob.addEventListener('pointerup', end);
    knob.addEventListener('pointercancel', end);
    knob.addEventListener('keydown', (e) => {
      const d = { ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1 }[e.key];
      if (!d) return;
      e.preventDefault();
      notch(d);
    });
    let spinTimer = 0;
    spinBtn.addEventListener('click', () => {
      clearTimeout(spinTimer);
      const dir = pos > maxPos * 0.6 ? -1 : 1;
      let n = 0;
      const tick = () => { notch(dir); if (++n < 14) spinTimer = setTimeout(tick, 28); };
      tick();
    });
    hist.push([performance.now(), 0]);
    render();
    draw(performance.now());
    if (demo === 'ring-spin') spinBtn.click();
  }

  /* ============================================================ Buttons section: assign, then try it */
  function initButtons() {
    const selects = $$('[data-assign]');
    selects.forEach((sel) => {
      const k = sel.dataset.assign;
      Object.entries(ACTIONS).forEach(([value, label]) => {
        const o = document.createElement('option');
        o.value = value; o.textContent = label;
        sel.append(o);
      });
      sel.value = assign[k];
      sel.addEventListener('change', () => {
        assign[k] = sel.value;
        $$(`[data-pad-name="${k}"]`).forEach((n) => { n.textContent = ACTIONS[sel.value]; });
        lightPad(k);
      });
    });
    $$('[data-press]').forEach((b) => b.addEventListener('click', () => fire(b.dataset.press, b)));
  }

  /* ============================================================ Feel it: the flywheel demo */
  function hexToRgba(hex, a) {
    const m = /^#?([0-9a-f]{6})$/i.exec(hex.trim());
    if (!m) return hex;
    const n = parseInt(m[1], 16);
    return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${a})`;
  }
  class Spark {
    constructor(canvas, { windowMs = 3000, floor = 1000 } = {}) {
      this.canvas = canvas;
      this.ctx = canvas.getContext('2d');
      this.windowMs = windowMs;
      this.floor = floor;
      this.scale = floor;
      this.samples = [];
      this.peak = []; // the afterglow: a slow-fading copy of recent peaks
      this.c = '#ff5ca8';
      this.resize();
    }
    resize() {
      const r = this.canvas.getBoundingClientRect();
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      this.w = Math.max(1, Math.round(r.width));
      this.h = Math.max(1, Math.round(r.height));
      this.canvas.width = Math.round(this.w * dpr);
      this.canvas.height = Math.round(this.h * dpr);
      this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    push(t, v) {
      const s = this.samples;
      if (s.length && t - s[s.length - 2] > 120) s.push(t - 17, 0);
      s.push(t, v);
      const cutoff = t - this.windowMs - 120;
      let i = 0;
      while (i < s.length - 4 && s[i] < cutoff) i += 2;
      if (i) s.splice(0, i);
    }
    draw(now) {
      const { ctx, w, h } = this;
      ctx.clearRect(0, 0, w, h);
      ctx.lineWidth = 1;
      ctx.strokeStyle = 'rgba(255,255,255,0.06)';
      ctx.beginPath();
      for (let i = 1; i <= 3; i++) { const y = Math.round((h * i) / 4) + 0.5; ctx.moveTo(0, y); ctx.lineTo(w, y); }
      ctx.stroke();
      let s = this.samples;
      if (s.length < 2) s = [now - this.windowMs - 20, 0, now, 0];
      const lastT = s[s.length - 2];
      if (now - lastT > 34) s = s.concat([lastT + 17, 0, now, 0]);
      let max = this.floor;
      for (let i = 1; i < s.length; i += 2) if (s[i] > max) max = s[i];
      this.scale += (max * 1.12 - this.scale) * 0.12;
      const top = 8;
      const base = h - 3;
      const X = (t) => w - ((now - t) / this.windowMs) * w;
      const Y = (v) => base - Math.min(1, v / this.scale) * (base - top);
      const lead = X(s[0]) > 0;
      const trace = () => {
        ctx.beginPath();
        if (lead) { ctx.moveTo(0, base); ctx.lineTo(X(s[0]), base); ctx.lineTo(X(s[0]), Y(s[1])); }
        else ctx.moveTo(X(s[0]), Y(s[1]));
        for (let i = 2; i < s.length; i += 2) ctx.lineTo(X(s[i]), Y(s[i + 1]));
      };
      trace();
      ctx.lineTo(X(s[s.length - 2]), base);
      ctx.lineTo(lead ? 0 : X(s[0]), base);
      ctx.closePath();
      const fill = ctx.createLinearGradient(0, top, 0, base);
      fill.addColorStop(0, hexToRgba(this.c, 0.34));
      fill.addColorStop(1, hexToRgba(this.c, 0));
      ctx.fillStyle = fill;
      ctx.fill();
      // A glowing line: a wide soft pass under a crisp one.
      trace();
      ctx.lineJoin = 'round';
      ctx.lineCap = 'round';
      ctx.strokeStyle = hexToRgba(this.c, 0.35);
      ctx.lineWidth = 6;
      ctx.stroke();
      ctx.strokeStyle = this.c;
      ctx.lineWidth = 2;
      ctx.stroke();
      // The head of the trace: a bright dot where "now" is.
      const hy = Y(s[s.length - 1]);
      ctx.fillStyle = '#ffd6ea';
      ctx.beginPath();
      ctx.arc(w - 2, hy, 3, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  function initDemo() {
    const box = $('[data-demo]');
    if (!box) return;
    const vp = $('[data-fw-viewport]', box);
    const track = $('[data-fw-track]', box);
    const thumb = $('[data-fw-thumb]', box);
    const canvas = $('[data-fw-canvas]', box);
    const speedOut = $('[data-fw-speed]', box);
    const note = $('[data-fw-note]', box);
    const spinBtn = $('[data-fw-spin]', box);
    const radios = $$('input[name="fw-mode"]', box);
    const fm = $('[data-fm]', box);
    const TAU = 82;
    const NOTES = {
      plain: 'Plain wheel: every tick jumps the page its full distance in a single frame. That jolt is what you feel.',
      flywheel: 'Flywheel: each tick adds a push, and friction (τ ≈ 82 ms) glides it to a stop. Same distance, no jolts.',
    };
    const frag = document.createDocumentFragment();
    for (let i = 0; i < 90; i++) {
      const li = document.createElement('li');
      li.className = 'fw-row';
      const dotEl = document.createElement('span');
      dotEl.className = 'fw-dot';
      const label = document.createElement('span');
      label.className = 'fw-label';
      label.textContent = `Row ${i + 1}`;
      const bar = document.createElement('span');
      bar.className = 'fw-bar';
      bar.style.width = `${20 + ((i * 37) % 46)}%`;
      li.append(dotEl, label, bar);
      frag.append(li);
    }
    track.append(frag);

    let mode = (radios.find((r) => r.checked) || {}).value || 'flywheel';
    let pos = 0; let v = 0; let maxPos = 0; let vh = 0; let barH = 0; let rowH = 54;
    const render = () => {
      track.style.transform = `translate3d(0, ${(-pos).toFixed(2)}px, 0)`;
      const total = maxPos + vh;
      const th = total > 0 ? Math.max(28, (vh / total) * barH) : barH;
      const ty = maxPos > 0 ? (pos / maxPos) * (barH - th) : 0;
      thumb.style.height = `${th.toFixed(1)}px`;
      thumb.style.transform = `translate3d(0, ${ty.toFixed(2)}px, 0)`;
    };
    const measureDemo = () => {
      vh = vp.clientHeight;
      barH = Math.max(0, vh - 28);
      maxPos = Math.max(0, track.offsetHeight - vh);
      rowH = (track.firstElementChild && track.firstElementChild.offsetHeight) || 54;
      pos = clamp(pos, 0, maxPos);
      render();
    };
    const spark = new Spark(canvas, { windowMs: 3000, floor: 1200 });

    // Flick meter: your best moments in this visit. Nothing is stored or sent.
    const meter = (() => {
      if (!fm) return { update() {} };
      const bar = $('.fm-bar', fm);
      const fill = $('[data-fm-fill]', fm);
      const bestMark = $('[data-fm-best]', fm);
      const topOut = $('[data-fm-top]', fm);
      const glideOut = $('[data-fm-glide]', fm);
      const totalOut = $('[data-fm-total]', fm);
      const badge = $('[data-fm-badge]', fm);
      const liveEl = $('[data-fm-live]', fm);
      const FULL = 6000;
      let best = 0; let longest = 0; let total = 0; let glidePeak = 0; let glideDist = 0;
      let inGlide = false; let stillFor = 0; let shownTotal = -1; let badgeTimer = 0;
      const pulse = (el) => { el.classList.remove('bump'); void el.offsetWidth; el.classList.add('bump'); };
      const placeBest = () => {
        bestMark.style.setProperty('--best-x', `${(clamp(best / FULL, 0, 1) * bar.clientWidth).toFixed(1)}px`);
        bestMark.classList.add('on');
      };
      if ('ResizeObserver' in window) new ResizeObserver(() => { if (best) placeBest(); }).observe(bar);
      const celebrate = () => {
        badge.classList.add('show');
        clearTimeout(badgeTimer);
        badgeTimer = setTimeout(() => badge.classList.remove('show'), 1800);
        liveEl.textContent = `New best: ${fmt(best)} pixels per second.`;
      };
      const endGlide = () => {
        inGlide = false;
        stillFor = 0;
        const rows = glideDist / rowH;
        if (rows >= 1 && rows > longest + 0.5) {
          longest = rows;
          glideOut.textContent = fmt(Math.floor(longest));
          if (!reduce.matches) pulse(glideOut);
        }
        const previous = best;
        if (glidePeak > best + 1) {
          best = glidePeak;
          topOut.textContent = fmt(best);
          if (!reduce.matches) pulse(topOut);
          placeBest();
          if (previous >= 600 && best >= previous * 1.05) celebrate();
        }
        glidePeak = 0;
        glideDist = 0;
      };
      return {
        update(speed, moved, dt) {
          fill.style.setProperty('--v', clamp(speed / FULL, 0, 1).toFixed(3));
          if (moved > 0.25) {
            total += moved; glideDist += moved;
            glidePeak = Math.max(glidePeak, speed);
            inGlide = true; stillFor = 0;
          } else if (inGlide) {
            stillFor += dt;
            if (stillFor > 220 || dt === 0) endGlide();
          }
          const rowsTotal = Math.floor(total / rowH);
          if (rowsTotal !== shownTotal) { shownTotal = rowsTotal; totalOut.textContent = fmt(rowsTotal); }
        },
      };
    })();

    let running = false; let visible = false; let last = 0; let lastPos = 0;
    let quietFor = 0; let shownSpeed = 0; let dragging = false;
    const frameD = (t) => {
      if (!visible || document.hidden) { running = false; last = 0; return; }
      const dt = last ? clamp(t - last, 1, 64) : 16.7;
      last = t;
      if (mode === 'flywheel' && !dragging && v !== 0) {
        const k = Math.exp(-dt / TAU);
        // Exact integral of v·e^(−t/τ) over this frame: frame-rate independent, and every push
        // travels exactly its tick's distance.
        let next = pos + v * TAU * (1 - k);
        v *= k;
        if (next <= 0 || next >= maxPos) { next = clamp(next, 0, maxPos); v = 0; }
        if (Math.abs(v) < 0.002) v = 0;
        pos = next;
        render();
      }
      const moved = Math.abs(pos - lastPos);
      const speed = (moved / dt) * 1000;
      lastPos = pos;
      spark.push(t, speed);
      spark.draw(t);
      shownSpeed += (speed - shownSpeed) * 0.18;
      speedOut.textContent = fmt(shownSpeed < 1 ? 0 : shownSpeed);
      meter.update(shownSpeed, moved, dt);
      quietFor = (speed < 0.5 && v === 0 && !dragging) ? quietFor + dt : 0;
      if (quietFor > 3300) { running = false; last = 0; speedOut.textContent = '0'; meter.update(0, 0, 0); return; }
      requestAnimationFrame(frameD);
    };
    const wakeD = () => { quietFor = 0; if (!running && visible) { running = true; requestAnimationFrame(frameD); } };
    const projected = () => pos + (mode === 'flywheel' ? v * TAU : 0);
    const push = (d) => {
      if (!d) return;
      if (mode === 'plain') { pos = clamp(pos + d, 0, maxPos); render(); }
      else v += d / TAU;
      wakeD();
    };

    vp.addEventListener('wheel', (e) => {
      if (e.ctrlKey) return;
      if (Math.abs(e.deltaX) > Math.abs(e.deltaY)) return;
      if ((e.deltaY < 0 && pos <= 0 && v <= 0) || (e.deltaY > 0 && pos >= maxPos && v >= 0)) return;
      e.preventDefault();
      let d = e.deltaY;
      if (e.deltaMode === 1) d *= 40;
      else if (e.deltaMode === 2) d *= vh;
      push(d);
    }, { passive: false });

    let dragId = null; let startY = 0; let startPos = 0; let trail = [];
    let armed = false; let tapX = 0; let tapY = 0;
    const disarm = () => { armed = false; vp.classList.remove('armed'); };
    document.addEventListener('pointerdown', (e) => { if (armed && !vp.contains(e.target)) disarm(); });
    vp.addEventListener('blur', disarm);
    vp.addEventListener('pointerup', (e) => {
      if (coarse.matches && !armed && Math.hypot(e.clientX - tapX, e.clientY - tapY) < 10) { armed = true; vp.classList.add('armed'); }
    });
    vp.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;
      tapX = e.clientX; tapY = e.clientY;
      if (coarse.matches && !armed) return;
      dragging = true; dragId = e.pointerId; startY = e.clientY; startPos = pos; v = 0;
      trail = [{ t: e.timeStamp, p: pos }];
      try { vp.setPointerCapture(e.pointerId); } catch (_) { /* ignore */ }
      vp.classList.add('dragging');
      wakeD();
    });
    vp.addEventListener('pointermove', (e) => {
      if (!dragging || e.pointerId !== dragId) return;
      pos = clamp(startPos - (e.clientY - startY), 0, maxPos);
      render();
      trail.push({ t: e.timeStamp, p: pos });
      while (trail.length > 2 && e.timeStamp - trail[0].t > 100) trail.shift();
      wakeD();
    });
    const endDrag = (e) => {
      if (!dragging || e.pointerId !== dragId) return;
      dragging = false; dragId = null;
      vp.classList.remove('dragging');
      if (mode === 'flywheel' && trail.length > 1) {
        const a = trail[0]; const b = trail[trail.length - 1];
        const span = b.t - a.t;
        if (span > 0 && e.timeStamp - b.t < 80) v = (b.p - a.p) / span;
      }
      wakeD();
    };
    vp.addEventListener('pointerup', endDrag);
    vp.addEventListener('pointercancel', endDrag);
    vp.addEventListener('keydown', (e) => {
      const page = vh * 0.85;
      let d = 0;
      switch (e.key) {
        case 'ArrowDown': d = 60; break;
        case 'ArrowUp': d = -60; break;
        case 'PageDown': d = page; break;
        case 'PageUp': d = -page; break;
        case ' ': d = e.shiftKey ? -page : page; break;
        case 'Home': d = -projected(); break;
        case 'End': d = maxPos - projected(); break;
        default: return;
      }
      e.preventDefault();
      push(d);
    });
    let spinTimer = 0;
    spinBtn.addEventListener('click', () => {
      clearTimeout(spinTimer);
      const dir = projected() > maxPos * 0.55 ? -1 : 1;
      let n = 0;
      const tick = () => { push(dir * 44 * (1 + n * 0.05)); if (++n < 16) spinTimer = setTimeout(tick, 30); };
      tick();
    });
    radios.forEach((r) => r.addEventListener('change', () => {
      if (!r.checked) return;
      mode = r.value; v = 0;
      note.textContent = NOTES[mode];
    }));
    note.textContent = NOTES[mode];

    measureDemo();
    if ('ResizeObserver' in window) {
      new ResizeObserver(() => { measureDemo(); spark.resize(); spark.draw(performance.now()); }).observe(vp);
      new ResizeObserver(() => { spark.resize(); spark.draw(performance.now()); }).observe(canvas.parentElement);
    } else window.addEventListener('resize', () => { measureDemo(); spark.resize(); });
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(([e]) => { visible = e.isIntersecting; if (visible) wakeD(); }, { rootMargin: '120px' }).observe(box);
    } else { visible = true; }
    document.addEventListener('visibilitychange', () => { if (!document.hidden) wakeD(); });
    spark.draw(performance.now());
    if (demo === 'feel') { visible = true; spinBtn.click(); }
  }

  /* ============================================================ Overview: the instrument cluster
     Starts from an example day (the app's own sample numbers) and adds what you do on
     this page: pointer travel to "Ball rolled", page scrolling to "Scrolled", clicks to
     "Clicks today". Gauges fill toward each best; passing one is a new best, once. */
  function initLive() {
    if (!liveEl) return;
    const PX_PER_M = 3780; // CSS pixels in a metre (96 per inch)
    const stats = {
      clicks: { v: 2140, best: 3780, fmt: (n) => fmt(n) },
      ball: { v: 41.0, best: 66.7, fmt: (n) => n.toFixed(1) },
      scrolled: { v: 63.0, best: 118, fmt: (n) => n.toFixed(1) },
    };
    Object.entries(stats).forEach(([k, st]) => {
      st.out = $(`[data-lv-out="${k}"]`, liveEl);
      st.arc = $(`[data-lv-gauge="${k}"] [data-lv-arc]`, liveEl);
      st.g = $(`[data-lv-gauge="${k}"]`, liveEl);
      st.badge = $(`[data-lv-new="${k}"]`, liveEl);
      st.shown = -1;
      st.celebrated = false;
    });
    const ticks = $('[data-lv-ticks]', liveEl);
    const ballEl2 = $('.lv-ball', liveEl);
    const bsOut = $('[data-lv-bs]', liveEl);
    const rsOut = $('[data-lv-rs]', liveEl);
    const canvas = $('[data-lv-chart]', liveEl);
    const ctx = canvas.getContext('2d');
    let started = false;
    let intro = 0; // 0 → 1 while the numbers count up the first time
    let shownIntro = 0;
    let introT0 = 0;

    const paint = (k) => {
      const st = stats[k];
      const v = st.v * shownIntro;
      const text = st.fmt(v);
      if (text !== st.shown) { st.out.textContent = text; st.shown = text; }
      const f = clamp(v / st.best, 0, 1);
      st.arc.style.strokeDasharray = `${(f * 75).toFixed(2)} 100`;
      if (st.v > st.best && !st.celebrated && shownIntro >= 1) {
        st.celebrated = true;
        st.g.classList.add('best');
        st.badge.classList.add('show');
        $(`[data-lv-bestout="${k}"]`, liveEl).textContent = st.fmt(st.v);
      }
    };

    // Rates, smoothed, for the chart and the legend.
    let ballPx = 0; let ringPx = 0; // pixels since the last frame
    let ballRate = 0; let ringRate = 0; // in/s of ball, notches/s
    const hist = []; // [t, ball, ring]
    let raf3 = 0; let last = 0; let quiet = 0; let ringAngle = 0; let lvx = 0;
    let w = 0; let h = 0;
    const resize = () => {
      const r = canvas.getBoundingClientRect();
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      w = Math.max(1, Math.round(r.width)); h = Math.max(1, Math.round(r.height));
      canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    };
    const W = 6000;
    const draw = (now) => {
      ctx.clearRect(0, 0, w, h);
      ctx.strokeStyle = 'rgba(255,255,255,0.05)';
      ctx.lineWidth = 1;
      ctx.beginPath();
      for (let i = 1; i <= 3; i++) { const y = Math.round((h * i) / 4) + 0.5; ctx.moveTo(0, y); ctx.lineTo(w, y); }
      ctx.stroke();
      const trace = (idx, color, rgb, floor) => {
        let max = floor;
        hist.forEach((p) => { if (p[idx] > max) max = p[idx]; });
        const X = (t) => w - ((now - t) / W) * w;
        const Y = (v) => h - 3 - Math.min(1, v / max) * (h - 12);
        ctx.beginPath();
        ctx.moveTo(0, h - 3);
        if (hist.length) ctx.lineTo(Math.max(0, X(hist[0][0])), h - 3);
        hist.forEach((p) => ctx.lineTo(X(p[0]), Y(p[idx])));
        ctx.lineTo(w, hist.length ? Y(hist[hist.length - 1][idx]) : h - 3);
        ctx.lineJoin = 'round';
        ctx.strokeStyle = `rgba(${rgb},0.3)`; ctx.lineWidth = 6; ctx.stroke();
        ctx.strokeStyle = color; ctx.lineWidth = 2; ctx.stroke();
        ctx.lineTo(w, h); ctx.lineTo(0, h); ctx.closePath();
        const g = ctx.createLinearGradient(0, 0, 0, h);
        g.addColorStop(0, `rgba(${rgb},0.18)`); g.addColorStop(1, `rgba(${rgb},0)`);
        ctx.fillStyle = g; ctx.fill();
      };
      trace(1, '#4da8ff', PART_RGB.ball, 2);
      trace(2, '#ff5ca8', PART_RGB.ring, 8);
    };
    const loop = (t) => {
      const dt = clamp(t - last, 1, 64);
      last = t;
      if (started && intro < 1) intro = reduce.matches ? 1 : Math.min(1, (t - introT0) / 1400);
      shownIntro = started ? 1 - Math.pow(1 - intro, 3) : 0;
      const k = 1 - Math.exp(-dt / 160);
      ballRate += ((ballPx / 96 / speedRatio) / (dt / 1000) - ballRate) * k;
      ringRate += ((ringPx / 30) / (dt / 1000) - ringRate) * k;
      ringAngle += ringPx * K;
      lvx += ballPx * 0.4;
      ballPx = 0; ringPx = 0;
      if (ballRate < 0.01) ballRate = 0;
      if (ringRate < 0.05) ringRate = 0;
      hist.push([t, ballRate, ringRate]);
      while (hist.length > 2 && t - hist[0][0] > W + 200) hist.shift();
      Object.keys(stats).forEach(paint);
      bsOut.textContent = `${ballRate.toFixed(1)} in/s`;
      rsOut.textContent = `${Math.round(ringRate)} notches/s`;
      ticks.style.setProperty('--lv-ring', `${ringAngle.toFixed(1)}deg`);
      ballEl2.style.setProperty('--lv-x', `${lvx.toFixed(1)}px`);
      draw(t);
      quiet = (ballRate === 0 && ringRate === 0 && intro >= 1) ? quiet + dt : 0;
      raf3 = (quiet > W + 300 || !liveVisible) ? 0 : requestAnimationFrame(loop);
    };
    const wake3 = () => { quiet = 0; if (!raf3 && liveVisible) { last = performance.now(); raf3 = requestAnimationFrame(loop); } };

    window.addEventListener('pointermove', (e) => {
      if (!liveVisible || e.pointerType !== 'mouse') return;
      const d = Math.hypot(e.movementX || 0, e.movementY || 0);
      if (!d) return;
      ballPx += d;
      stats.ball.v += d / PX_PER_M;
      bump('ball', Math.min(0.6, d / 60));
      wake3();
    }, { passive: true });
    let ly2 = window.scrollY;
    window.addEventListener('scroll', () => {
      const dy = Math.abs(window.scrollY - ly2);
      ly2 = window.scrollY;
      if (!liveVisible || !dy) return;
      ringPx += dy;
      stats.scrolled.v += dy / PX_PER_M;
      bump('ring', Math.min(0.8, dy / 60));
      wake3();
    }, { passive: true });
    window.addEventListener('mousedown', () => {
      if (!liveVisible) return;
      stats.clicks.v += 1;
      bump('amber', 0.9);
      wake3();
    }, { passive: true });

    resize();
    if ('ResizeObserver' in window) new ResizeObserver(() => { resize(); draw(performance.now()); }).observe(canvas);
    Object.keys(stats).forEach(paint);
    draw(performance.now());
    const begin = () => {
      if (started) return;
      started = true;
      introT0 = performance.now();
      wake3();
    };
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(([e]) => {
        liveVisible = e.isIntersecting;
        if (liveVisible) { begin(); wake3(); }
      }, { threshold: 0.15 }).observe(liveEl);
    } else { liveVisible = true; begin(); }
    if (demo) { liveVisible = true; begin(); intro = 1; shownIntro = 1; Object.keys(stats).forEach(paint); }
  }

  /* ============================================================ The real app, on a loop */
  function initVideo() {
    const fig = $('[data-vid]');
    if (!fig) return;
    const video = $('video', fig);
    const btn = $('[data-vid-btn]', fig);
    if (!video || !btn) return;
    let visible = false;
    let userPaused = reduce.matches; // reduced motion: it waits for you to press play
    const paint = () => {
      const playing = !video.paused;
      btn.setAttribute('aria-pressed', String(playing));
      btn.setAttribute('aria-label', playing ? 'Pause video' : 'Play video');
    };
    const go = () => { const p = video.play(); if (p && p.catch) p.catch(() => {}); };
    const sync = () => {
      if (visible && !userPaused && !document.hidden) go();
      else video.pause();
    };
    video.addEventListener('play', paint);
    video.addEventListener('pause', paint);
    btn.addEventListener('click', () => {
      if (video.paused) { userPaused = false; go(); } else { userPaused = true; video.pause(); }
    });
    document.addEventListener('visibilitychange', sync);
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(([e]) => { visible = e.isIntersecting; sync(); }, { threshold: 0.35 }).observe(fig);
    }
    paint();
  }

  /* ============================================================ End of the page: one pink sweep, once */
  function initArrival() {
    const closing = $('.closing');
    if (!closing || !('IntersectionObserver' in window) || demo) return;
    const io = new IntersectionObserver(([e]) => {
      if (!e.isIntersecting) return;
      io.disconnect();
      if (reduce.matches) return;
      closing.classList.add('arrived');
      if (dock) {
        dock.classList.add('sweep');
        setTimeout(() => dock.classList.remove('sweep'), 1600);
      }
    }, { threshold: 0.55 });
    io.observe(closing);
  }

  /* ============================================================ Boot */
  requestAnimationFrame(() => requestAnimationFrame(() => hx.classList.add('ready')));
  initLive();
  initOdometers();
  initPointer();
  initRing();
  initButtons();
  initDemo();
  initVideo();
  initArrival();
  updateDock();

  // Screenshot states (?demo=...). They only set what you'd see after doing it yourself.
  if (demo) {
    const states = {
      roll() { frozen = true; rx = 140; ry = 60; vx = 2.2; vy = 0.9; light.ball = 0.9; aimX = 0.5; aimY = 0.2; lx = 0.5; ly = 0.2; chip('ball', true); readout(2.4, true); },
      ring() { frozen = true; angle = 38; light.ring = 1; chip('ring', true); say('Ring:', '14 notches a second', 'ring', { hold: 0 }); },
      'pad-tl'() { frozen = true; lightPad('tl'); light.amber = 1; say('Top left:', 'Mission Control', 'buttons', { hold: 0 }); },
      combo() { frozen = true; lightPad('br'); lightPad('tr'); light.amber = 1; say('Bottom right + top right:', 'Mission Control', 'buttons', { hold: 0 }); },
      mc() { openMC('mc'); },
      spot() { openMC('spot'); mcSearch.value = 'in'; fillMC('in'); },
      menu() { frozen = true; lightPad('br'); light.amber = 1; openCtx($('[data-pad="br"]', stage), 'br'); },
      all() { frozen = true; light.ball = 0.7; light.ring = 0.8; angle = 20; rx = 90; ry = 30; vx = 1.6; vy = 0.6; lightPad('tl'); light.amber = 0.7; },
    };
    if (states[demo]) states[demo]();
    apply();
  }
})();
