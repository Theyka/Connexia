import { api, ApiError } from "./api.js";
import { b64ToBytes, bytesToB64, decryptString, encryptString, importAesKey, randomBytes } from "./crypto.js";

const TABLES = ["hosts", "groups", "identities", "knownHosts", "snippets", "sessionLogs", "themes", "tunnels"];
const POLL_INTERVAL = 10000;
const MAX_CONFLICT_RETRIES = 3;

const listeners = new Set();
let syncKey = null;
let vaultKey = null;
let vaultKeyB64 = null;
let writeQueue = Promise.resolve();
let pendingWrites = 0;

export const state = {
  payload: null,
  revision: 0,
  updatedAt: null,
  blobBytes: 0,
  saving: false,
  error: null,
};

export function data() {
  return state.payload.data;
}

export function setting(key, fallback = null) {
  const value = state.payload?.data.settings[key];
  return value == null ? fallback : value;
}

export function onChange(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

function emit(reason) {
  for (const listener of listeners) {
    listener(reason);
  }
}

function emptyPayload() {
  const data = Object.fromEntries(TABLES.map((t) => [t, []]));
  data.settings = {};
  return { format: "connexia-sync", version: 1, modifiedAt: new Date().toISOString(), data };
}

function normalize(payload) {
  payload.data ??= {};
  for (const table of TABLES) {
    if (!Array.isArray(payload.data[table])) payload.data[table] = [];
  }
  if (!payload.data.settings || typeof payload.data.settings !== "object") {
    payload.data.settings = {};
  }
  return payload;
}

async function loadVaultKey() {
  const b64 = state.payload.data.settings.vaultMasterKey || null;
  if (b64 === vaultKeyB64) return;
  vaultKeyB64 = b64;
  vaultKey = null;
  if (b64) {
    try {
      vaultKey = await importAesKey(b64ToBytes(b64));
    } catch {
      vaultKey = null;
    }
  }
}

export async function unlock(rawKey) {
  syncKey = await importAesKey(rawKey);
  await refresh(true);
  setInterval(() => {
    if (pendingWrites === 0 && document.visibilityState === "visible") {
      refresh(false).catch(() => {});
    }
  }, POLL_INTERVAL);
}

export async function refresh(force) {
  const remote = await api.get("/api/sync");
  const revision = remote.revision || 0;
  if (!force && state.payload && revision === state.revision) {
    return false;
  }
  const payload = remote.blob ? JSON.parse(await decryptString(remote.blob, syncKey)) : emptyPayload();
  state.payload = normalize(payload);
  state.revision = revision;
  state.updatedAt = remote.updatedAt || null;
  state.blobBytes = remote.blob ? Math.floor((remote.blob.length * 3) / 4) : 0;
  await loadVaultKey();
  emit("remote");
  return true;
}

export function mutate(change) {
  const run = async () => {
    pendingWrites++;
    state.saving = true;
    state.error = null;
    emit("saving");
    try {
      for (let attempt = 0; ; attempt++) {
        const next = structuredClone(state.payload);
        await change(next.data);
        next.modifiedAt = new Date().toISOString();
        const blob = await encryptString(JSON.stringify(next), syncKey);
        try {
          const result = await api.post("/api/sync", { revision: state.revision, blob });
          state.payload = next;
          state.revision = result.revision;
          state.updatedAt = new Date().toISOString();
          state.blobBytes = Math.floor((blob.length * 3) / 4);
          await loadVaultKey();
          return;
        } catch (err) {
          if (err instanceof ApiError && err.status === 409 && attempt < MAX_CONFLICT_RETRIES) {
            await refresh(true);
            continue;
          }
          throw err;
        }
      }
    } catch (err) {
      state.error = err.message;
      throw err;
    } finally {
      pendingWrites--;
      state.saving = pendingWrites > 0;
      emit("local");
    }
  };
  const result = writeQueue.then(run, run);
  writeQueue = result.catch(() => {});
  return result;
}

export function upsert(rows, row, key = "id") {
  const existing = rows.find((r) => r[key] === row[key]);
  if (existing) Object.assign(existing, row);
  else rows.push(row);
  return existing || row;
}

export const vault = {
  get available() {
    return vaultKey != null;
  },

  async decrypt(ciphertext) {
    if (!vaultKey || !ciphertext) return null;
    try {
      return await decryptString(ciphertext, vaultKey);
    } catch {
      return null;
    }
  },

  async encrypt(plaintext, data) {
    if (!vaultKey) {
      const raw = randomBytes(32);
      data.settings.vaultMasterKey = bytesToB64(raw);
      vaultKeyB64 = data.settings.vaultMasterKey;
      vaultKey = await importAesKey(raw);
    }
    return encryptString(plaintext, vaultKey);
  },
};
