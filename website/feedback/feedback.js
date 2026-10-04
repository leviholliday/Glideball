/* Glide: the "Send feedback" page. Sends what's typed (and any pictures, a
   piece at a time) to /api/feedback, the same way the Mac app does:

     POST /api/feedback                              the item -> id, upload token, piece size
     PUT  /api/feedback/upload?id&file&index&total   one piece of a picture
     POST /api/feedback/complete?id                  every piece is in (the developer hears of it then)

   No dependencies, no tracking. */
(() => {
  'use strict';

  // Not a secret: the Mac app sends the same. It keeps out what just wanders by.
  const KEY = 'TKsnHSb_TNX9SlHJtd9s59z3';
  const MAX_FILES = 4;
  const MAX_SIZE = 12e6;
  const TYPES = ['image/png', 'image/jpeg'];

  const $ = (id) => document.getElementById(id);
  const form = $('fb-form');
  const titleEl = $('fb-title');
  const emailEl = $('fb-email');
  const contactEl = $('fb-contact');
  const contactRow = $('fb-contact-row');
  const fileInput = $('fb-files');
  const drop = $('fb-drop');
  const thumbs = $('fb-thumbs');
  const filesNote = $('fb-files-note');
  const errorBox = $('fb-error');
  const errorText = $('fb-error-text');
  const submit = $('fb-submit');
  const submitText = $('fb-submit-text');
  const progress = $('fb-progress');
  const bar = $('fb-bar');
  const done = $('fb-done');
  const doneText = $('fb-done-text');

  /** The pictures picked: { file, name, url }. */
  let picked = [];
  /** An item already created whose pictures didn't all arrive: trying again
   * sends only what's missing, to the same item. */
  let pending = null;
  let busy = false;

  /* ------------------------------------------------------------ Contact */
  function syncContact() {
    const has = emailEl.value.trim() !== '';
    contactEl.disabled = !has;
    if (!has) contactEl.checked = false;
    contactRow.classList.toggle('off', !has);
  }
  emailEl.addEventListener('input', syncContact);
  syncContact();

  /* ------------------------------------------------------------ Pictures */
  /** A name the server takes: letters, digits, . _ - (up to 80), not
   * starting with a dot, and different from the others. */
  function safeName(original, type, taken) {
    const ext = type === 'image/png' ? '.png' : '.jpg';
    let stem = original.replace(/\.[^.]*$/, '').normalize('NFKD')
      .replace(/[^A-Za-z0-9._-]+/g, '-').replace(/\.{2,}/g, '.').replace(/^[^A-Za-z0-9]+/, '').replace(/[-.]+$/, '');
    if (!stem) stem = 'picture';
    stem = stem.slice(0, 70);
    let name = stem + ext;
    for (let n = 2; taken.has(name); n++) name = `${stem}-${n}${ext}`;
    return name;
  }

  const mb = (n) => (n >= 1e6 ? `${(n / 1e6).toFixed(1)} MB` : `${Math.max(1, Math.round(n / 1e3))} KB`);

  function note(text, bad) {
    filesNote.textContent = text || '';
    filesNote.classList.toggle('bad', !!bad);
  }

  function addFiles(list) {
    if (busy) return;
    const problems = [];
    for (const file of list) {
      if (picked.length >= MAX_FILES) { problems.push(`Only ${MAX_FILES} pictures can be sent.`); break; }
      if (!TYPES.includes(file.type)) { problems.push(`${file.name} isn't a PNG or JPEG.`); continue; }
      if (file.size > MAX_SIZE) { problems.push(`${file.name} is over 12 MB.`); continue; }
      if (!file.size) { problems.push(`${file.name} is empty.`); continue; }
      if (picked.some((p) => p.file.name === file.name && p.file.size === file.size && p.file.lastModified === file.lastModified)) continue;
      const name = safeName(file.name, file.type, new Set(picked.map((p) => p.name)));
      picked.push({ file, name, url: URL.createObjectURL(file) });
    }
    pending = null;  // a different set of pictures: a new item
    renderThumbs();
    note([...new Set(problems)].join(' '), problems.length > 0);
  }

  function removeFile(i) {
    if (busy) return;
    const [gone] = picked.splice(i, 1);
    if (gone) URL.revokeObjectURL(gone.url);
    pending = null;
    renderThumbs();
    note('');
  }

  function renderThumbs() {
    thumbs.textContent = '';
    picked.forEach((p, i) => {
      const li = document.createElement('li');
      li.className = 'fb-thumb';
      const img = document.createElement('img');
      img.src = p.url;
      img.alt = '';
      img.addEventListener('error', () => li.classList.add('noimg'));
      const cap = document.createElement('div');
      cap.className = 'fb-thumb-cap';
      const nm = document.createElement('span');
      nm.textContent = p.file.name;
      nm.title = p.file.name;
      const sz = document.createElement('span');
      sz.textContent = mb(p.file.size);
      cap.append(nm, sz);
      const x = document.createElement('button');
      x.type = 'button';
      x.className = 'fb-thumb-x';
      x.setAttribute('aria-label', `Remove ${p.file.name}`);
      x.innerHTML = '<svg class="icon" aria-hidden="true"><use href="#i-x"/></svg>';
      x.addEventListener('click', () => removeFile(i));
      li.append(img, cap, x);
      thumbs.append(li);
    });
    drop.classList.toggle('full', picked.length >= MAX_FILES);
  }

  fileInput.addEventListener('change', () => {
    addFiles(Array.from(fileInput.files || []));
    fileInput.value = '';
  });
  ['dragenter', 'dragover'].forEach((t) => drop.addEventListener(t, (e) => {
    e.preventDefault();
    drop.classList.add('over');
  }));
  ['dragleave', 'drop'].forEach((t) => drop.addEventListener(t, (e) => {
    e.preventDefault();
    drop.classList.remove('over');
  }));
  drop.addEventListener('drop', (e) => addFiles(Array.from(e.dataTransfer?.files || [])));
  // Pasting a screenshot anywhere on the page adds it too.
  document.addEventListener('paste', (e) => {
    const files = Array.from(e.clipboardData?.files || []).filter((f) => f.type.startsWith('image/'));
    if (files.length) { e.preventDefault(); addFiles(files); }
  });

  /* ------------------------------------------------------------ Sending */
  class SendError extends Error {
    constructor(message, retry) { super(message); this.retry = retry; }
  }

  async function call(url, opts, tries = 3) {
    for (let attempt = 1; ; attempt++) {
      let r;
      try {
        r = await fetch(url, { ...opts, credentials: 'same-origin', cache: 'no-store' });
      } catch {
        if (attempt < tries) { await wait(700 * attempt); continue; }
        throw new SendError("Couldn't reach the server. Check your connection and try again.", true);
      }
      let data = null;
      try { data = await r.json(); } catch { /* not JSON */ }
      if (r.ok) return data || {};
      if (r.status >= 500 && attempt < tries) { await wait(700 * attempt); continue; }
      throw new SendError(data?.error || `Something went wrong (${r.status}). Try again in a moment.`, r.status >= 500 || r.status === 429);
    }
  }
  const wait = (ms) => new Promise((res) => setTimeout(res, ms));

  function setProgress(fraction) {
    progress.hidden = false;
    bar.style.width = `${Math.round(Math.min(1, Math.max(0.03, fraction)) * 100)}%`;
  }

  function showError(text) {
    errorText.textContent = text;
    errorBox.hidden = false;
  }

  function setBusy(on, label) {
    busy = on;
    submit.disabled = on;
    submitText.textContent = label || 'Send feedback';
    form.setAttribute('aria-busy', on ? 'true' : 'false');
  }

  /** The item, or the one made already if its pictures are what's left. */
  async function create() {
    if (pending) return pending;
    const type = form.querySelector('input[name="type"]:checked')?.value || 'Bug';
    const email = emailEl.value.trim();
    const body = {
      title: titleEl.value.trim(),
      details: $('fb-details').value.trim(),
      tags: [type],
      priority: 'normal',
      name: $('fb-name').value.trim(),
      email,
      contactOK: !!email && contactEl.checked,
      platform: 'web',
      app: {},
      system: { userAgent: navigator.userAgent.slice(0, 400) },
      attachments: picked.map((p) => ({ name: p.name, type: p.file.type, size: p.file.size })),
    };
    // Creating isn't repeated on its own: a reply lost on the way would
    // otherwise make two of the same.
    const r = await call('/api/feedback', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-glide-key': KEY },
      body: JSON.stringify(body),
    }, 1);
    pending = { id: r.id, token: r.uploadToken, chunk: r.chunkSize || 3 * 1024 * 1024, sent: new Set() };
    return pending;
  }

  async function upload(item) {
    const total = picked.reduce((a, p) => a + p.file.size, 0);
    let sent = 0;
    for (const p of picked) {
      const pieces = Math.max(1, Math.ceil(p.file.size / item.chunk));
      for (let i = 0; i < pieces; i++) {
        const start = i * item.chunk;
        const end = Math.min(p.file.size, start + item.chunk);
        const key = `${p.name}/${i}`;
        if (!item.sent.has(key)) {
          const q = new URLSearchParams({ id: item.id, file: p.name, index: String(i), total: String(pieces) });
          await call(`/api/feedback/upload?${q}`, {
            method: 'PUT',
            headers: { 'content-type': 'application/octet-stream', 'x-glide-key': KEY, 'x-upload-token': item.token },
            body: p.file.slice(start, end),
          });
          item.sent.add(key);
        }
        sent += end - start;
        setProgress(0.05 + 0.9 * (sent / total));
      }
    }
    await call(`/api/feedback/complete?id=${encodeURIComponent(item.id)}`, {
      method: 'POST',
      headers: { 'x-glide-key': KEY, 'x-upload-token': item.token },
    });
  }

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (busy) return;
    errorBox.hidden = true;
    titleEl.removeAttribute('aria-invalid');
    emailEl.removeAttribute('aria-invalid');

    if (!titleEl.value.trim()) {
      titleEl.setAttribute('aria-invalid', 'true');
      showError('Give it a short title first.');
      titleEl.focus();
      return;
    }
    const email = emailEl.value.trim();
    if (email && !/^[^\s@?&#%/]+@[^\s@?&#%/]+\.[^\s@?&#%/]+$/.test(email)) {
      emailEl.setAttribute('aria-invalid', 'true');
      showError("That email address doesn't look right. It's optional, so you can leave it empty.");
      emailEl.focus();
      return;
    }

    // A bot filled in the field people never see: pretend it went.
    if ($('fb-website').value) { finish(); return; }

    setBusy(true, 'Sending…');
    setProgress(0.04);
    try {
      const item = await create();
      if (picked.length) {
        setBusy(true, 'Uploading pictures…');
        await upload(item);
      }
      setProgress(1);
      finish();
    } catch (err) {
      const msg = err instanceof SendError ? err.message : 'Something went wrong. Try again in a moment.';
      showError(pending
        ? `${msg} What you wrote has been saved; pressing Send again finishes the pictures.`
        : msg);
      progress.hidden = true;
      setBusy(false, pending ? 'Try again' : 'Send feedback');
    }
  });

  function finish() {
    doneText.textContent = contactEl.checked
      ? "It's on its way to the developer. If there's anything to follow up on, you'll hear back by email."
      : "It's on its way to the developer. Thanks for helping make Glide better.";
    setBusy(false);
    progress.hidden = true;
    form.hidden = true;
    done.hidden = false;
    done.focus();
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  $('fb-again').addEventListener('click', () => {
    form.reset();
    picked.forEach((p) => URL.revokeObjectURL(p.url));
    picked = [];
    pending = null;
    renderThumbs();
    note('');
    syncContact();
    errorBox.hidden = true;
    bar.style.width = '0';
    done.hidden = true;
    form.hidden = false;
    titleEl.focus();
  });
})();
