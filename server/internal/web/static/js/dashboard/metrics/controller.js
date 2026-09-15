import * as store from "../store.js";
import { autoAcceptHostKeys, checkHostKey, openClient, resolveAuth, trustHostKey } from "../ssh/client.js";
import { collectSample, hottestTemp, listServiceUnits, readCrontab, runServiceAction, writeCrontab } from "./collect.js";
import * as history from "./history.js";

const LIVE_MS = 5000;
const BACKGROUND_MS = 10000;
const IDLE = Object.freeze({ pollState: "idle", error: null, last: null, lastUpdated: null });
const NO_POLICIES = Object.freeze({ loading: false, error: null, unsupported: false, units: [], crontab: "" });

export function watchlistOf(settings) {
  try {
    const list = JSON.parse(settings?.metricsWatchlist || "[]");
    return Array.isArray(list) ? list.filter((id) => typeof id === "string") : [];
  } catch {
    return [];
  }
}

let instance = null;

export function metricsController(app) {
  instance ??= createController(app);
  return instance;
}

function createController(app) {
  const states = new Map();
  const conns = new Map();
  const services = new Map();
  const crons = new Map();
  const polling = new Map();
  const cardsPending = new Set();
  const needsCredentials = new Set();
  const typed = new Map();
  const signatures = new Map();
  const listeners = new Set();
  let selectedId = null;
  let started = false;
  let known = [];
  let emitQueued = false;

  const emit = () => {
    if (emitQueued) return;
    emitQueued = true;
    queueMicrotask(() => {
      emitQueued = false;
      for (const listener of listeners) listener();
    });
  };

  const stateOf = (id) => states.get(id) ?? IDLE;
  const servicesOf = (id) => services.get(id) ?? NO_POLICIES;
  const cronOf = (id) => crons.get(id) ?? NO_POLICIES;
  const setState = (id, patch) => {
    states.set(id, { ...stateOf(id), ...patch });
    emit();
  };
  const fail = (id, error) => setState(id, { pollState: "error", error });
  const watchlist = () => watchlistOf(store.data().settings);
  const findHost = (id) => store.data().hosts.find((host) => host.id === id);

  function connFor(id) {
    let conn = conns.get(id);
    if (!conn) {
      conn = { handle: null, prevCpu: null, prevRxCum: null, prevTxCum: null, prevTs: null, username: "", password: null, failures: 0, retryAt: 0 };
      conns.set(id, conn);
    }
    return conn;
  }

  function closeConn(conn) {
    const handle = conn.handle;
    conn.handle = null;
    handle?.close();
  }

  function drop(id) {
    const conn = conns.get(id);
    if (conn) closeConn(conn);
    for (const map of [conns, states, services, crons, typed, signatures]) map.delete(id);
    cardsPending.delete(id);
    needsCredentials.delete(id);
  }

  function signature(host) {
    const group = host.groupId ? store.data().groups.find((g) => g.id === host.groupId) : null;
    return JSON.stringify([host.address, host.port, host.username, host.authType, host.encryptedPassword, host.keyId, group?.username, group?.authType, group?.encryptedPassword, group?.keyId]);
  }

  function sync() {
    const list = watchlist();
    for (const id of [...new Set([...conns.keys(), ...states.keys()])]) {
      if (!list.includes(id)) drop(id);
    }
    for (const id of list) {
      const host = findHost(id);
      if (!host) continue;
      const next = signature(host);
      const previous = signatures.get(id);
      signatures.set(id, next);
      if (previous != null && previous !== next) {
        needsCredentials.delete(id);
        typed.delete(id);
        const conn = conns.get(id);
        if (conn) {
          closeConn(conn);
          conn.failures = 0;
          conn.retryAt = 0;
        }
        poll(id, true);
      }
    }
    const added = list.filter((id) => !known.includes(id));
    known = list;
    if (!list.includes(selectedId)) {
      selectedId = list[0] ?? null;
      if (selectedId) cardsPending.add(selectedId);
    }
    for (const id of added) poll(id);
    emit();
  }

  function start() {
    if (started) return;
    started = true;
    setInterval(() => {
      if (selectedId) poll(selectedId);
    }, LIVE_MS);
    setInterval(() => {
      for (const id of watchlist()) {
        if (id !== selectedId) poll(id);
      }
    }, BACKGROUND_MS);
    store.onChange(sync);
    sync();
  }

  function poll(id, force = false) {
    const running = polling.get(id);
    if (running) return running;
    const conn = conns.get(id);
    if (!force && conn && !conn.handle && conn.retryAt > Date.now()) return Promise.resolve();
    const promise = doPoll(id).finally(() => {
      polling.delete(id);
      emit();
    });
    polling.set(id, promise);
    return promise;
  }

  async function connect(conn, id, host, auth) {
    const address = host.address;
    const port = parseInt(host.port, 10) || 22;
    let handle = null;
    handle = await openClient({
      address,
      port,
      auth,
      verifyHostKey: async (wireType, fingerprint) => {
        const check = checkHostKey(address, port, wireType, fingerprint);
        if (check.status === "trusted") return true;
        if (check.status === "changed") return check.message;
        if (autoAcceptHostKeys()) {
          await trustHostKey(app, address, port, check.keyType, fingerprint);
          return true;
        }
        return "Host key not verified yet — connect once via a Terminal first";
      },
      onClose: () => {
        if (handle && conn.handle === handle) conn.handle = null;
      },
    });
    if (!watchlist().includes(id) || conns.get(id) !== conn) {
      handle.close();
      throw new Error("No longer tracked");
    }
    conn.handle = handle;
    conn.prevCpu = null;
  }

  function connectFailed(conn, id, err) {
    const message = err?.message || String(err);
    if (message.startsWith("Authentication failed") || message === "Authentication cancelled.") {
      needsCredentials.add(id);
    }
    conn.failures++;
    conn.retryAt = Date.now() + Math.min(60000, 5000 * 2 ** conn.failures);
    fail(id, message.startsWith("Authentication failed") ? "Authentication failed" : message);
  }

  async function doPoll(id, retried = false) {
    const host = findHost(id);
    if (!host || !watchlist().includes(id) || needsCredentials.has(id)) return;
    if (app.account.webSSH === false) {
      fail(id, "Web SSH is turned off on this server. An admin can turn it on in the admin page.");
      return;
    }
    if (stateOf(id).pollState !== "ok") setState(id, { pollState: "connecting" });

    const conn = connFor(id);
    if (!conn.handle) {
      let auth = await resolveAuth(host);
      const entered = typed.get(id);
      if (auth.missing) {
        if (!entered) {
          if (!auth.fatal) needsCredentials.add(id);
          fail(id, auth.missing);
          return;
        }
        auth = { username: entered.username, password: entered.password, authType: "password" };
      }
      conn.username = auth.username;
      conn.password = auth.password;
      try {
        await connect(conn, id, host, auth);
      } catch (err) {
        if (conns.get(id) === conn) connectFailed(conn, id, err);
        return;
      }
    }

    let sample;
    try {
      sample = await collectSample(conn.handle);
    } catch (err) {
      closeConn(conn);
      if (!retried && err?.message !== "Timed out") return doPoll(id, true);
      fail(id, err?.message === "Timed out" ? "Timed out" : "Lost connection");
      return;
    }
    if (conns.get(id) !== conn) return;

    conn.failures = 0;
    conn.retryAt = 0;
    const finished = finalizeRates(conn, sample);
    setState(id, { pollState: "ok", error: null, last: finished, lastUpdated: finished.ts });

    const gaveUp = (policy) => policy && !policy.loading && policy.error === "Host is offline";
    if (cardsPending.delete(id) || gaveUp(services.get(id)) || gaveUp(crons.get(id))) {
      loadServices(id);
      loadCron(id);
    }
    history.add({
      hostId: id,
      ts: finished.ts,
      cpuPct: finished.cpuPct,
      memPct: finished.memPct,
      diskPct: (finished.disks.find((disk) => disk.mount === "/") ?? finished.disks[0])?.pct ?? null,
      load1: finished.load1,
      netRx: finished.netRxRate,
      netTx: finished.netTxRate,
      temp: hottestTemp(finished)?.celsius ?? null,
    });
  }

  function finalizeRates(conn, s) {
    let cpuPct = null;
    if (conn.prevCpu && s.cpuCounters) {
      const dTotal = s.cpuCounters.total - conn.prevCpu.total;
      const dIdle = s.cpuCounters.idle - conn.prevCpu.idle;
      if (dTotal > 0 && dIdle >= 0) cpuPct = Math.min(100, Math.max(0, (1 - dIdle / dTotal) * 100));
    }
    if (s.cpuCounters) conn.prevCpu = s.cpuCounters;

    let rxCum = 0;
    let txCum = 0;
    for (const iface of s.ifaces) {
      rxCum += iface.rxBytes;
      txCum += iface.txBytes;
    }
    let netRxRate = 0;
    let netTxRate = 0;
    if (conn.prevRxCum != null && conn.prevTs != null && rxCum >= conn.prevRxCum) {
      const dt = (s.ts - conn.prevTs) / 1000;
      if (dt > 0) {
        netRxRate = Math.max(0, (rxCum - conn.prevRxCum) / dt);
        netTxRate = Math.max(0, (txCum - conn.prevTxCum) / dt);
      }
    }
    conn.prevRxCum = rxCum;
    conn.prevTxCum = txCum;
    conn.prevTs = s.ts;
    return { ...s, cpuPct, netRxRate, netTxRate, netRxCum: rxCum, netTxCum: txCum };
  }

  async function withHandle(id) {
    if (!conns.get(id)?.handle) await poll(id, true);
    return conns.get(id)?.handle ?? null;
  }

  async function loadServices(id) {
    const previous = servicesOf(id);
    services.set(id, { ...NO_POLICIES, loading: true, units: previous.units, unsupported: previous.unsupported });
    emit();
    const handle = await withHandle(id);
    if (!handle) {
      services.set(id, { ...NO_POLICIES, error: "Host is offline" });
      emit();
      return;
    }
    try {
      const units = await listServiceUnits(handle);
      services.set(id, { ...NO_POLICIES, units, unsupported: units.length === 0 });
    } catch (err) {
      services.set(id, { ...NO_POLICIES, error: err.message });
    }
    emit();
  }

  async function serviceAction(id, unit, action) {
    const conn = conns.get(id);
    if (!conn?.handle) return "Host is offline";
    services.set(id, { ...servicesOf(id), loading: true });
    emit();
    let error = null;
    try {
      error = await runServiceAction(conn.handle, unit, action, conn.username === "root" ? null : conn.password);
    } catch (err) {
      error = err.message;
    }
    await loadServices(id);
    return error;
  }

  async function loadCron(id) {
    crons.set(id, { ...NO_POLICIES, loading: true, crontab: cronOf(id).crontab });
    emit();
    const handle = await withHandle(id);
    if (!handle) {
      crons.set(id, { ...NO_POLICIES, error: "Host is offline" });
      emit();
      return;
    }
    try {
      crons.set(id, { ...NO_POLICIES, crontab: await readCrontab(handle) });
    } catch (err) {
      crons.set(id, { ...NO_POLICIES, error: err.message });
    }
    emit();
  }

  async function writeCron(id, body) {
    const handle = conns.get(id)?.handle;
    if (!handle) return "Host is offline";
    crons.set(id, { ...cronOf(id), loading: true });
    emit();
    try {
      const error = await writeCrontab(handle, body);
      crons.set(id, { ...cronOf(id), loading: false, crontab: error == null ? body : cronOf(id).crontab });
      emit();
      return error;
    } catch (err) {
      crons.set(id, { ...cronOf(id), loading: false });
      emit();
      return err.message;
    }
  }

  return {
    start,
    onChange(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    get selectedId() {
      return selectedId;
    },
    stateOf,
    servicesOf,
    cronOf,
    cardsPending: (id) => cardsPending.has(id),
    needsCredentials: (id) => needsCredentials.has(id),
    select(id) {
      selectedId = id;
      cardsPending.add(id);
      emit();
      poll(id, true);
    },
    refresh: (id) => poll(id, true),
    provideCredentials(id, username, password) {
      typed.set(id, { username, password });
      needsCredentials.delete(id);
      const conn = conns.get(id);
      if (conn) {
        closeConn(conn);
        conn.failures = 0;
        conn.retryAt = 0;
      }
      cardsPending.add(id);
      emit();
      poll(id, true);
    },
    loadServices,
    serviceAction,
    loadCron,
    writeCron,
    history: (id, since) => history.load(id, since),
    hasConnections: () => [...conns.values()].some((conn) => conn.handle),
  };
}
