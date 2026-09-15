import { ApiError, api, sessionToken, signOutLocally } from "./api.js";
import { b64ToBytes, bytesToB64, deriveSyncKey } from "./crypto.js";
import { h, icon } from "./dom.js";
import { createSelectionBar } from "./selection.js";
import * as store from "./store.js";
import { button, connexiaMark, installTooltips, snackbar, textField } from "./ui.js";
import { createHostsScreen } from "./screens/hosts.js";
import { createKeysScreen } from "./screens/keys.js";
import { createKnownHostsScreen } from "./screens/known-hosts.js";
import { createLogsScreen } from "./screens/logs.js";
import { createMetricsScreen } from "./screens/metrics.js";
import { createSettingsScreen } from "./screens/settings.js";
import { createSftpScreen } from "./screens/sftp.js";
import { createSnippetsScreen } from "./screens/snippets.js";
import { createTeamsScreen } from "./screens/teams.js";
import { createTunnelsScreen } from "./screens/tunnels.js";
import { createTerminalsScreen } from "./screens/terminals.js";
import * as terminals from "./ssh/sessions.js";
import { createSessionTabs } from "./ssh/tabs.js";

if (!sessionToken()) {
  location.replace("/login");
}

const SECTIONS = [
  { id: "hosts", label: "Hosts", icon: "dns-outlined", create: createHostsScreen },
  { id: "metrics", label: "Metrics", icon: "query-stats-outlined", create: createMetricsScreen },
  { id: "keys", label: "Keys", icon: "vpn-key-outlined", create: createKeysScreen },
  { id: "tunnels", label: "Tunnels", icon: "lan-outlined", create: createTunnelsScreen },
  { id: "snippets", label: "Snippets", icon: "code", create: createSnippetsScreen },
  { id: "known-hosts", label: "Known hosts", icon: "shield-outlined", create: createKnownHostsScreen },
  { id: "logs", label: "Logs", icon: "receipt-long-outlined", create: createLogsScreen },
  { id: "teams", label: "Teams", icon: "groups-outlined", create: createTeamsScreen },
];
const SETTINGS = { id: "settings", label: "Settings", icon: "settings-outlined", create: createSettingsScreen };
const TERMINALS = { id: "terminals", label: "Terminals", icon: "terminal", create: createTerminalsScreen };
const SFTP = { id: "sftp", label: "SFTP", icon: "swap-horiz", create: createSftpScreen };
const ALL_SECTIONS = [...SECTIONS, SETTINGS, TERMINALS, SFTP];

const content = document.getElementById("content");
const screens = new Map();
const navButtons = [];
let current = null;
let homeButton = null;
let sftpButton = null;
let sessionTabs = null;

const app = {
  account: { email: "", userId: null, isAdmin: false, emailVerified: true, totpEnabled: false },
  selectionBar: createSelectionBar(content),
  go: showSection,
  current: () => current,
  connect: (host) => terminals.connectHost(host),
  loadAccount,
  signOut: signOutLocally,

  async save(change) {
    try {
      await store.mutate(change);
      return true;
    } catch (err) {
      snackbar(`Couldn't save your changes: ${err.message}`);
      return false;
    }
  },
};

async function loadAccount() {
  try {
    const account = await api.get("/api/account");
    Object.assign(app.account, {
      email: account.email || "",
      userId: account.userId,
      isAdmin: Boolean(account.isAdmin),
      emailVerified: account.emailVerified ?? true,
      totpEnabled: Boolean(account.totpEnabled),
      webSSH: account.webSSH !== false,
    });
  } catch {
  }
  return app.account;
}

function buildShell() {
  const titlebar = document.getElementById("titlebar");
  homeButton = h(
    "button",
    { type: "button", class: "titlebar-btn", onClick: () => showSection("hosts") },
    icon("home-outlined", 14),
    h("span", { text: "Home" }),
  );
  sftpButton = h(
    "button",
    { type: "button", class: "titlebar-btn", onClick: () => showSection("sftp") },
    icon("swap-horiz", 14),
    h("span", { text: "SFTP" }),
  );
  const tabStrip = h("div", { class: "titlebar-tabs" });
  const titlebarEnd = h("div", { class: "titlebar-end" });
  titlebar.append(homeButton, sftpButton, tabStrip, titlebarEnd);
  sessionTabs = createSessionTabs({ strip: tabStrip, end: titlebarEnd, mobileRow: document.getElementById("mobile-sessions"), app });

  const navButton = (section) => {
    const el = h(
      "button",
      { type: "button", class: "nav-btn", "data-tip": section.label, "data-tip-below": "1160", onClick: () => showSection(section.id) },
      icon(section.icon, 18),
      h("span", { class: "nav-label", text: section.label }),
    );
    navButtons.push({ id: section.id, el });
    return el;
  };
  document.getElementById("sidebar-list").append(...SECTIONS.map(navButton));
  document.getElementById("sidebar-foot").append(navButton(SETTINGS));

  const mobilebar = document.getElementById("mobilebar");
  for (const section of ALL_SECTIONS) {
    const chip = h("button", { type: "button", class: "mobile-chip", text: section.label, onClick: () => showSection(section.id) });
    navButtons.push({ id: section.id, el: chip });
    mobilebar.append(chip);
  }
}

function showSection(id) {
  let section = ALL_SECTIONS.find((s) => s.id === id) || SECTIONS[0];
  if (section === TERMINALS && terminals.sessions.length === 0) section = SECTIONS[0];
  if (current === section.id) return;

  if (current) screens.get(current)?.hide?.();
  app.selectionBar.hide();
  current = section.id;

  let screen = screens.get(section.id);
  if (!screen) {
    screen = section.create(app);
    screens.set(section.id, screen);
    content.append(screen.el);
  }
  for (const [key, other] of screens) {
    other.el.hidden = key !== section.id;
  }
  screen.show?.();

  for (const nav of navButtons) {
    nav.el.classList.toggle("is-selected", nav.id === section.id);
  }
  homeButton.classList.toggle("is-selected", section.id === "hosts");
  sftpButton.classList.toggle("is-selected", section.id === "sftp");
  document.body.classList.toggle("in-terminals", section.id === "terminals");
  document.body.classList.toggle("in-sftp", section.id === "sftp");
  terminals.setVisible(section.id === "terminals");
  sessionTabs.render();
  syncTerminalsChip();
  history.replaceState(null, "", "#" + section.id);
}

function matchesBinding(event, binding) {
  const parts = binding.split("+").map((p) => p.trim().toLowerCase()).filter(Boolean);
  const key = parts.pop();
  const want = (name) => parts.includes(name);
  const pressed = event.key.length === 1 ? event.key.toLowerCase() : event.key.toLowerCase();
  return (
    pressed === (key === "plus" ? "=" : key) &&
    event.ctrlKey === (want("ctrl") || want("control")) &&
    event.shiftKey === want("shift") &&
    event.altKey === want("alt") &&
    event.metaKey === (want("meta") || want("cmd") || want("win"))
  );
}

document.addEventListener("keydown", (event) => {
  if (!store.state.payload || event.repeat) return;
  const target = event.target;
  if (target.closest?.("input, textarea, [contenteditable]") || document.querySelector(".dialog-barrier, .menu-layer")) {
    return;
  }
  let custom = {};
  try {
    custom = JSON.parse(store.setting("customShortcuts", "{}")) || {};
  } catch {
    custom = {};
  }
  if (matchesBinding(event, custom.editCard || "E")) {
    if (screens.get(current)?.editHovered?.()) event.preventDefault();
  }
});

function showLoading() {
  content.replaceChildren(h("div", { class: "loading" }, h("div", { class: "spinner" })));
}

function showLock(message) {
  const error = h("div", { class: "lock-error", text: message || "" });
  error.hidden = !message;

  const password = textField({ label: "Account password", reveal: true, autofocus: true, onEnter: () => submit() });
  const unlockButton = button({ label: "Unlock", icon: "lock-outline", block: true, className: "btn-h32", onClick: () => submit() });

  const lock = h(
    "div",
    { class: "lock" },
    h(
      "div",
      { class: "lock-card" },
      connexiaMark(40),
      h("div", { class: "lock-title", text: "Unlock your data" }),
      h("div", {
        class: "lock-text",
        text: "Your hosts, keys and snippets are end-to-end encrypted with a key derived from your account password. Enter it to open them in this tab.",
      }),
      password.el,
      h("div", { class: "sp-12" }),
      unlockButton,
      error,
      button({ variant: "text", label: "Sign out", onClick: signOutLocally }),
    ),
  );
  document.body.append(lock);
  password.focus();

  async function submit() {
    if (!password.value) return;
    unlockButton.disabled = true;
    error.hidden = true;
    try {
      const account = app.account.userId ? app.account : await loadAccount();
      if (!account.userId) throw new Error("Could not load your account. Try again.");
      const raw = await deriveSyncKey(password.value, account.userId);
      await store.unlock(raw);
      sessionStorage.setItem("cnx_sync_key", bytesToB64(raw));
      lock.remove();
      start();
    } catch (err) {
      error.textContent = err instanceof ApiError ? err.message : err.name === "OperationError" ? "Wrong password." : err.message;
      error.hidden = false;
      unlockButton.disabled = false;
    }
  }
}

function syncTerminalsChip() {
  for (const nav of navButtons) {
    if (nav.id === "terminals") nav.el.hidden = terminals.sessions.length === 0;
  }
}

function start() {
  content.replaceChildren();
  terminals.init(app);
  terminals.onChange(() => {
    sessionTabs.render();
    syncTerminalsChip();
    if (current === "terminals" && terminals.sessions.length === 0) showSection("hosts");
  });
  window.addEventListener("beforeunload", (event) => {
    if (terminals.sessions.some((s) => s.ssh) || screens.get("sftp")?.busy?.()) event.preventDefault();
  });
  store.onChange((reason) => {
    for (const screen of screens.values()) {
      screen.update?.(reason);
    }
  });
  const fromHash = () => {
    const id = location.hash.slice(1);
    showSection(ALL_SECTIONS.some((s) => s.id === id) ? id : "hosts");
  };
  window.addEventListener("hashchange", fromHash);
  fromHash();
}

async function boot() {
  installTooltips();
  buildShell();
  showLoading();
  loadAccount();

  const cached = sessionStorage.getItem("cnx_sync_key");
  if (cached) {
    try {
      await store.unlock(b64ToBytes(cached));
      start();
      return;
    } catch (err) {
      if (err instanceof ApiError) {
        showLock(err.message);
        return;
      }
      sessionStorage.removeItem("cnx_sync_key");
    }
  }
  showLock();
}

boot();
