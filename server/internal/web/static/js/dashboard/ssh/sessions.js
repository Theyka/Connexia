import { sessionToken } from "../api.js";
import { h, uuid } from "../dom.js";
import * as store from "../store.js";
import { TERMINAL_THEMES } from "../terminal-themes.js";
import { snackbar } from "../ui.js";
import { askAnswers, autoAcceptHostKeys, checkHostKey, detectOs, promptCredentials, relayUrl, resolveAuth, trustHostKey } from "./client.js";
import { loadSSH, loadTerminal } from "./runtime.js";

const RETRY_DELAY = 5000;
const MIN_FONT = 8;
const MAX_FONT = 28;

export const sessions = [];
export const state = { activeId: null, visible: false, snippetsOpen: false };

const listeners = new Set();
const waiting = [];
let connecting = 0;
let counter = 0;
let app = null;
let zoomSaveTimer = 0;
let fontSizeOverride = null;

export function init(appRef) {
  app = appRef;
  store.onChange(applySettings);
}

export function onChange(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

function emit() {
  for (const listener of listeners) listener();
}

export function activeSession() {
  return sessions.find((s) => s.id === state.activeId) || null;
}

export function statusColor(status) {
  if (status === "connected") return "var(--success)";
  if (status === "connecting" || status === "verifying") return "var(--warning)";
  return "var(--danger)";
}

export function setActive(id) {
  state.activeId = id;
  const session = activeSession();
  if (session) session.hasUnseenOutput = false;
  emit();
  focusActive();
}

export function setVisible(visible) {
  state.visible = visible;
  if (visible) {
    const session = activeSession();
    if (session) session.hasUnseenOutput = false;
    focusActive();
  }
  emit();
}

export function toggleSnippets() {
  state.snippetsOpen = !state.snippetsOpen;
  emit();
}

function focusActive() {
  requestAnimationFrame(() => {
    const session = activeSession();
    if (state.visible && session?.term) {
      fitSession(session);
      session.term.focus();
    }
  });
}

function fontSize() {
  if (fontSizeOverride != null) return fontSizeOverride;
  return parseFloat(store.setting("fontSize", "14")) || 14;
}

function xtermTheme() {
  const name = store.setting("terminalTheme", "Connexia");
  const t = TERMINAL_THEMES.find((theme) => theme.name === name) || TERMINAL_THEMES[0];
  return {
    background: t.background,
    foreground: t.foreground,
    cursor: t.cursor,
    cursorAccent: t.background,
    selectionBackground: t.selection,
    black: t.black,
    red: t.red,
    green: t.green,
    yellow: t.yellow,
    blue: t.blue,
    magenta: t.magenta,
    cyan: t.cyan,
    white: t.white,
    brightBlack: t.brightBlack,
    brightRed: t.brightRed,
    brightGreen: t.brightGreen,
    brightYellow: t.brightYellow,
    brightBlue: t.brightBlue,
    brightMagenta: t.brightMagenta,
    brightCyan: t.brightCyan,
    brightWhite: t.brightWhite,
  };
}

function applySettings() {
  const theme = xtermTheme();
  const size = fontSize();
  const scrollback = parseInt(store.setting("scrollback", "5000"), 10) || 5000;
  for (const session of sessions) {
    if (!session.term) continue;
    const options = session.term.options;
    if (options.theme.background !== theme.background || options.theme.foreground !== theme.foreground) options.theme = theme;
    if (options.fontSize !== size) options.fontSize = size;
    if (options.scrollback !== scrollback) options.scrollback = scrollback;
    session.el.style.setProperty("--term-bg", theme.background);
    fitSession(session);
  }
}

export function currentFontSize() {
  return fontSize();
}

export function zoom(delta) {
  const next = delta === 0 ? 14 : Math.min(MAX_FONT, Math.max(MIN_FONT, fontSize() + delta));
  fontSizeOverride = next;
  applySettings();
  emit();
  clearTimeout(zoomSaveTimer);
  zoomSaveTimer = setTimeout(() => {
    const value = Number.isInteger(next) ? next.toFixed(1) : String(next);
    app.save((d) => {
      d.settings.fontSize = value;
    }).then(() => {
      fontSizeOverride = null;
    });
  }, 800);
}

function fitSession(session) {
  if (!session.term || !session.el.isConnected || session.el.offsetParent === null) return;
  try {
    session.fit.fit();
  } catch {
    return;
  }
}

async function createTerminal(session) {
  const { Terminal, FitAddon } = await loadTerminal();
  const theme = xtermTheme();
  const term = new Terminal({
    fontFamily: '"JetBrains Mono", ui-monospace, monospace',
    fontSize: fontSize(),
    lineHeight: 1.15,
    scrollback: parseInt(store.setting("scrollback", "5000"), 10) || 5000,
    cursorBlink: false,
    theme,
  });
  const fit = new FitAddon();
  term.loadAddon(fit);
  session.el.style.setProperty("--term-bg", theme.background);
  term.open(session.el);
  session.term = term;
  session.fit = fit;

  term.onData((data) => session.ssh?.write(data));
  term.onBinary((data) => session.ssh?.write(Uint8Array.from(data, (c) => c.charCodeAt(0))));
  term.onResize(({ cols, rows }) => {
    clearTimeout(session.resizeTimer);
    session.resizeTimer = setTimeout(() => session.ssh?.resize(cols, rows), 60);
  });
  term.attachCustomKeyEventHandler((event) => handleKey(session, event));
  new ResizeObserver(() => fitSession(session)).observe(session.el);
  fitSession(session);
}

function handleKey(session, event) {
  if (event.type !== "keydown") return true;
  const ctrlShift = event.ctrlKey && event.shiftKey && !event.altKey && !event.metaKey;
  if (ctrlShift && event.code === "KeyC") {
    const text = session.term.getSelection();
    if (text) navigator.clipboard.writeText(text).catch(() => {});
    return false;
  }
  if (ctrlShift && event.code === "KeyV") {
    navigator.clipboard.readText().then((text) => session.term.paste(normalizePaste(text)), () => {});
    return false;
  }
  if ((event.ctrlKey || event.metaKey) && !event.shiftKey && !event.altKey) {
    if (event.key === "=" || event.key === "+") {
      event.preventDefault();
      zoom(1);
      return false;
    }
    if (event.key === "-") {
      event.preventDefault();
      zoom(-1);
      return false;
    }
    if (event.key === "0") {
      event.preventDefault();
      zoom(0);
      return false;
    }
  }
  return true;
}

export function normalizePaste(text) {
  return text.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
}

function acquireSlot() {
  const limit = Math.min(100, Math.max(1, parseInt(store.setting("maxConcurrentConnects", "4"), 10) || 4));
  if (connecting < limit) {
    connecting++;
    return Promise.resolve();
  }
  return new Promise((resolve) => waiting.push(resolve));
}

function releaseSlot() {
  const next = waiting.shift();
  if (next) next();
  else connecting--;
}

async function connect(session) {
  if (session.closed) return;
  clearRetry(session);
  const generation = ++session.generation;
  session.status = "connecting";
  session.error = null;
  emit();

  await acquireSlot();
  try {
    if (session.closed || generation !== session.generation) return;
    if (!session.term) await createTerminal(session);
    const ssh = await loadSSH();
    const { request } = session;
    const handle = await ssh.connect({
      url: relayUrl(request.address, request.port),
      protocols: ["connexia-relay", "token." + sessionToken()],
      username: request.username,
      password: request.password || "",
      privateKey: request.privateKey || "",
      passphrase: request.passphrase || "",
      cols: session.term.cols,
      rows: session.term.rows,
      verifyHostKey: (type, fingerprint) => verifyHostKey(session, type, fingerprint),
      prompt: (name, instruction, questions, echos) => askAnswers(session.label, name, instruction, questions, echos),
      onData: (bytes) => {
        if (session.closed || generation !== session.generation) return;
        session.term.write(bytes);
        markUnseen(session);
      },
      onClose: (reason) => handleClosed(session, generation, reason),
    });

    if (session.closed || generation !== session.generation) {
      handle.close();
      return;
    }
    session.ssh = handle;
    if (session.closedGeneration === generation) {
      session.ssh = null;
      session.status = "disconnected";
      emit();
      scheduleRetry(session);
      return;
    }
    session.status = "connected";
    session.autoRetry = false;
    emit();
    handle.resize(session.term.cols, session.term.rows);
    logConnect(session);
    detectOs(app, handle, request).then((os) => {
      if (!os || session.closed) return;
      session.os = os;
      emit();
    });
    if (state.visible && state.activeId === session.id) session.term.focus();
  } catch (err) {
    if (session.closed || generation !== session.generation) return;
    session.status = "error";
    session.error = err?.message || String(err);
    emit();
    if (session.autoRetry) scheduleRetry(session);
  } finally {
    releaseSlot();
  }
}

function handleClosed(session, generation, reason) {
  if (session.closed || generation !== session.generation) return;
  session.closedGeneration = generation;
  if (!session.ssh) return;
  session.ssh = null;
  session.status = "disconnected";
  session.error = reason || null;
  logDisconnect(session);
  emit();
  scheduleRetry(session);
}

function clearRetry(session) {
  clearInterval(session.retryTimer);
  session.retryTimer = 0;
  session.nextRetryAt = null;
}

function scheduleRetry(session) {
  if (session.closed || session.retryTimer) return;
  session.autoRetry = true;
  session.nextRetryAt = Date.now() + RETRY_DELAY;
  session.retryTimer = setInterval(() => {
    if (session.closed) return;
    if (Date.now() >= session.nextRetryAt) {
      clearRetry(session);
      connect(session);
    } else {
      emit();
    }
  }, 1000);
  emit();
}

export function stopAutoRetry(session) {
  clearRetry(session);
  session.autoRetry = false;
  emit();
}

async function verifyHostKey(session, wireType, fingerprint) {
  const { address, port } = session.request;
  const check = checkHostKey(address, port, wireType, fingerprint);
  if (check.status === "trusted") return true;
  if (check.status === "changed") return check.message;

  if (!autoAcceptHostKeys()) {
    const accepted = await new Promise((resolve) => {
      session.pendingHostKey = { keyType: check.keyType, fingerprint, resolve };
      session.status = "verifying";
      emit();
    });
    if (!accepted) return "Connection cancelled: host key not trusted.";
  }

  await trustHostKey(app, address, port, check.keyType, fingerprint);
  return true;
}

export function resolveHostKey(session, accept) {
  const pending = session.pendingHostKey;
  if (!pending) return;
  session.pendingHostKey = null;
  if (accept) {
    session.status = "connecting";
    emit();
  }
  pending.resolve(accept);
}

export async function connectHost(host) {
  if (app.account.webSSH === false) {
    snackbar("Web SSH is turned off on this server. An admin can turn it on in the admin page.");
    return;
  }
  const auth = await resolveAuth(host);
  let { username, password, privateKey, passphrase } = auth;
  if (!username) {
    const entered = await promptCredentials(host);
    if (!entered) return;
    username = entered.username;
    password = entered.password;
  }

  openSession({
    hostId: host.id,
    displayName: host.name,
    address: host.address,
    port: parseInt(host.port, 10) || 22,
    username,
    password,
    privateKey,
    passphrase,
    os: host.os,
  });
}

export function openSession(request) {
  const duplicates = sessions.filter((s) => s.request.address === request.address && s.request.port === request.port).length;
  const session = {
    id: `${Date.now()}-${counter++}`,
    request,
    label: duplicates > 0 ? `${request.displayName} (${duplicates + 1})` : request.displayName,
    os: request.os || null,
    status: "connecting",
    error: null,
    el: h("div", { class: "term-host" }),
    term: null,
    fit: null,
    ssh: null,
    generation: 0,
    closedGeneration: -1,
    hasUnseenOutput: false,
    autoRetry: false,
    nextRetryAt: null,
    retryTimer: 0,
    resizeTimer: 0,
    pendingHostKey: null,
    logId: null,
    closed: false,
  };
  sessions.push(session);
  state.activeId = session.id;
  app.go("terminals");
  emit();
  connect(session);
  return session;
}

export function closeSession(session) {
  if (session.closed) return;
  session.closed = true;
  clearRetry(session);
  session.pendingHostKey?.resolve(false);
  session.pendingHostKey = null;
  session.ssh?.close();
  session.ssh = null;
  logDisconnect(session);
  session.term?.dispose();
  session.el.remove();
  const index = sessions.indexOf(session);
  sessions.splice(index, 1);
  if (state.activeId === session.id) {
    state.activeId = (sessions[index] || sessions[index - 1])?.id ?? null;
  }
  emit();
  focusActive();
}

export function reconnect(session) {
  session.ssh?.close();
  session.ssh = null;
  logDisconnect(session);
  session.autoRetry = false;
  connect(session);
}

export function duplicate(session) {
  openSession(session.request);
}

export function rename(session, label) {
  const trimmed = label.trim();
  if (trimmed) session.label = trimmed;
  emit();
}

function markUnseen(session) {
  if (session.hasUnseenOutput) return;
  if (state.visible && state.activeId === session.id) return;
  session.hasUnseenOutput = true;
  emit();
}

export function paste(text) {
  const session = activeSession();
  if (!session?.ssh || !session.term) return false;
  session.term.paste(normalizePaste(text));
  return true;
}

export function run(text) {
  const session = activeSession();
  if (!paste(text)) return false;
  session.ssh.write("\r");
  return true;
}

export function runAll(text) {
  let count = 0;
  for (const session of sessions) {
    if (!session.ssh || !session.term) continue;
    session.term.paste(normalizePaste(text));
    session.ssh.write("\r");
    count++;
  }
  return count;
}

export function copySelection(session) {
  const text = session.term?.getSelection();
  if (text) navigator.clipboard.writeText(text).catch(() => {});
  session.term?.clearSelection();
}

export function pasteClipboard(session) {
  navigator.clipboard.readText().then(
    (text) => session.term?.paste(normalizePaste(text)),
    () => snackbar("Could not access the clipboard"),
  );
}

function findHost(d, request) {
  return d.hosts.find((host) => host.id === request.hostId) || d.hosts.find((host) => host.address === request.address && Number(host.port) === request.port);
}

function logConnect(session) {
  if (session.logId) return;
  const id = uuid();
  session.logId = id;
  const { address, username } = session.request;
  const now = new Date().toISOString();
  app.save((d) => {
    d.sessionLogs.push({ id, address, username, connectedAt: now, disconnectedAt: null, status: "" });
    const host = findHost(d, session.request);
    if (host) host.lastConnected = now;
  });
}

function logDisconnect(session) {
  const id = session.logId;
  if (!id) return;
  session.logId = null;
  const now = new Date().toISOString();
  app.save((d) => {
    const log = d.sessionLogs.find((entry) => entry.id === id);
    if (log) log.disconnectedAt = now;
  });
}

