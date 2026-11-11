/* Glideball: site interactions. Vanilla JS, no dependencies, no tracking.
   Nothing here runs in a loop by itself: every animation starts from something
   you did (pointer, scroll, a press) and stops once things are still, and
   everything sleeps while it's off screen. */
(() => {
  'use strict';

  const root = document.documentElement;
  root.classList.add('js');

  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  const hasIO = 'IntersectionObserver' in window;
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

  /* ------------------------------------------------------------ The trackball (hero)
     The pointer moves the ball's inner light, scrolling the page turns the ring
     (its pink glow grows with scroll speed), and a corner pad lights amber while
     you hover or press it. With Reduce Motion only the pads answer. */
  function initTrackball() {
    const stage = document.querySelector('.tb-stage');
    if (!stage) return;

    stage.querySelectorAll('[data-pad]').forEach((pad) => {
      let timer = 0;
      const on = () => { clearTimeout(timer); pad.classList.add('lit'); };
      const off = () => pad.classList.remove('lit');
      pad.addEventListener('pointerenter', (e) => { if (e.pointerType === 'mouse') on(); });
      pad.addEventListener('pointerleave', off);
      pad.addEventListener('pointerdown', (e) => {
        on();
        if (e.pointerType !== 'mouse') timer = setTimeout(off, 280);
      });
    });

    let visible = !hasIO;
    watchVisibility(stage, (v) => { visible = v; }, '0px');

    // ---- light: follows the pointer (and a tap on touch screens)
    let lx = 0;
    let ly = 0;
    let lightQueued = false;
    let rest = 0;
    const applyLight = () => {
      lightQueued = false;
      stage.style.setProperty('--lx', lx.toFixed(3));
      stage.style.setProperty('--ly', ly.toFixed(3));
    };
    const aimAt = (x, y, reach) => {
      const r = stage.getBoundingClientRect();
      const cx = r.left + r.width / 2;
      const cy = r.top + r.height / 2;
      lx = clamp((x - cx) / reach, -1, 1);
      ly = clamp((y - cy) / reach, -1, 1);
      if (!lightQueued) { lightQueued = true; requestAnimationFrame(applyLight); }
    };
    window.addEventListener('pointermove', (e) => {
      if (!visible || reduceMotion.matches || e.pointerType !== 'mouse') return;
      stage.classList.add('live');
      aimAt(e.clientX, e.clientY, Math.max(window.innerWidth, window.innerHeight) * 0.45);
    }, { passive: true });
    stage.addEventListener('pointerdown', (e) => {
      if (reduceMotion.matches || e.pointerType === 'mouse') return;
      stage.classList.remove('live');
      aimAt(e.clientX, e.clientY, stage.clientWidth * 0.4);
      clearTimeout(rest);
      rest = setTimeout(() => aimAt(0, 0, Infinity), 1400);
    });
    document.documentElement.addEventListener('pointerleave', () => {
      if (reduceMotion.matches) return;
      stage.classList.remove('live');
      lx = 0; ly = 0;
      if (!lightQueued) { lightQueued = true; requestAnimationFrame(applyLight); }
    });

    // ---- ring: turns with the page; glow follows scroll speed, then fades and the loop stops
    let angle = 0;
    let lastY = window.scrollY;
    let lastT = performance.now();
    let target = 0;
    let glow = 0;
    let running = false;
    const frame = () => {
      glow += (target - glow) * (target > glow ? 0.45 : 0.1);
      target *= 0.82;
      stage.style.setProperty('--ring', `${angle.toFixed(2)}deg`);
      stage.style.setProperty('--glow', glow < 0.004 ? '0' : glow.toFixed(3));
      if (glow < 0.004 && target < 0.004) { running = false; glow = 0; target = 0; return; }
      requestAnimationFrame(frame);
    };
    window.addEventListener('scroll', () => {
      const y = window.scrollY;
      const t = performance.now();
      const dy = y - lastY;
      const dt = Math.max(t - lastT, 8);
      lastY = y;
      lastT = t;
      if (!visible || reduceMotion.matches) return;
      angle += dy * 0.14;
      target = Math.max(target, clamp((Math.abs(dy) / dt) * 1000 / 2400, 0, 1));
      if (!running) { running = true; requestAnimationFrame(frame); }
    }, { passive: true });
  }

  /* ------------------------------------------------------------ Sparkline (canvas) */
  class Spark {
    constructor(canvas, { windowMs = 3000, floor = 1000, color = '--ring' } = {}) {
      this.canvas = canvas;
      this.ctx = canvas.getContext('2d');
      this.windowMs = windowMs;
      this.floor = floor;
      this.scale = floor;
      this.colorVar = color;
      this.samples = []; // flat [t0, v0, t1, v1, ...]
      this.readColors();
      this.resize();
    }

    readColors() {
      const cs = getComputedStyle(this.canvas);
      this.c = cs.getPropertyValue(this.colorVar).trim() || '#ff5ca8';
      this.grid = cs.getPropertyValue('--line').trim() || 'rgba(255,255,255,.08)';
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
      fill.addColorStop(0, hexToRgba(this.c, 0.26));
      fill.addColorStop(1, hexToRgba(this.c, 0));
      ctx.fillStyle = fill;
      ctx.fill();

      // Line
      trace();
      ctx.strokeStyle = this.c;
      ctx.lineWidth = 1.75;
      ctx.lineJoin = 'round';
      ctx.lineCap = 'round';
      ctx.stroke();
    }
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

    // ---- flick meter: your best moments in this visit. Nothing is stored or sent.
    // A new best is a real event, so it gets the one small bounce (the badge); nothing else celebrates.
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
      // At either end of the list, let the page scroll instead of trapping the wheel.
      if ((e.deltaY < 0 && pos <= 0 && v <= 0) || (e.deltaY > 0 && pos >= maxPos && v >= 0)) return;
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
    // On touch screens the list only captures swipes after a tap arms it, so the page can still scroll.
    const coarse = window.matchMedia('(pointer: coarse)');
    let armed = false;
    let tapX = 0;
    let tapY = 0;
    const disarm = () => { armed = false; vp.classList.remove('armed'); };
    document.addEventListener('pointerdown', (e) => { if (armed && !vp.contains(e.target)) disarm(); });
    vp.addEventListener('blur', disarm);
    vp.addEventListener('pointerup', (e) => {
      if (coarse.matches && !armed && Math.hypot(e.clientX - tapX, e.clientY - tapY) < 10) {
        armed = true;
        vp.classList.add('armed');
      }
    });
    vp.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;
      tapX = e.clientX;
      tapY = e.clientY;
      if (coarse.matches && !armed) return;
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

  /* ------------------------------------------------------------ Copy buttons */
  function initCopy() {
    document.querySelectorAll('.copy-btn[data-copy]').forEach((btn) => {
      const label = btn.textContent;
      let timer = 0;
      btn.addEventListener('click', async () => {
        const text = btn.dataset.copy;
        let ok = false;
        try {
          await navigator.clipboard.writeText(text);
          ok = true;
        } catch (_) {
          const ta = document.createElement('textarea');
          ta.value = text;
          ta.setAttribute('readonly', '');
          ta.className = 'sr-only';
          document.body.append(ta);
          ta.select();
          try { ok = document.execCommand('copy'); } catch (__) { ok = false; }
          ta.remove();
        }
        btn.textContent = ok ? 'Copied' : 'Copy failed';
        btn.classList.toggle('copied', ok);
        clearTimeout(timer);
        timer = setTimeout(() => { btn.textContent = label; btn.classList.remove('copied'); }, 2000);
      });
    });
  }

  /* ------------------------------------------------------------ /download/
     On a Mac, start the download right away (the fallback link stays on the
     page). On a phone, Windows or Linux, explain instead of downloading. */
  function initDownloadPage() {
    const page = document.querySelector('[data-dl]');
    if (!page) return;
    const zip = page.getAttribute('data-dl');
    const ua = navigator.userAgent || '';
    const platform = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || '';
    const mobile = /iPhone|iPad|iPod|Android|Mobile/i.test(ua) || (navigator.userAgentData && navigator.userAgentData.mobile);
    // iPadOS Safari says "Macintosh" too; a Mac has no touch screen.
    const iPad = /Macintosh/.test(ua) && navigator.maxTouchPoints > 1;
    const mac = (/Mac/i.test(platform) || /Macintosh|Mac OS X/.test(ua)) && !mobile && !iPad;
    const h1 = document.querySelector('.pg-hero h1');
    if (!mac) {
      document.body.classList.add('not-mac');
      if (h1) h1.textContent = 'Glideball is a Mac app';
      return;
    }
    document.body.classList.add('is-mac');
    if (h1) h1.textContent = 'Your download is starting';
    // A moment first, so the page is on screen before the browser's download UI takes over.
    setTimeout(() => { window.location.href = zip; }, 450);
  }

  /* ------------------------------------------------------------ Boot */
  const boot = () => {
    initTrackball();
    initDemo();
    initCopy();
    initDownloadPage();
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();

/* Download counter: the site only gets a number once there are 200+ downloads. */
(() => {
  const el = document.querySelector("[data-downloads]");
  if (!el || !window.fetch) return;
  fetch("/api/downloads")
    .then((r) => (r.ok ? r.json() : null))
    .then((d) => {
      if (!d || typeof d.downloads !== "number") return;
      el.querySelector("[data-downloads-n]").textContent = d.downloads.toLocaleString();
      el.hidden = false;
    })
    .catch(() => {});
})();
