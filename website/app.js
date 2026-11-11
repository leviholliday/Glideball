/* Glideball: shared site interactions. Vanilla JS, no dependencies, no tracking.
   Nothing here runs by itself: each effect starts from something you did (the
   pointer, a click, scrolling a block into view) and stops right after.
   The home page's toys live in home.js. */
(() => {
  'use strict';

  const root = document.documentElement;
  root.classList.add('js');

  const hover = window.matchMedia('(hover: hover)');
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

  /* ------------------------------------------------------------ Rise in once
     Blocks marked .reveal rise in the first time they come into view. Blocks that
     arrive together are staggered a little, then the observer forgets them. */
  function initReveal() {
    const els = document.querySelectorAll('.reveal');
    if (!els.length) return;
    // ?demo=… (screenshot states) shows everything at once.
    if (!('IntersectionObserver' in window) || /[?&]demo=/.test(location.search)) { els.forEach((el) => el.classList.add('in')); return; }
    const io = new IntersectionObserver((entries) => {
      let n = 0;
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        const el = entry.target;
        el.style.setProperty('--d', String(Math.min(n, 5) * 70));
        n += 1;
        el.classList.add('in');
        io.unobserve(el);
        // Afterwards the block keeps no animation, so its own hover effects work.
        el.addEventListener('animationend', () => el.style.removeProperty('--d'), { once: true });
      });
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
    els.forEach((el) => io.observe(el));
  }

  /* ------------------------------------------------------------ Light that follows the pointer
     .card.lit: a soft spotlight on the face and edge, only while the pointer is over it.
     [data-tilt]: leans a few degrees toward the pointer, and settles back when it leaves. */
  function initPointerLight() {
    if (!hover.matches) return;
    document.querySelectorAll('.card.lit').forEach((card) => {
      let queued = false;
      let x = 0;
      let y = 0;
      const apply = () => {
        queued = false;
        card.style.setProperty('--mx', `${x}px`);
        card.style.setProperty('--my', `${y}px`);
      };
      card.addEventListener('pointermove', (e) => {
        if (e.pointerType !== 'mouse') return;
        const r = card.getBoundingClientRect();
        x = Math.round(e.clientX - r.left);
        y = Math.round(e.clientY - r.top);
        card.classList.add('hot');
        if (!queued) { queued = true; requestAnimationFrame(apply); }
      });
      card.addEventListener('pointerleave', () => card.classList.remove('hot'));
    });

    if (reduceMotion.matches) return;
    document.querySelectorAll('[data-tilt]').forEach((el) => {
      let queued = false;
      let tx = 0;
      let ty = 0;
      const apply = () => {
        queued = false;
        el.style.setProperty('--tx', `${tx.toFixed(2)}deg`);
        el.style.setProperty('--ty', `${ty.toFixed(2)}deg`);
      };
      el.addEventListener('pointermove', (e) => {
        if (e.pointerType !== 'mouse') return;
        const r = el.getBoundingClientRect();
        tx = ((e.clientX - r.left) / r.width - 0.5) * 5;
        ty = -((e.clientY - r.top) / r.height - 0.5) * 4;
        el.classList.add('tilting');
        if (!queued) { queued = true; requestAnimationFrame(apply); }
      });
      el.addEventListener('pointerleave', () => {
        el.classList.remove('tilting');
        tx = 0; ty = 0;
        if (!queued) { queued = true; requestAnimationFrame(apply); }
      });
    });
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

  const boot = () => {
    initReveal();
    initPointerLight();
    initCopy();
    initDownloadPage();
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();

/* Download counter: the site only gets a number once there are 200+ downloads. */
(() => {
  const el = document.querySelector('[data-downloads]');
  if (!el || !window.fetch) return;
  fetch('/api/downloads')
    .then((r) => (r.ok ? r.json() : null))
    .then((d) => {
      if (!d || typeof d.downloads !== 'number') return;
      el.querySelector('[data-downloads-n]').textContent = d.downloads.toLocaleString();
      el.hidden = false;
    })
    .catch(() => {});
})();
