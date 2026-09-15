const DB_NAME = "connexia-metrics";
const STORE = "samples";
const KEEP_MS = 8 * 24 * 60 * 60 * 1000;
const PRUNE_EVERY_MS = 60 * 60 * 1000;

const memory = [];
let opening = null;
let lastPrune = 0;

function open() {
  opening ??= new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, 1);
    request.onupgradeneeded = () => {
      const objects = request.result.createObjectStore(STORE, { autoIncrement: true });
      objects.createIndex("host_ts", ["hostId", "ts"]);
      objects.createIndex("ts", "ts");
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  }).catch(() => null);
  return opening;
}

function prune(db) {
  const cutoff = Date.now() - KEEP_MS;
  lastPrune = Date.now();
  if (!db) {
    while (memory.length && memory[0].ts < cutoff) memory.shift();
    return;
  }
  try {
    const request = db.transaction(STORE, "readwrite").objectStore(STORE).index("ts").openCursor(IDBKeyRange.upperBound(cutoff));
    request.onsuccess = () => {
      const cursor = request.result;
      if (!cursor) return;
      cursor.delete();
      cursor.continue();
    };
  } catch {
    return;
  }
}

export async function add(row) {
  const db = await open();
  if (Date.now() - lastPrune > PRUNE_EVERY_MS) prune(db);
  if (!db) {
    memory.push(row);
    return;
  }
  try {
    db.transaction(STORE, "readwrite").objectStore(STORE).add(row);
  } catch {
    memory.push(row);
  }
}

export async function load(hostId, since, limit = 6000) {
  const db = await open();
  const fromMemory = () => memory.filter((row) => row.hostId === hostId && row.ts >= since).slice(-limit);
  if (!db) return fromMemory();
  return new Promise((resolve) => {
    const rows = [];
    const done = () => resolve([...rows.reverse(), ...fromMemory()]);
    try {
      const range = IDBKeyRange.bound([hostId, since], [hostId, Infinity]);
      const request = db.transaction(STORE).objectStore(STORE).index("host_ts").openCursor(range, "prev");
      request.onsuccess = () => {
        const cursor = request.result;
        if (cursor && rows.length < limit) {
          rows.push(cursor.value);
          cursor.continue();
        } else {
          done();
        }
      };
      request.onerror = done;
    } catch {
      done();
    }
  });
}
