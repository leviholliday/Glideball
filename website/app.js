/* Glide — site interactions. Vanilla JS, no dependencies, no tracking. */
(() => {
  'use strict';

  const root = document.documentElement;
  root.classList.add('js');

  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const lightScheme = window.matchMedia('(prefers-color-scheme: light)');
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  const hasIO = 'IntersectionObserver' in window;
  const finePointer = window.matchMedia('(hover: hover) and (pointer: fine)');
  const fmtInt = (n) => Math.round(n).toLocaleString('en-US');

  /** Re-triggers a one-shot CSS animation class. */
  function pulse(el, cls) {
    el.classList.remove(cls);
    void el.offsetWidth; // restart the animation
    el.classList.add(cls);
  }

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
    const fm = demo.querySelector('[data-fm]');

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
    let rowH = 52;

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
      rowH = (track.firstElementChild && track.firstElementChild.offsetHeight) || 52;
      pos = clamp(pos, 0, maxPos);
      render();
    };

    const spark = new Spark(canvas, { windowMs: 3000, floor: 1200 });
    sparks.push(spark);

    // ---- flick meter: your best moments in this visit. Nothing is stored or sent.
    const meter = (() => {
      if (!fm) return { update() {} };
      const bar = fm.querySelector('.fm-bar');
      const fill = fm.querySelector('[data-fm-fill]');
      const bestMark = fm.querySelector('[data-fm-best]');
      const topOut = fm.querySelector('[data-fm-top]');
      const glideOut = fm.querySelector('[data-fm-glide]');
      const totalOut = fm.querySelector('[data-fm-total]');
      const badge = fm.querySelector('[data-fm-badge]');
      const live = fm.querySelector('[data-fm-live]');
      const FULL = 6000; // px/s for a full bar
      let best = 0;
      let longest = 0;
      let total = 0;
      let glidePeak = 0;
      let glideDist = 0;
      let inGlide = false;
      let stillFor = 0;
      let shownTotal = -1;
      let badgeTimer = 0;

      const placeBest = () => {
        bestMark.style.setProperty('--best-x', `${(clamp(best / FULL, 0, 1) * bar.clientWidth).toFixed(1)}px`);
        bestMark.classList.add('on');
      };
      if ('ResizeObserver' in window) new ResizeObserver(() => { if (best) placeBest(); }).observe(bar);

      const celebrate = () => {
        badge.classList.add('show');
        clearTimeout(badgeTimer);
        badgeTimer = setTimeout(() => badge.classList.remove('show'), 1800);
        if (!reduceMotion.matches) {
          pulse(fm, 'record');
          const r = badge.getBoundingClientRect();
          Confetti.burst(r.left + r.width / 2, r.top + r.height / 2, { count: 34, power: 0.5, spread: 1.1 });
        }
        live.textContent = `New best: ${fmtInt(best)} pixels per second.`;
      };

      const endGlide = () => {
        inGlide = false;
        stillFor = 0;
        const rows = glideDist / rowH;
        if (rows >= 1 && rows > longest + 0.5) {
          longest = rows;
          glideOut.textContent = fmtInt(Math.floor(longest));
          if (!reduceMotion.matches) pulse(glideOut, 'bump');
        }
        const previous = best;
        if (glidePeak > best + 1) {
          best = glidePeak;
          topOut.textContent = fmtInt(best);
          if (!reduceMotion.matches) pulse(topOut, 'bump');
          placeBest();
          // Only a real improvement on a real flick earns the fanfare.
          if (previous >= 600 && best >= previous * 1.05) celebrate();
        }
        glidePeak = 0;
        glideDist = 0;
      };

      return {
        update(speed, moved, dt) {
          fill.style.setProperty('--v', clamp(speed / FULL, 0, 1).toFixed(3));
          if (moved > 0.25) {
            total += moved;
            glideDist += moved;
            glidePeak = Math.max(glidePeak, speed);
            inGlide = true;
            stillFor = 0;
          } else if (inGlide) {
            stillFor += dt;
            if (stillFor > 220 || dt === 0) endGlide();
          }
          const rowsTotal = Math.floor(total / rowH);
          if (rowsTotal !== shownTotal) { shownTotal = rowsTotal; totalOut.textContent = fmtInt(rowsTotal); }
        },
      };
    })();

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

      const moved = Math.abs(pos - lastPos);
      const speed = (moved / dt) * 1000; // px/s
      lastPos = pos;
      spark.push(t, speed);
      spark.draw(t);

      shownSpeed += (speed - shownSpeed) * 0.18;
      speedOut.textContent = String(Math.round(shownSpeed < 1 ? 0 : shownSpeed));
      meter.update(shownSpeed, moved, dt);

      quietFor = (speed < 0.5 && v === 0 && !dragging) ? quietFor + dt : 0;
      if (quietFor > 3300) { running = false; lastT = 0; speedOut.textContent = '0'; meter.update(0, 0, 0); return; }
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
    const stage = card.querySelector('[data-dash-stage]');
    const ring = card.querySelector('.tb-ring');
    let ringAngle = 0;

    const spark = new Spark(canvas, { windowMs: 4000, floor: 900, colors: ['--cyan', '--violet'] });
    sparks.push(spark);

    let clicks = 0;
    const press = (pad) => {
      pad.classList.add('lit');
      if (!reduceMotion.matches) pulse(pad, 'ripple');
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
        // The scroll ring turns with your pointer, like the app's live view.
        if (ema > 0) {
          ringAngle = (ringAngle + ema * dt * 0.00022) % 360;
          ring.style.transform = `rotate(${ringAngle.toFixed(2)}deg)`;
        }
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
    watchVisibility(card, (isVisible) => {
      visible = isVisible;
      stage.classList.toggle('idle', isVisible && !reduceMotion.matches);
      if (isVisible) wake();
    });
    spark.draw(performance.now());
  }

  /* ------------------------------------------------------------ Confetti */
  /** A short canvas burst. The canvas exists only while pieces are flying. */
  const Confetti = (() => {
    const COLORS = ['#a78bfa', '#67e8f9', '#f472b6', '#fde68a', '#818cf8', '#5eead4'];
    let canvas = null;
    let ctx = null;
    let pieces = [];
    let raf = 0;
    let last = 0;

    const size = () => {
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      canvas.width = Math.round(window.innerWidth * dpr);
      canvas.height = Math.round(window.innerHeight * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    };

    const step = (t) => {
      const dt = clamp((t - last) / 1000, 0, 0.05);
      last = t;
      ctx.clearRect(0, 0, window.innerWidth, window.innerHeight);
      const k = 2.3;       // air drag
      const g = 1150;      // gravity, px/s²
      pieces = pieces.filter((p) => {
        p.age += dt;
        if (p.age < 0) return true;
        if (p.age > p.life) return false;
        p.vx -= p.vx * k * dt;
        p.vy += (g - p.vy * k) * dt;
        p.x += p.vx * dt;
        p.y += p.vy * dt;
        p.rot += p.vr * dt;
        ctx.save();
        ctx.globalAlpha = Math.min(1, (p.life - p.age) / 0.5);
        ctx.translate(p.x, p.y);
        ctx.rotate(p.rot);
        ctx.scale(Math.max(0.15, Math.abs(Math.cos(p.age * p.flutter))), 1);
        ctx.fillStyle = p.color;
        if (p.round) { ctx.beginPath(); ctx.arc(0, 0, p.h * 0.6, 0, Math.PI * 2); ctx.fill(); }
        else ctx.fillRect(-p.w / 2, -p.h / 2, p.w, p.h);
        ctx.restore();
        return true;
      });
      if (pieces.length) { raf = requestAnimationFrame(step); return; }
      raf = 0;
      window.removeEventListener('resize', size);
      canvas.remove();
      canvas = null;
    };

    return {
      burst(x, y, { count = 110, power = 1, spread = 0.7 } = {}) {
        if (reduceMotion.matches) return;
        if (!canvas) {
          canvas = document.createElement('canvas');
          canvas.className = 'confetti';
          canvas.setAttribute('aria-hidden', 'true');
          document.body.append(canvas);
          ctx = canvas.getContext('2d');
          size();
          window.addEventListener('resize', size);
        }
        for (let i = 0; i < count; i++) {
          const angle = -Math.PI / 2 + (Math.random() * 2 - 1) * spread;
          const speed = (480 + Math.random() * 700) * power;
          pieces.push({
            x,
            y,
            vx: Math.cos(angle) * speed,
            vy: Math.sin(angle) * speed,
            age: -Math.random() * 0.08,
            life: 1.5 + Math.random() * 0.9,
            rot: Math.random() * Math.PI,
            vr: (Math.random() * 2 - 1) * 10,
            flutter: 6 + Math.random() * 8,
            w: 6 + Math.random() * 5,
            h: 3.5 + Math.random() * 2.5,
            round: Math.random() < 0.22,
            color: COLORS[(Math.random() * COLORS.length) | 0],
          });
        }
        if (!raf) { last = performance.now(); raf = requestAnimationFrame(step); }
      },
    };
  })();

  /* ------------------------------------------------------------ Download: confetti + what's next */
  function initDownload() {
    const links = document.querySelectorAll('a[href$="/releases/latest/download/Glide.zip"]');
    if (!links.length) return;
    let toast = null;
    let hideTimer = 0;
    let lastBurst = 0;

    const hide = () => {
      if (!toast) return;
      const el = toast;
      toast = null;
      clearTimeout(hideTimer);
      if (reduceMotion.matches) { el.remove(); return; }
      el.classList.add('leaving');
      el.addEventListener('animationend', () => el.remove(), { once: true });
      setTimeout(() => el.remove(), 600);
    };

    const show = () => {
      if (toast) { clearTimeout(hideTimer); hideTimer = setTimeout(hide, 9000); return; }
      const svgNS = 'http://www.w3.org/2000/svg';
      toast = document.createElement('div');
      toast.className = 'dl-toast glass';
      toast.setAttribute('role', 'status');

      const check = document.createElement('span');
      check.className = 'dl-check';
      const svg = document.createElementNS(svgNS, 'svg');
      svg.setAttribute('class', 'icon');
      svg.setAttribute('aria-hidden', 'true');
      const use = document.createElementNS(svgNS, 'use');
      use.setAttribute('href', '#i-check');
      svg.append(use);
      check.append(svg);

      const text = document.createElement('div');
      text.className = 'dl-text';
      const title = document.createElement('strong');
      title.textContent = 'Glide is on its way';
      const next = document.createElement('span');
      next.append('Unzip it and drag Glide to Applications. ');
      const steps = document.createElement('a');
      steps.href = '#install';
      steps.textContent = 'First-launch tips';
      steps.addEventListener('click', hide);
      next.append(steps);
      text.append(title, next);

      const close = document.createElement('button');
      close.type = 'button';
      close.className = 'dl-close';
      close.setAttribute('aria-label', 'Dismiss');
      close.textContent = '×';
      close.addEventListener('click', hide);

      toast.append(check, text, close);
      document.body.append(toast);
      hideTimer = setTimeout(hide, 9000);
    };

    links.forEach((a) => a.addEventListener('click', () => {
      // Never delay or block the download: celebrate alongside it.
      const now = performance.now();
      if (now - lastBurst > 900) {
        lastBurst = now;
        const r = a.getBoundingClientRect();
        Confetti.burst(r.left + r.width / 2, r.top + r.height / 2);
      }
      show();
    }));
  }

  /* ------------------------------------------------------------ Magnetic buttons */
  function initMagnetic() {
    if (!finePointer.matches || reduceMotion.matches) return;
    document.querySelectorAll('.btn-primary').forEach((btn) => {
      let raf = 0;
      let px = 0;
      let py = 0;
      let mx = 0;
      let my = 0;
      const apply = () => {
        raf = 0;
        const r = btn.getBoundingClientRect();
        // Measure from where the button would be without its current pull.
        const cx = r.left - mx + r.width / 2;
        const cy = r.top - my + r.height / 2;
        mx = clamp((px - cx) * 0.16, -8, 8);
        my = clamp((py - cy) * 0.28, -5, 5);
        btn.style.setProperty('--mx', `${mx.toFixed(2)}px`);
        btn.style.setProperty('--my', `${my.toFixed(2)}px`);
        btn.style.setProperty('--gx', `${(((px - r.left) / r.width) * 100).toFixed(1)}%`);
        btn.style.setProperty('--gy', `${(((py - r.top) / r.height) * 100).toFixed(1)}%`);
      };
      btn.addEventListener('pointerenter', () => btn.classList.add('magnet'));
      btn.addEventListener('pointermove', (e) => {
        px = e.clientX;
        py = e.clientY;
        if (!raf) raf = requestAnimationFrame(apply);
      });
      btn.addEventListener('pointerleave', () => {
        cancelAnimationFrame(raf);
        raf = 0;
        mx = 0;
        my = 0;
        btn.style.setProperty('--mx', '0px');
        btn.style.setProperty('--my', '0px');
      });
    });
  }

  /* ------------------------------------------------------------ Cursor glow on glass cards */
  function initGlow() {
    if (!finePointer.matches || reduceMotion.matches) return;
    const cards = document.querySelectorAll('.hl.glass, .mode.glass, .card.glass, .step.glass, .sync.glass, .final-card.glass, .faq details.glass, .curve-card, .dash-card');
    cards.forEach((el) => {
      el.classList.add('glow');
      let raf = 0;
      let x = 0;
      let y = 0;
      const apply = () => {
        raf = 0;
        const r = el.getBoundingClientRect();
        el.style.setProperty('--px', `${(x - r.left).toFixed(0)}px`);
        el.style.setProperty('--py', `${(y - r.top).toFixed(0)}px`);
      };
      el.addEventListener('pointerenter', () => el.classList.add('glowing'));
      el.addEventListener('pointermove', (e) => {
        x = e.clientX;
        y = e.clientY;
        if (!raf) raf = requestAnimationFrame(apply);
      }, { passive: true });
      el.addEventListener('pointerleave', () => el.classList.remove('glowing'));
    });
  }

  /* ------------------------------------------------------------ Boot */
  const boot = () => {
    initReveal();
    initTilt();
    initCurve();
    initDemo();
    initDash();
    initDownload();
    initMagnetic();
    initGlow();
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
