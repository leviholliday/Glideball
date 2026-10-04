/* Glide — site interactions. Vanilla JS, no dependencies, no tracking. */
(() => {
  'use strict';

  const root = document.documentElement;
  root.classList.add('js');

  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const lightScheme = window.matchMedia('(prefers-color-scheme: light)');
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  const hasIO = 'IntersectionObserver' in window;

  /** Calls cb(true/false) as the element enters / leaves the viewport. */
  function watchVisibility(el, cb, margin = '120px') {
    if (!hasIO) { cb(true); return; }
    new IntersectionObserver((entries) => {
      entries.forEach((entry) => cb(entry.isIntersecting));
    }, { rootMargin: margin }).observe(el);
  }

  function hexToRgba(hex, a) {
    const m = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(hex.trim());
    if (!m) return hex;
    let h = m[1];
    if (h.length === 3) h = h.split('').map((c) => c + c).join('');
    const n = parseInt(h, 16);
    return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${a})`;
  }

  /* ------------------------------------------------------------ Reveal */
  function initReveal() {
    const els = Array.from(document.querySelectorAll('.reveal'));
    // Stagger siblings that reveal together (grids of cards).
    els.forEach((el) => {
      const sibs = Array.from(el.parentElement.children).filter((c) => c.classList.contains('reveal'));
      const i = sibs.indexOf(el);
      if (sibs.length > 2 && i > 0) el.style.setProperty('--d', `${Math.min(i, 5) * 70}ms`);
    });
    if (!hasIO || reduceMotion.matches) {
      els.forEach((el) => el.classList.add('in'));
      return;
    }
    const io = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add('in');
          io.unobserve(entry.target);
        }
      });
    }, { rootMargin: '0px 0px -6% 0px', threshold: 0.06 });
    els.forEach((el) => io.observe(el));
  }

  /* ------------------------------------------------------------ Hero tilt */
  function initTilt() {
    const el = document.querySelector('[data-tilt]');
    if (!el) return;
    let queued = false;
    const update = () => {
      queued = false;
      if (reduceMotion.matches) { el.style.setProperty('--tilt', '0'); return; }
      const r = el.getBoundingClientRect();
      const vh = window.innerHeight || 1;
      // 1 while the shot's top sits low in the viewport, easing to 0 as it scrolls up.
      const t = clamp((r.top - vh * 0.18) / (vh * 0.55), 0, 1);
      el.style.setProperty('--tilt', t.toFixed(3));
    };
    const queue = () => { if (!queued) { queued = true; requestAnimationFrame(update); } };
    window.addEventListener('scroll', queue, { passive: true });
    window.addEventListener('resize', queue);
    update();
  }

  /* ------------------------------------------------------------ Sparkline (canvas) */
  class Spark {
    constructor(canvas, { windowMs = 3000, floor = 1000, colors = ['--cyan', '--violet'] } = {}) {
      this.canvas = canvas;
      this.ctx = canvas.getContext('2d');
      this.windowMs = windowMs;
      this.floor = floor;
      this.scale = floor;
      this.colorVars = colors;
      this.samples = []; // flat [t0, v0, t1, v1, ...]
      this.readColors();
      this.resize();
    }

    readColors() {
      const cs = getComputedStyle(this.canvas);
      this.c1 = cs.getPropertyValue(this.colorVars[0]).trim() || '#67e8f9';
      this.c2 = cs.getPropertyValue(this.colorVars[1]).trim() || '#a78bfa';
      this.grid = cs.getPropertyValue('--line').trim() || 'rgba(255,255,255,.1)';
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
      // After an idle gap (the loop sleeps when nothing moves), restart from a flat baseline
      // instead of drawing a ramp from the last old sample.
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

      // Recessive grid
      ctx.lineWidth = 1;
      ctx.strokeStyle = this.grid;
      ctx.beginPath();
      for (let i = 1; i <= 3; i++) {
        const y = Math.round((h * i) / 4) + 0.5;
        ctx.moveTo(0, y);
        ctx.lineTo(w, y);
      }
      ctx.stroke();

      let s = this.samples;
      if (s.length < 2) s = [now - this.windowMs - 20, 0, now, 0]; // nothing yet: flat baseline
      // The loop sleeps once things are still, so any time after the last sample was quiet: extend at 0.
      const lastT = s[s.length - 2];
      if (now - lastT > 34) s = s.concat([lastT + 17, 0, now, 0]);

      let max = this.floor;
      for (let i = 1; i < s.length; i += 2) if (s[i] > max) max = s[i];
      this.scale += (max * 1.12 - this.scale) * 0.12;

      const top = 6;
      const base = h - 2;
      const X = (t) => w - ((now - t) / this.windowMs) * w;
      const Y = (v) => base - Math.min(1, v / this.scale) * (base - top);

      // If history doesn't fill the window yet, lead in with a flat baseline from the left edge.
      const lead = X(s[0]) > 0;
      const trace = () => {
        ctx.beginPath();
        if (lead) { ctx.moveTo(0, base); ctx.lineTo(X(s[0]), base); ctx.lineTo(X(s[0]), Y(s[1])); }
        else ctx.moveTo(X(s[0]), Y(s[1]));
        for (let i = 2; i < s.length; i += 2) ctx.lineTo(X(s[i]), Y(s[i + 1]));
      };

      // Area
      trace();
      ctx.lineTo(X(s[s.length - 2]), base);
      ctx.lineTo(lead ? 0 : X(s[0]), base);
      ctx.closePath();
      const fill = ctx.createLinearGradient(0, top, 0, base);
      fill.addColorStop(0, hexToRgba(this.c2, 0.34));
      fill.addColorStop(1, hexToRgba(this.c1, 0));
      ctx.fillStyle = fill;
      ctx.fill();

      // Line
      trace();
      const stroke = ctx.createLinearGradient(0, 0, w, 0);
      stroke.addColorStop(0, this.c1);
      stroke.addColorStop(1, this.c2);
      ctx.strokeStyle = stroke;
      ctx.lineWidth = 2;
      ctx.lineJoin = 'round';
      ctx.lineCap = 'round';
      ctx.stroke();
    }
  }

  const sparks = [];
  lightScheme.addEventListener?.('change', () => sparks.forEach((sp) => sp.readColors()));

  /* ------------------------------------------------------------ Response curve */
  function initCurve() {
    const card = document.querySelector('[data-curve]');
    if (!card) return;
    const svg = card.querySelector('svg');
    const line = card.querySelector('[data-curve-line]');
    const area = card.querySelector('[data-curve-area]');
    const mac = card.querySelector('[data-curve-mac]');
    const macTag = card.querySelector('[data-curve-mactag]');
    const dot = card.querySelector('[data-curve-dot]');
    const halo = card.querySelector('[data-curve-halo]');
    const input = card.querySelector('#speed');
    const out = card.querySelector('[data-speed-out]');

    // Plot box in viewBox units
    const X0 = 10, X1 = 310, Y0 = 168, Y1 = 8;
    const P = 2.2;
    const MAC_MAX = 3;
    const gain = (s) => 0.1 + s * 0.09;
    const fy = (x, s) => gain(s) * Math.pow(x, P);
    const toX = (x) => X0 + x * (X1 - X0);
    const toY = (y) => Y0 - y * (Y0 - Y1);
    const xLimit = (s) => Math.min(1, Math.pow(1 / gain(s), 1 / P));

    const pathFor = (s, steps = 72) => {
      const xm = xLimit(s);
      let d = '';
      for (let i = 0; i <= steps; i++) {
        const x = (i / steps) * xm;
        d += `${i ? 'L' : 'M'}${toX(x).toFixed(2)} ${toY(fy(x, s)).toFixed(2)}`;
      }
      return { d, xm };
    };

    const macPath = pathFor(MAC_MAX);
    mac.setAttribute('d', macPath.d);
    macTag.setAttribute('y', (toY(fy(1, MAC_MAX)) - 8).toFixed(1));

    let speed = Number(input.value);
    let xm = 1;
    let hoverX = null;

    const placeDot = (x) => {
      const cx = toX(x).toFixed(2);
      const cy = toY(fy(x, speed)).toFixed(2);
      dot.setAttribute('cx', cx); dot.setAttribute('cy', cy);
      halo.setAttribute('cx', cx); halo.setAttribute('cy', cy);
    };

    const drawCurve = () => {
      const p = pathFor(speed);
      xm = p.xm;
      line.setAttribute('d', p.d);
      area.setAttribute('d', p.d); // soft glow under the line
      out.textContent = String(speed);
      const pct = ((speed - Number(input.min)) / (Number(input.max) - Number(input.min))) * 100;
      input.style.setProperty('--fill', `${pct}%`);
      if (reduceMotion.matches || !running) placeDot(hoverX ?? xm * 0.62);
    };

    input.addEventListener('input', () => { speed = Number(input.value); drawCurve(); });

    const toPlotX = (clientX) => {
      const r = svg.getBoundingClientRect();
      const vbX = ((clientX - r.left) / r.width) * 320;
      return clamp((vbX - X0) / (X1 - X0), 0, 1);
    };
    svg.addEventListener('pointermove', (e) => {
      hoverX = Math.min(toPlotX(e.clientX), xm);
      if (!running) placeDot(hoverX);
    });
    svg.addEventListener('pointerleave', () => { hoverX = null; if (!running) placeDot(xm * 0.62); });

    // Gentle "roll the ball" animation of the dot along the curve.
    let running = false;
    let visible = false;
    let phase = 0.15;
    let last = 0;
    const frame = (t) => {
      if (!visible || reduceMotion.matches) { running = false; last = 0; return; }
      const dt = last ? Math.min(t - last, 50) : 16;
      last = t;
      if (hoverX == null) {
        phase += dt / 3400;
        const u = 0.5 - 0.5 * Math.cos(phase * Math.PI * 2);
        placeDot(0.03 + u * (xm * 0.97 - 0.03));
      } else {
        placeDot(Math.min(hoverX, xm));
      }
      requestAnimationFrame(frame);
    };
    watchVisibility(card, (v) => {
      visible = v;
      if (v && !running && !reduceMotion.matches) { running = true; requestAnimationFrame(frame); }
    }, '0px');

    drawCurve();
  }

  /* ------------------------------------------------------------ Flywheel demo */
  function initDemo() {
    const demo = document.querySelector('[data-demo]');
    if (!demo) return;
    const vp = demo.querySelector('[data-fw-viewport]');
    const track = demo.querySelector('[data-fw-track]');
    const thumb = demo.querySelector('[data-fw-thumb]');
    const canvas = demo.querySelector('[data-fw-canvas]');
    const speedOut = demo.querySelector('[data-fw-speed]');
    const note = demo.querySelector('[data-fw-note]');
    const spinBtn = demo.querySelector('[data-fw-spin]');
    const radios = demo.querySelectorAll('input[name="fw-mode"]');

    const TAU = 82; // ms — friction time constant
    const NOTES = {
      plain: 'Plain wheel: every tick jumps the page its full distance in a single frame. That jolt is what you feel.',
      flywheel: 'Flywheel: each tick adds a push, and friction (τ ≈ 82 ms) glides it to a stop. Same distance, no jolts.',
    };

    // Build rows
    const frag = document.createDocumentFragment();
    for (let i = 0; i < 90; i++) {
      const li = document.createElement('li');
      li.className = 'fw-row';
      const dotEl = document.createElement('span');
      dotEl.className = 'fw-dot';
      dotEl.style.color = `hsl(${(14 + i * 8) % 360} 85% 66%)`;
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

    let mode = (Array.from(radios).find((r) => r.checked) || {}).value || 'flywheel';
    let pos = 0;        // px
    let v = 0;          // px per ms
    let maxPos = 0;
    let vh = 0;
    let barH = 0;

    const render = () => {
      track.style.transform = `translate3d(0, ${(-pos).toFixed(2)}px, 0)`;
      const total = maxPos + vh;
      const th = total > 0 ? Math.max(28, (vh / total) * barH) : barH;
      const ty = maxPos > 0 ? (pos / maxPos) * (barH - th) : 0;
      thumb.style.height = `${th.toFixed(1)}px`;
      thumb.style.transform = `translate3d(0, ${ty.toFixed(2)}px, 0)`;
    };

    const measure = () => {
      vh = vp.clientHeight;
      barH = Math.max(0, vh - 28);
      maxPos = Math.max(0, track.offsetHeight - vh);
      pos = clamp(pos, 0, maxPos);
      render();
    };

    const spark = new Spark(canvas, { windowMs: 3000, floor: 1200 });
    sparks.push(spark);

    // ---- animation loop (runs only while visible and something is happening)
    let running = false;
    let visible = false;
    let lastT = 0;
    let lastPos = 0;
    let quietFor = 0;
    let shownSpeed = 0;
    let dragging = false;

    const frame = (t) => {
      if (!visible || document.hidden) { running = false; lastT = 0; return; }
      const dt = lastT ? Math.min(t - lastT, 64) : 16.7;
      lastT = t;

      if (mode === 'flywheel' && !dragging && v !== 0) {
        const k = Math.exp(-dt / TAU);
        // Exact integral of v·e^(−t/τ) over this frame, so the glide is frame-rate independent
        // and the total distance of every push equals the tick's delta.
        let next = pos + v * TAU * (1 - k);
        v *= k;
        if (next <= 0 || next >= maxPos) { next = clamp(next, 0, maxPos); v = 0; }
        if (Math.abs(v) < 0.002) v = 0; // below 2 px/s: stop
        pos = next;
        render();
      }

      const speed = (Math.abs(pos - lastPos) / dt) * 1000; // px/s
      lastPos = pos;
      spark.push(t, speed);
      spark.draw(t);

      shownSpeed += (speed - shownSpeed) * 0.18;
      speedOut.textContent = String(Math.round(shownSpeed < 1 ? 0 : shownSpeed));

      quietFor = (speed < 0.5 && v === 0 && !dragging) ? quietFor + dt : 0;
      if (quietFor > 3300) { running = false; lastT = 0; speedOut.textContent = '0'; return; }
      requestAnimationFrame(frame);
    };

    const wake = () => {
      quietFor = 0;
      if (!running && visible) { running = true; requestAnimationFrame(frame); }
    };

    const projected = () => pos + (mode === 'flywheel' ? v * TAU : 0);

    /** One scroll "tick" of d pixels. */
    const push = (d) => {
      if (!d) return;
      if (mode === 'plain') {
        pos = clamp(pos + d, 0, maxPos);
        render();
      } else {
        v += d / TAU; // each tick adds velocity; friction spreads it into a glide
      }
      wake();
    };

    // ---- wheel (contained: only while the pointer is over the list)
    vp.addEventListener('wheel', (e) => {
      if (e.ctrlKey) return; // let pinch-zoom through
      if (Math.abs(e.deltaX) > Math.abs(e.deltaY)) return;
      e.preventDefault();
      let d = e.deltaY;
      if (e.deltaMode === 1) d *= 40;
      else if (e.deltaMode === 2) d *= vh;
      push(d);
    }, { passive: false });

    // ---- drag / flick
    let dragId = null;
    let startY = 0;
    let startPos = 0;
    let trail = [];
    vp.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;
      dragging = true;
      dragId = e.pointerId;
      startY = e.clientY;
      startPos = pos;
      v = 0;
      trail = [{ t: e.timeStamp, p: pos }];
      try { vp.setPointerCapture(e.pointerId); } catch (_) { /* ignore */ }
      vp.classList.add('dragging');
      wake();
    });
    vp.addEventListener('pointermove', (e) => {
      if (!dragging || e.pointerId !== dragId) return;
      pos = clamp(startPos - (e.clientY - startY), 0, maxPos);
      render();
      trail.push({ t: e.timeStamp, p: pos });
      while (trail.length > 2 && e.timeStamp - trail[0].t > 100) trail.shift();
      wake();
    });
    const endDrag = (e) => {
      if (!dragging || e.pointerId !== dragId) return;
      dragging = false;
      dragId = null;
      vp.classList.remove('dragging');
      if (mode === 'flywheel' && trail.length > 1) {
        const a = trail[0];
        const b = trail[trail.length - 1];
        const span = b.t - a.t;
        if (span > 0 && e.timeStamp - b.t < 80) v = (b.p - a.p) / span; // release velocity, px/ms
      }
      wake();
    };
    vp.addEventListener('pointerup', endDrag);
    vp.addEventListener('pointercancel', endDrag);

    // ---- keyboard
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

    // ---- simulated spin (for visitors without a wheel)
    let spinTimer = 0;
    spinBtn.addEventListener('click', () => {
      clearTimeout(spinTimer);
      const dir = projected() > maxPos * 0.55 ? -1 : 1;
      let n = 0;
      const tick = () => {
        push(dir * 44 * (1 + n * 0.05));
        if (++n < 16) spinTimer = setTimeout(tick, 30);
      };
      tick();
    });

    // ---- mode switch
    radios.forEach((r) => r.addEventListener('change', () => {
      if (!r.checked) return;
      mode = r.value;
      v = 0;
      note.textContent = NOTES[mode];
    }));
    note.textContent = NOTES[mode];

    // ---- sizing & visibility
    measure();
    if ('ResizeObserver' in window) {
      new ResizeObserver(() => { measure(); spark.resize(); spark.draw(performance.now()); }).observe(vp);
      new ResizeObserver(() => { spark.resize(); spark.draw(performance.now()); }).observe(canvas.parentElement);
    } else {
      window.addEventListener('resize', () => { measure(); spark.resize(); });
    }
    watchVisibility(demo, (isVisible) => {
      visible = isVisible;
      if (isVisible) wake();
    });
    document.addEventListener('visibilitychange', () => { if (!document.hidden) wake(); });
    spark.draw(performance.now());
  }

  /* ------------------------------------------------------------ Mini dashboard */
  function initDash() {
    const card = document.querySelector('[data-dash]');
    if (!card) return;
    const pads = card.querySelectorAll('[data-pad]');
    const shine = card.querySelector('[data-dash-shine]');
    const canvas = card.querySelector('[data-dash-canvas]');
    const speedOut = card.querySelector('[data-dash-speed]');
    const clicksOut = card.querySelector('[data-dash-clicks]');

    const spark = new Spark(canvas, { windowMs: 4000, floor: 900, colors: ['--cyan', '--violet'] });
    sparks.push(spark);

    let clicks = 0;
    const press = (pad) => {
      pad.classList.add('lit');
      clicks += 1;
      clicksOut.textContent = String(clicks);
    };
    const release = (pad) => pad.classList.remove('lit');

    pads.forEach((pad) => {
      pad.addEventListener('pointerdown', (e) => { if (e.button === 0) press(pad); });
      pad.addEventListener('pointerup', () => release(pad));
      pad.addEventListener('pointerleave', () => release(pad));
      pad.addEventListener('pointercancel', () => release(pad));
      pad.addEventListener('keydown', (e) => {
        if ((e.key === ' ' || e.key === 'Enter') && !e.repeat) { e.preventDefault(); press(pad); }
      });
      pad.addEventListener('keyup', (e) => { if (e.key === ' ' || e.key === 'Enter') release(pad); });
      pad.addEventListener('blur', () => release(pad));
    });

    let acc = 0;
    let lastX = null;
    let lastY = 0;
    let rollX = 0;
    let rollY = 0;
    card.addEventListener('pointermove', (e) => {
      if (lastX !== null) {
        const dx = e.clientX - lastX;
        const dy = e.clientY - lastY;
        acc += Math.hypot(dx, dy);
        rollX = clamp(rollX + dx * 0.18, -16, 16);
        rollY = clamp(rollY + dy * 0.18, -14, 14);
      }
      lastX = e.clientX;
      lastY = e.clientY;
      wake();
    });
    card.addEventListener('pointerleave', () => { lastX = null; });

    let running = false;
    let visible = false;
    let lastT = 0;
    let ema = 0;
    let quietFor = 0;
    const frame = (t) => {
      if (!visible || document.hidden) { running = false; lastT = 0; return; }
      const dt = lastT ? Math.min(t - lastT, 64) : 16.7;
      lastT = t;
      const inst = (acc / dt) * 1000;
      acc = 0;
      ema += (inst - ema) * 0.3;
      if (ema < 1) ema = 0;
      spark.push(t, ema);
      spark.draw(t);
      speedOut.textContent = String(Math.round(ema));

      if (!reduceMotion.matches) {
        rollX *= 0.9;
        rollY *= 0.9;
        shine.style.transform = `translate3d(${rollX.toFixed(2)}px, ${rollY.toFixed(2)}px, 0)`;
      }

      quietFor = ema === 0 ? quietFor + dt : 0;
      if (quietFor > 4300) { running = false; lastT = 0; return; }
      requestAnimationFrame(frame);
    };
    const wake = () => {
      quietFor = 0;
      if (!running && visible) { running = true; requestAnimationFrame(frame); }
    };

    if ('ResizeObserver' in window) {
      new ResizeObserver(() => { spark.resize(); spark.draw(performance.now()); }).observe(canvas.parentElement);
    }
    watchVisibility(card, (isVisible) => { visible = isVisible; if (isVisible) wake(); });
    spark.draw(performance.now());
  }

  /* ------------------------------------------------------------ Boot */
  const boot = () => {
    initReveal();
    initTilt();
    initCurve();
    initDemo();
    initDash();
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
