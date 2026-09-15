import { api } from "../api.js";
import { fmt, h, icon } from "../dom.js";
import * as store from "../store.js";
import { TERMINAL_THEMES } from "../terminal-themes.js";
import { button, checkboxTile, connexiaMark, openDialog, snackbar, switchControl, textField } from "../ui.js";

const CATEGORIES = [
  { icon: "cloud-outlined", label: "Account", render: accountPanel },
  { icon: "terminal", label: "Terminal", render: terminalPanel },
  { icon: "keyboard-outlined", label: "Shortcuts", render: shortcutsPanel },
  { icon: "storage-outlined", label: "Database", render: databasePanel },
  { icon: "info-outline", label: "About", render: aboutPanel },
];

const SHORTCUTS = [
  { id: "newWindow", label: "New window", binding: "Ctrl+Shift+N" },
  { id: "editCard", label: "Edit card under cursor", binding: "E" },
  { id: "search", label: "Toggle find in terminal", binding: "Ctrl+Shift+F" },
  { id: "copy", label: "Copy selection", binding: "Ctrl+Shift+C" },
  { id: "paste", label: "Paste clipboard", binding: "Ctrl+Shift+V" },
  { id: "zoomIn", label: "Zoom in", binding: "Ctrl+=" },
  { id: "zoomOut", label: "Zoom out", binding: "Ctrl+-" },
  { id: "zoomReset", label: "Reset zoom", binding: "Ctrl+0" },
];

export function createSettingsScreen(app) {
  let category = 0;
  const rail = h("div", { class: "settings-rail" });
  const chips = h("div", { class: "settings-chips" });
  const content = h("div", { class: "settings-content" });
  const el = h("section", { class: "screen" }, chips, h("div", { class: "settings-row" }, rail, content));

  function renderNav() {
    rail.replaceChildren(
      ...CATEGORIES.map((c, i) =>
        h(
          "button",
          { type: "button", class: ["settings-cat", i === category && "is-selected"], onClick: () => choose(i) },
          icon(c.icon, 17),
          h("span", { text: c.label }),
        ),
      ),
    );
    chips.replaceChildren(
      ...CATEGORIES.map((c, i) => h("button", { type: "button", class: ["settings-chip", i === category && "is-selected"], text: c.label, onClick: () => choose(i) })),
    );
  }

  function choose(index) {
    category = index;
    renderNav();
    renderContent(true);
    content.scrollTop = 0;
  }

  function renderContent(force) {
    const active = document.activeElement;
    if (!force && content.contains(active) && active.matches("input, textarea")) return;
    const top = content.scrollTop;
    content.replaceChildren(CATEGORIES[category].render(app, () => renderContent(true)));
    content.scrollTop = top;
  }

  return {
    el,
    update: (reason) => renderContent(false, reason),
    show() {
      renderNav();
      renderContent(true);
      app.loadAccount().then(() => renderContent(false));
    },
  };
}

function title(text) {
  return h("div", { class: "settings-title", text });
}

function iconBox(name) {
  return h("div", { class: "settings-icon" }, icon(name, 18));
}

function saveSetting(app, key, value, rerender) {
  app.save((d) => {
    d.settings[key] = value;
  }).then(rerender);
}

function accountPanel(app, rerender) {
  const account = app.account;
  const { saving, updatedAt } = store.state;

  const status = saving
    ? h("span", { class: "account-status is-pending", text: "Pending changes..." })
    : h("span", { class: "account-status", text: updatedAt ? `Synced ${fmt.relative(updatedAt)}` : "Never synced" });

  const securityRow = (iconName, iconClass, label, value, valueClass) =>
    h("div", { class: "security-row" }, icon(iconName, 17, iconClass), h("span", { class: "security-label", text: label }), h("span", { class: ["security-value", valueClass], text: value }));

  const syncButton = button({
    icon: "sync",
    label: "Sync now",
    block: true,
    className: "btn-h32",
    onClick: async () => {
      syncButton.disabled = true;
      syncButton.querySelector(".btn-label").textContent = "Syncing...";
      try {
        await store.refresh(true);
      } catch (err) {
        snackbar(err.message);
      }
      rerender();
    },
  });

  return h(
    "div",
    { class: "settings-page" },
    title("ACCOUNT"),
    h(
      "div",
      { class: "account-card" },
      h(
        "div",
        { class: "account-top" },
        h("div", { class: "account-icon" }, icon("cloud-done-outlined", 17)),
        h("div", { class: "stack" }, h("span", { class: "account-email", text: account.email }), h("span", { class: "account-server", text: location.origin + "/" })),
      ),
      status,
    ),
    h("div", { class: "sp-14" }),
    title("SECURITY"),
    h(
      "div",
      { class: "security-card" },
      account.emailVerified
        ? securityRow("verified-outlined", "is-success", "Email verification", "Verified", "is-success")
        : securityRow("error-outline", "is-warning", "Email verification", "Pending", "is-warning"),
      h("div", { class: "security-divider" }),
      account.totpEnabled
        ? securityRow("security-outlined", "is-accent", "Two-factor authentication", "Enabled", "is-accent")
        : securityRow("security-outlined", "is-faint", "Two-factor authentication", "Off", "is-muted"),
    ),
    h("div", { class: "sp-8" }),
    button({
      variant: "outlined",
      icon: "shield-outlined",
      iconSize: 15,
      label: account.totpEnabled ? "Disable two-factor authentication" : "Enable two-factor authentication",
      block: true,
      className: "btn-h30",
      onClick: () => (account.totpEnabled ? disableTwoFactor(app, rerender) : enableTwoFactor(app, rerender)),
    }),
    h("div", { class: "sp-12" }),
    syncButton,
    h("div", { class: "sp-8" }),
    button({ variant: "outlined", icon: "logout", iconSize: 15, label: "Sign out", block: true, className: "btn-h30", onClick: app.signOut }),
    h("div", { class: "sp-4" }),
    button({
      variant: "text",
      danger: true,
      icon: "delete-forever-outlined",
      iconSize: 15,
      label: "Delete account",
      block: true,
      className: "btn-h26",
      onClick: () => deleteAccount(app),
    }),
    h("div", { class: "sp-12" }),
    h("div", {
      class: "settings-note",
      text: "This page stays in sync automatically: the server snapshot is checked every few seconds and your edits are uploaded as soon as you make them. Data is encrypted in the browser before upload - the server cannot read it.",
    }),
  );
}

function totpDialog({ heading, confirmLabel, body, confirm }) {
  let confirmButton = null;
  const error = h("div", { class: "dialog-error", text: "Invalid code. Check your authenticator app and try again." });
  error.hidden = true;
  const code = textField({ label: "6-digit code", prefixIcon: "pin-outlined", maxLength: 6, inputMode: "numeric", autofocus: true, onEnter: () => confirmButton?.click() });

  return openDialog({
    title: heading,
    className: "totp-dialog",
    content: h("div", { class: "stack" }, body, h("div", { class: "sp-14" }), code.el, error),
    actions: [
      { label: "Cancel", value: false },
      {
        label: confirmLabel,
        variant: "filled",
        ref: (node) => (confirmButton = node),
        onClick: async (close) => {
          const value = code.value.trim();
          if (!value) return;
          confirmButton.disabled = true;
          error.hidden = true;
          try {
            await confirm(value);
            close(true);
          } catch {
            error.hidden = false;
            confirmButton.disabled = false;
          }
        },
      },
    ],
  }).then((result) => result === true);
}

async function enableTwoFactor(app, rerender) {
  let setup;
  try {
    setup = await api.post("/api/enable-2fa");
  } catch (err) {
    snackbar(err.message);
    return;
  }
  const label = (text) => h("div", { class: "totp-label", text });
  const ok = await totpDialog({
    heading: "Enable two-factor authentication",
    confirmLabel: "Enable",
    body: h(
      "div",
      { class: "stack" },
      h("div", {
        class: "totp-text",
        text: "Add this account to your authenticator app (Google Authenticator, Authy, 1Password, ...), then enter the 6-digit code it shows to finish.",
      }),
      h("div", { class: "sp-12" }),
      label("otpauth:// URL"),
      h("div", { class: "sp-4" }),
      h("div", { class: "totp-url", text: setup.otpauthUrl }),
      h("div", { class: "sp-10" }),
      label("Or enter the secret manually"),
      h("div", { class: "sp-4" }),
      h("div", { class: "totp-secret", text: setup.secret }),
      h("div", { class: "sp-6" }),
      h(
        "div",
        {},
        button({
          variant: "text",
          icon: "copy",
          iconSize: 14,
          label: "Copy otpauth URL",
          className: "totp-copy",
          onClick: () => navigator.clipboard.writeText(setup.otpauthUrl).catch(() => {}),
        }),
      ),
    ),
    confirm: (code) => api.post("/api/confirm-2fa", { code }),
  });
  if (!ok) return;
  app.account.totpEnabled = true;
  rerender();
  snackbar("Two-factor authentication enabled");
}

async function disableTwoFactor(app, rerender) {
  const ok = await totpDialog({
    heading: "Disable two-factor authentication",
    confirmLabel: "Disable",
    body: h("div", { class: "totp-text", text: "Enter a current code from your authenticator app to confirm that you are disabling 2FA." }),
    confirm: (code) => api.post("/api/disable-2fa", { code }),
  });
  if (!ok) return;
  app.account.totpEnabled = false;
  rerender();
  snackbar("Two-factor authentication disabled");
}

async function deleteAccount(app) {
  const email = app.account.email;
  const confirmed = await openDialog({
    title: "Delete account permanently?",
    content: `This removes the account${email ? " " + email : ""} and all of its synced data from the server forever. Your hosts, keys and snippets that were pushed to this account will be gone.\n\nThis cannot be undone.`,
    actions: [
      { label: "Cancel", value: false },
      { label: "Delete permanently", variant: "filled", danger: true, value: true },
    ],
  });
  if (confirmed !== true) return;
  try {
    await api.post("/api/account/delete");
    app.signOut();
  } catch (err) {
    snackbar(err.message);
  }
}

function terminalPanel(app, rerender) {
  const themeName = store.setting("terminalTheme", "Connexia");
  const theme = TERMINAL_THEMES.find((t) => t.name === themeName) || TERMINAL_THEMES[0];
  const fontSize = parseFloat(store.setting("fontSize", "14")) || 14;
  const scrollback = parseInt(store.setting("scrollback", "5000"), 10) || 5000;
  const maxConnects = Math.min(100, Math.max(1, parseInt(store.setting("maxConcurrentConnects", "4"), 10) || 4));
  const autoAccept = store.setting("autoAcceptHostKeys", "false") === "true";

  const double = (v) => (Number.isInteger(v) ? v.toFixed(1) : String(v));

  const autoAcceptSwitch = switchControl({
    checked: autoAccept,
    label: "Auto-accept host keys",
    onChange: (value) => saveSetting(app, "autoAcceptHostKeys", String(value), rerender),
  });

  return h(
    "div",
    { class: "settings-page" },
    title("PREVIEW"),
    h(
      "div",
      { class: "theme-preview", style: { background: theme.background } },
      h("div", { style: { color: theme.green }, text: "connexia@server:~$" }),
      h("div", { style: { color: theme.foreground }, text: "ssh connected — ready" }),
      h("div", { style: { color: theme.cyan }, text: "connexia@server:~$ █" }),
    ),
    h("div", { class: "sp-16" }),
    title("PRESETS"),
    TERMINAL_THEMES.map((preset) => {
      const selected = preset === theme;
      return h(
        "button",
        {
          type: "button",
          class: ["preset-tile", selected && "is-selected"],
          onClick: () => saveSetting(app, "terminalTheme", preset.name, rerender),
        },
        [preset.background, preset.foreground, preset.green, preset.blue, preset.red].map((color) => h("span", { class: "preset-swatch", style: { background: color } })),
        h("span", { class: "preset-name", text: preset.name }),
        icon(selected ? "check-circle" : "circle-outlined", 17, "preset-check"),
      );
    }),
    h("div", { class: "sp-8" }),
    title("TERMINAL SETTINGS"),
    stepperCard({
      iconName: "format-size",
      title: "Font size",
      description: "Character size in terminal sessions.",
      value: fontSize,
      suffix: "pt",
      min: 8,
      max: 28,
      isDouble: true,
      decrease: () => saveSetting(app, "fontSize", double(fontSize - 1), rerender),
      increase: () => saveSetting(app, "fontSize", double(fontSize + 1), rerender),
      change: (v) => saveSetting(app, "fontSize", double(v), rerender),
    }),
    h("div", { class: "sp-10" }),
    stepperCard({
      iconName: "history",
      title: "Scrollback lines",
      description: "How many lines of history to keep per session.",
      value: scrollback,
      suffix: "lines",
      min: 100,
      max: 100000,
      decrease: () => saveSetting(app, "scrollback", String(Math.floor(scrollback / 2)), rerender),
      increase: () => saveSetting(app, "scrollback", String(scrollback * 2), rerender),
      change: (v) => saveSetting(app, "scrollback", String(v), rerender),
    }),
    h("div", { class: "sp-10" }),
    stepperCard({
      iconName: "sync-alt",
      title: "Max parallel connections",
      description: "How many hosts may connect at the same time. Lower keeps the UI snappier; higher connects many hosts faster.",
      value: maxConnects,
      min: 1,
      max: 100,
      decrease: () => saveSetting(app, "maxConcurrentConnects", String(maxConnects - 1), rerender),
      increase: () => saveSetting(app, "maxConcurrentConnects", String(maxConnects + 1), rerender),
      change: (v) => saveSetting(app, "maxConcurrentConnects", String(v), rerender),
    }),
    h("div", { class: "sp-10" }),
    h(
      "div",
      { class: "settings-card" },
      iconBox("security-outlined"),
      h(
        "div",
        { class: "settings-card-text" },
        h("span", { class: "settings-card-title", text: "Auto-accept host keys" }),
        h("span", { class: "settings-card-desc", text: "Trust the host key of any new host automatically without asking for confirmation." }),
      ),
      autoAcceptSwitch.el,
    ),
  );
}

function stepperCard({ iconName, title: heading, description, value, suffix, min, max, isDouble, decrease, increase, change }) {
  const format = (v) => (isDouble ? (Number.isInteger(v) ? String(v) : v.toFixed(1)) : String(Math.round(v)));
  const input = h("input", { class: "stepper-input", value: format(value), inputmode: isDouble ? "decimal" : "numeric" });
  input.addEventListener("input", () => {
    input.value = input.value.replace(isDouble ? /[^0-9.]/g : /[^0-9]/g, "");
  });
  const commit = () => {
    const parsed = isDouble ? parseFloat(input.value) : parseInt(input.value, 10);
    if (Number.isNaN(parsed)) {
      input.value = format(value);
      return;
    }
    const clamped = Math.min(max, Math.max(min, parsed));
    input.value = format(clamped);
    if (clamped !== value) change(clamped);
  };
  input.addEventListener("blur", commit);
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter") input.blur();
  });

  const stepButton = (iconName, enabled, onClick) =>
    h("button", { type: "button", class: "step-btn", disabled: !enabled, onClick }, icon(iconName, 15));

  return h(
    "div",
    { class: "settings-card" },
    iconBox(iconName),
    h("div", { class: "settings-card-text" }, h("span", { class: "settings-card-title", text: heading }), h("span", { class: "settings-card-desc", text: description })),
    h("div", { class: "stepper-value" }, input, suffix && h("span", { class: "stepper-suffix", text: suffix })),
    stepButton("remove", value > min, decrease),
    stepButton("add", value < max, increase),
  );
}

function customShortcuts() {
  try {
    const parsed = JSON.parse(store.setting("customShortcuts", "{}"));
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function saveShortcuts(app, map, rerender) {
  saveSetting(app, "customShortcuts", JSON.stringify(map), rerender);
}

function shortcutsPanel(app, rerender) {
  const custom = customShortcuts();
  return h(
    "div",
    { class: "settings-page" },
    title("KEYBOARD SHORTCUTS"),
    h("div", { class: "settings-lead", text: "Click Record on any shortcut to press a new key combination, or Reset to restore the default." }),
    h("div", { class: "sp-14" }),
    SHORTCUTS.map((shortcut) => {
      const isCustom = Boolean(custom[shortcut.id]);
      return h(
        "div",
        { class: "shortcut-row" },
        iconBox("keyboard-outlined"),
        h(
          "div",
          { class: "settings-card-text" },
          h("span", { class: "settings-card-title", text: shortcut.label }),
          isCustom && h("span", { class: "shortcut-custom", text: "Custom" }),
        ),
        h("span", { class: "shortcut-binding", text: custom[shortcut.id] || shortcut.binding }),
        h("button", { type: "button", class: "shortcut-record", onClick: () => recordShortcut(app, shortcut, rerender) }, icon("edit-outlined", 13), h("span", { text: "Record" })),
        isCustom &&
          h(
            "button",
            {
              type: "button",
              class: "shortcut-reset",
              onClick: () => {
                const next = customShortcuts();
                delete next[shortcut.id];
                saveShortcuts(app, next, rerender);
              },
            },
            icon("restart-alt", 14),
          ),
      );
    }),
  );
}

const KEY_NAMES = { " ": "Space", ArrowUp: "Up", ArrowDown: "Down", ArrowLeft: "Left", ArrowRight: "Right", PageUp: "PageUp", PageDown: "PageDown" };

function chordOf(event) {
  const parts = [];
  if (event.ctrlKey) parts.push("Ctrl");
  if (event.shiftKey) parts.push("Shift");
  if (event.altKey) parts.push("Alt");
  if (event.metaKey) parts.push("Meta");
  let key;
  if (event.code.startsWith("Key")) key = event.code.slice(3);
  else if (event.code.startsWith("Digit")) key = event.code.slice(5);
  else if (event.code === "Equal") key = "=";
  else if (event.code === "Minus") key = "-";
  else key = KEY_NAMES[event.key] || event.key;
  parts.push(key);
  return parts.join("+");
}

function recordShortcut(app, shortcut, rerender) {
  let stopListening = () => {};
  openDialog({
    title: "Record shortcut",
    className: "record-dialog",
    content: (close) => {
      const onKey = (event) => {
        event.preventDefault();
        event.stopPropagation();
        if (["Control", "Shift", "Alt", "Meta"].includes(event.key)) return;
        if (event.key !== "Escape") {
          const next = customShortcuts();
          if (event.key === "Backspace" || event.key === "Delete") delete next[shortcut.id];
          else next[shortcut.id] = chordOf(event);
          saveShortcuts(app, next, rerender);
        }
        close();
      };
      window.addEventListener("keydown", onKey, true);
      stopListening = () => window.removeEventListener("keydown", onKey, true);
      return h(
        "div",
        { class: "stack" },
        h("div", { class: "record-label", text: shortcut.label }),
        h("div", { class: "sp-12" }),
        h("div", { class: "record-box", text: "Press the keys now…" }),
        h("div", { class: "sp-10" }),
        h("div", { class: "record-hint", text: "Press Escape to cancel, Backspace to clear." }),
      );
    },
    actions: [{ label: "Cancel", className: "btn-muted" }],
  }).then(() => stopListening());
}

const DATA_TILES = [
  ["hosts", "Hosts", "dns-outlined"],
  ["groups", "Groups", "folder-outlined"],
  ["identities", "Keys", "key-outlined"],
  ["snippets", "Snippets", "code"],
  ["knownHosts", "Known hosts", "verified-user-outlined"],
  ["sessionLogs", "Session logs", "history"],
];

const EXPORT_OPTIONS = [
  ["hosts", "Hosts", "dns-outlined"],
  ["groups", "Groups", "folder-outlined"],
  ["keys", "SSH keys", "key-outlined"],
  ["snippets", "Snippets", "code"],
  ["knownHosts", "Known hosts", "verified-user-outlined"],
];

function databasePanel(app, rerender) {
  const data = store.data();
  const { revision, updatedAt, blobBytes } = store.state;

  return h(
    "div",
    { class: "settings-page" },
    h(
      "div",
      { class: "settings-title-row" },
      title("ENCRYPTED SNAPSHOT"),
      h(
        "button",
        {
          type: "button",
          class: "square-btn",
          "data-tip": "Refresh",
          onClick: () =>
            store
              .refresh(true)
              .catch((err) => snackbar(err.message))
              .then(rerender),
        },
        icon("refresh", 15),
      ),
    ),
    h(
      "div",
      { class: "settings-card is-top" },
      iconBox("storage-outlined"),
      h(
        "div",
        { class: "settings-card-text" },
        h("span", { class: "settings-card-title", text: "Sync server" }),
        h("span", { class: "db-path", text: location.origin + "/" }),
        h("span", { class: "db-meta", text: `Snapshot: ${fmt.bytes(blobBytes)} · revision ${revision}` }),
        updatedAt && h("span", { class: "db-meta is-tight", text: `Last update: ${fmt.second(updatedAt)}` }),
      ),
    ),
    h("div", { class: "sp-20" }),
    title("DATA"),
    h(
      "div",
      { class: "db-tiles" },
      DATA_TILES.map(([table, label, iconName]) =>
        h(
          "div",
          { class: "db-tile" },
          h("div", { class: "db-tile-icon" }, icon(iconName, 14)),
          h("div", { class: "stack" }, h("span", { class: "db-tile-count", text: String(data[table].length) }), h("span", { class: "db-tile-label", text: label })),
        ),
      ),
    ),
    h("div", { class: "sp-20" }),
    h(
      "div",
      { class: "settings-card" },
      iconBox("file-download-outlined"),
      h(
        "div",
        { class: "settings-card-text" },
        h("span", { class: "settings-card-title", text: "Export data" }),
        h("span", { class: "settings-card-desc", text: "Save hosts, keys, snippets and more as a readable JSON file. You can choose which parts to include." }),
      ),
      button({ icon: "save-alt", label: "Export", className: "btn-h30", onClick: exportData }),
    ),
  );
}

async function exportData() {
  const selected = new Set(EXPORT_OPTIONS.map(([id]) => id));
  let exportButton = null;
  const choice = await openDialog({
    title: "Export data",
    className: "export-dialog",
    content: h(
      "div",
      { class: "stack" },
      h("div", { class: "totp-text", text: "Choose what to include in the export file." }),
      h("div", { class: "sp-10" }),
      EXPORT_OPTIONS.map(([id, label, iconName]) =>
        checkboxTile({
          label,
          checked: true,
          trailingIcon: iconName,
          onChange: (checked) => {
            if (checked) selected.add(id);
            else selected.delete(id);
            exportButton.disabled = selected.size === 0;
          },
        }).el,
      ),
      h("div", { class: "sp-4" }),
      h("div", { class: "export-note", text: "Passwords and private keys are exported in their encrypted form, never in plain text." }),
    ),
    actions: [
      { label: "Cancel", value: false },
      { label: "Export", variant: "filled", value: true, ref: (node) => (exportButton = node) },
    ],
  });
  if (choice !== true) return;

  const data = store.data();
  const now = new Date();
  const two = (n) => String(n).padStart(2, "0");
  const stamp = `${now.getFullYear()}${two(now.getMonth() + 1)}${two(now.getDate())}_${two(now.getHours())}${two(now.getMinutes())}${two(now.getSeconds())}`;
  const out = { app: "connexia", formatVersion: 1, exportedAt: now.toISOString() };
  const counts = [];
  const add = (id, key, items, noun) => {
    if (!selected.has(id)) return;
    out[key] = items;
    counts.push(`${items.length} ${noun}${items.length === 1 ? "" : "s"}`);
  };
  add("hosts", "hosts", data.hosts, "host");
  add("groups", "groups", data.groups, "group");
  add("keys", "keys", data.identities, "key");
  add("snippets", "snippets", data.snippets, "snippet");
  add("knownHosts", "knownHosts", data.knownHosts, "known host");

  const fileName = `connexia_export_${stamp}.json`;
  const url = URL.createObjectURL(new Blob([JSON.stringify(out, null, 2)], { type: "application/json" }));
  const link = h("a", { href: url, download: fileName });
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  snackbar(`Exported ${counts.join(", ")} to ${fileName}`, 6000);
}

let latestVersion = null;

function aboutPanel() {
  const version = h("span", { class: "about-version", text: latestVersion ? `Version ${latestVersion}` : "" });
  if (!latestVersion) {
    fetch("https://api.github.com/repos/Theyka/Connexia/releases/latest")
      .then((r) => (r.ok ? r.json() : null))
      .then((release) => {
        if (!release?.tag_name) return;
        latestVersion = release.tag_name.replace(/^v/, "");
        version.textContent = `Version ${latestVersion}`;
      })
      .catch(() => {});
  }

  const link = (iconNode, label, url) =>
    h("a", { class: "about-link", href: url, target: "_blank", rel: "noopener" }, h("span", { class: "about-link-icon" }, iconNode), h("span", { text: label }), icon("open-in-new", 11, "about-link-out"));

  return h(
    "div",
    { class: "settings-page" },
    h(
      "div",
      { class: "about-card" },
      h("div", { class: "about-head" }, connexiaMark(40), h("div", { class: "stack" }, h("span", { class: "about-name", text: "Connexia" }), version)),
      h("div", { class: "sp-16" }),
      h("div", { class: "about-text", text: "SSH client and terminal emulator. Works on Windows, macOS, Linux, iOS and Android. All data stays on your device." }),
      h("div", { class: "sp-16" }),
      h("div", { class: "about-tags" }, ["SSH / SFTP", "Local-first", "Open source"].map((tag) => h("span", { class: "about-tag", text: tag }))),
      h("div", { class: "sp-20" }),
      link(icon("language", 15), "connexia.run", "https://connexia.run"),
      link(icon("fa-github", 14), "github.com/Theyka", "https://github.com/Theyka"),
    ),
  );
}
