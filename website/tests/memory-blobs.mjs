// An in-memory stand-in for a @netlify/blobs store, for the functions' tests.
// It answers the calls the functions make the way the real library does,
// including conditional writes ({ onlyIfMatch: etag } / { onlyIfNew: true }
// give { modified: false } when the condition fails). Every call yields to
// the event loop first, so requests sent at once really do interleave.
//
//   const store = createMemoryStore();
//   store.stats()          // { reads, writes, deletes, lists } since creation / clearStats()
//   store.entries()        // [{ key, etag, bytes }], sorted
//   store.peek(key)        // the text, without counting a read
//   store.setPageSize(n)   // keys per page of list({ paginate: true }); default 1000

const te = new TextEncoder();
const td = new TextDecoder();

function shape(bytes, type) {
  switch (type) {
    case undefined:
    case "text": return td.decode(bytes);
    case "json": return JSON.parse(td.decode(bytes));
    case "arrayBuffer": return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    default: throw new Error(`Unsupported type "${type}" in the memory store.`);
  }
}

function toBytes(data) {
  if (typeof data === "string") return te.encode(data);
  if (data instanceof Uint8Array) return Uint8Array.from(data);
  if (data instanceof ArrayBuffer) return new Uint8Array(data.slice(0));
  throw new Error("A blob's data must be a string, an ArrayBuffer or a Uint8Array.");
}

function validateKey(key) {
  if (typeof key !== "string" || key === "") throw new Error("Blob key must not be empty.");
  if (key.startsWith("/")) throw new Error("Blob key must not start with forward slash (/).");
  if (te.encode(key).length > 600) throw new Error("Blob key must be at most 600 bytes of UTF-8.");
}

export function createMemoryStore() {
  const map = new Map();   // key -> { bytes, etag }
  let counter = 0;
  let pageSize = 1000;
  let counts = { reads: 0, writes: 0, deletes: 0, lists: 0 };
  const tick = () => Promise.resolve();

  async function write(key, data, options = {}, json = false) {
    validateKey(key);
    if ("onlyIfMatch" in options && "onlyIfNew" in options) throw new Error("onlyIfMatch and onlyIfNew are mutually exclusive.");
    const bytes = toBytes(json ? JSON.stringify(data) : data);
    await tick();
    const cur = map.get(key);
    if (options.onlyIfMatch && (!cur || cur.etag !== options.onlyIfMatch)) return { modified: false };
    if (options.onlyIfNew && cur) return { modified: false };
    const etag = `"m${++counter}"`;
    map.set(key, { bytes, etag });
    counts.writes++;
    return { modified: true, etag };
  }

  return {
    async get(key, options = {}) {
      validateKey(key);
      await tick();
      counts.reads++;
      const e = map.get(key);
      return e ? shape(e.bytes, options.type) : null;
    },
    async getWithMetadata(key, options = {}) {
      validateKey(key);
      await tick();
      counts.reads++;
      const e = map.get(key);
      return e ? { data: shape(e.bytes, options.type), etag: e.etag, metadata: {} } : null;
    },
    set: (key, data, options) => write(key, data, options ?? {}, false),
    setJSON: (key, data, options) => write(key, data, options ?? {}, true),
    async delete(key) {
      validateKey(key);
      await tick();
      counts.deletes++;
      map.delete(key);
    },
    // Without paginate: every blob in one reply. With it: an async iterable of
    // pages, as the real library gives.
    list(options = {}) {
      const all = async () => {
        await tick();
        counts.lists++;
        const keys = [...map.keys()].filter((k) => !options.prefix || k.startsWith(options.prefix)).sort();
        return keys.map((key) => ({ key, etag: map.get(key).etag }));
      };
      if (!options.paginate) return all().then((blobs) => ({ blobs, directories: [] }));
      return (async function* () {
        const blobs = await all();
        for (let i = 0; i < Math.max(blobs.length, 1); i += pageSize) yield { blobs: blobs.slice(i, i + pageSize), directories: [] };
      })();
    },

    // ---- tests only ----
    stats: () => ({ ...counts }),
    setPageSize(n) { pageSize = n; },
    clearStats() { counts = { reads: 0, writes: 0, deletes: 0, lists: 0 }; },
    entries() { return [...map].sort(([a], [b]) => (a < b ? -1 : 1)).map(([key, v]) => ({ key, etag: v.etag, bytes: v.bytes.length })); },
    keys() { return [...map.keys()].sort(); },
    peek(key) { const e = map.get(key); return e ? td.decode(e.bytes) : null; },
    poke(key, data) { map.set(key, { bytes: toBytes(typeof data === "string" ? data : JSON.stringify(data)), etag: `"m${++counter}"` }); },
    clear() { map.clear(); },
  };
}
