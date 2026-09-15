import { h, isTouch, uuid } from "../dom.js";
import { enableBandSelection } from "../selection.js";
import * as store from "../store.js";
import {
  button, cardAction, confirmDialog, copyToClipboard, emptyState, needsApp, openPanel, panelHeader, panelLayout,
  selectField, showMenu, snackbar, switchTile, textField,
} from "../ui.js";
import { card, gap, grid, markSelected, modKey, replaceKeepingScroll, searchBox, tile, trackHover } from "./common.js";

const TYPE_ICONS = { dynamic: "hub-outlined", remote: "arrow-outward-outlined" };

const portLabel = (tunnel) => (tunnel.bindPort == null ? "auto" : String(tunnel.bindPort));

function ruleText(tunnel) {
  const port = portLabel(tunnel);
  switch (tunnel.type) {
    case "local": {
      const target = tunnel.targetHost;
      const isLocal = !target || target === "localhost" || target === "127.0.0.1";
      return `${tunnel.bindAddress}:${port} → ${isLocal ? "" : target + ":"}${tunnel.targetPort ?? 0}`;
    }
    case "dynamic":
      return `SOCKS5 ${tunnel.bindAddress}:${port}`;
    case "remote":
      return `remote ${tunnel.bindAddress}:${port}`;
    default:
      return tunnel.type;
  }
}

function copyEndpoint(tunnel) {
  if (tunnel.bindPort == null) {
    snackbar("Start the tunnel to get its bound port", 2000);
    return;
  }
  const text = `${tunnel.bindAddress}:${tunnel.bindPort}`;
  copyToClipboard(text, `Copied ${text}`);
}

export function createTunnelsScreen(app) {
  let query = "";
  let visible = false;
  let panel = null;
  const multi = new Set();

  const search = searchBox("Search tunnels...", (value) => {
    query = value;
    render();
  });
  const toolbar = h(
    "div",
    { class: "toolbar" },
    search.el,
    h("div", { class: "toolbar-actions" }, button({ icon: "add", label: "New tunnel", size: "toolbar", onClick: () => openEditor(null) })),
  );
  const scroll = h("div", { class: "scroll" });
  const body = h("div", { class: "screen-body" }, scroll);
  const el = h("section", { class: "screen" }, toolbar, body);
  const hover = trackHover(scroll);

  enableBandSelection(scroll, {
    layer: body,
    getSelected: () => multi,
    onChange: (next) => {
      multi.clear();
      next.forEach((key) => multi.add(key));
      refreshSelection();
    },
    onEmptyClick: () => {
      if (multi.size === 0) return;
      multi.clear();
      refreshSelection();
    },
  });

  function refreshSelection() {
    markSelected(scroll, (key) => multi.has(key));
    syncSelectionBar();
  }

  function syncSelectionBar() {
    if (!visible || multi.size === 0) {
      app.selectionBar.hide();
      return;
    }
    app.selectionBar.show({
      count: multi.size,
      actions: [
        { icon: "play-arrow", label: "Start", onClick: () => needsApp("Starting a tunnel") },
        { icon: "refresh", label: "Restart", onClick: () => needsApp("Restarting a tunnel") },
        { icon: "stop", label: "Stop", onClick: () => needsApp("Stopping a tunnel") },
        { icon: "delete-outline", label: "Delete", danger: true, onClick: deleteSelection },
      ],
      onClose: () => {
        multi.clear();
        refreshSelection();
      },
    });
  }

  function render() {
    const tunnels = store.data().tunnels;
    const q = query.trim().toLowerCase();
    const filtered = tunnels
      .filter((t) => !q || [t.name, t.type, t.bindAddress].some((v) => (v || "").toLowerCase().includes(q)))
      .sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()));

    let nodes;
    if (tunnels.length === 0) {
      nodes = [
        emptyState({
          icon: "lan-outlined",
          title: "No tunnels yet",
          message: "Set up SSH port forwarding rules that outlive any single session.",
          action: button({ icon: "add", label: "Create your first tunnel", size: "toolbar", onClick: () => openEditor(null) }),
        }),
      ];
    } else if (filtered.length === 0) {
      nodes = [h("div", { class: "no-matches", text: "No matches" })];
    } else {
      nodes = [grid(filtered.map(tunnelCard), { rowHeight: 64, padding: "top" })];
    }
    replaceKeepingScroll(scroll, nodes);
    syncSelectionBar();
  }

  function tunnelCard(tunnel) {
    const rule = ruleText(tunnel);
    const ruleEl = h("span", {
      class: "card-sub is-rule",
      text: rule,
      "data-tip": `${rule}\nClick to copy`,
      "data-tip-wait": "500",
      onClick: (event) => {
        event.stopPropagation();
        copyEndpoint(tunnel);
      },
    });
    return card({
      key: tunnel.id,
      selected: multi.has(tunnel.id),
      tile: tile(TYPE_ICONS[tunnel.type] || "input-outlined"),
      title: tunnel.name,
      sub: ruleEl,
      action: cardAction({ icon: "play-arrow-rounded", tooltip: "Start", onClick: () => needsApp("Starting a tunnel") }),
      actionOnTouch: true,
      onClick: (event) => {
        if (modKey(event)) {
          if (multi.has(tunnel.id)) multi.delete(tunnel.id);
          else multi.add(tunnel.id);
        } else if (multi.size > 0) {
          multi.clear();
        } else if (isTouch) {
          openEditor(tunnel);
        }
        refreshSelection();
      },
      onMenu: (x, y) =>
        showMenu({
          x,
          y,
          items: [
            { icon: "edit-outlined", label: "Edit", onSelect: () => openEditor(tunnel) },
            { icon: "play-arrow-outlined", label: "Start", onSelect: () => needsApp("Starting a tunnel") },
            { icon: "refresh-outlined", label: "Restart", onSelect: () => needsApp("Restarting a tunnel") },
            {
              icon: "content-copy-outlined",
              label: tunnel.bindPort == null ? "Copy endpoint" : `Copy ${tunnel.bindPort}`,
              onSelect: () => copyEndpoint(tunnel),
            },
            {
              icon: "delete-outline",
              label: "Delete",
              danger: true,
              onSelect: () =>
                app.save((d) => {
                  d.tunnels = d.tunnels.filter((t) => t.id !== tunnel.id);
                }),
            },
          ].map((item) => ({ ...item, iconSize: 15, className: "is-small" })),
        }),
    });
  }

  async function deleteSelection() {
    const ids = [...multi];
    if (ids.length === 0) return;
    const confirmed = await confirmDialog({
      title: "Delete tunnels",
      message: `Delete ${ids.length} tunnel${ids.length === 1 ? "" : "s"}? Running tunnels will be stopped.`,
    });
    if (!confirmed) return;
    await app.save((d) => {
      d.tunnels = d.tunnels.filter((t) => !ids.includes(t.id));
    });
    multi.clear();
    render();
  }

  function openEditor(tunnel) {
    panel?.close();
    panel = openPanel(el, {
      width: 360,
      build: (p) => tunnelForm(app, p, tunnel),
      onClose: () => {
        panel = null;
      },
    });
    panel.targetId = tunnel?.id ?? null;
  }

  return {
    el,
    update() {
      render();
      if (panel?.targetId && !store.data().tunnels.some((t) => t.id === panel.targetId)) {
        panel.close();
      }
    },
    show() {
      visible = true;
      render();
    },
    hide() {
      visible = false;
      multi.clear();
    },
    editHovered() {
      const tunnel = store.data().tunnels.find((t) => t.id === hover.key);
      if (tunnel) openEditor(tunnel);
      return Boolean(tunnel);
    },
  };
}

function tunnelForm(app, panel, tunnel) {
  const data = store.data();
  let type = tunnel?.type ?? "local";
  let hostId = tunnel?.hostId ?? null;
  let authType = tunnel?.authType ?? "";
  let keyId = tunnel?.keyId ?? null;

  const label = (text) => h("div", { class: "panel-label-small", text: text.toUpperCase() });
  const name = textField({ label: "Name", value: tunnel?.name, autofocus: true });
  const typeField = selectField({
    label: "Type",
    value: type,
    options: [
      { value: "local", label: "Local forward (-L)" },
      { value: "dynamic", label: "Dynamic / SOCKS5 (-D)" },
      { value: "remote", label: "Remote forward (-R)" },
    ],
    onChange: (value) => {
      type = value;
      renderRule();
    },
  });
  const autoStart = switchTile({
    title: "Auto-start at launch",
    subtitle: "Connect this tunnel automatically when Connexia opens.",
    checked: tunnel?.autoStart ?? false,
  });

  const serverAddress = textField({ label: "Server address", helper: "SSH server the tunnel connects to.", value: tunnel?.address ?? "" });
  const serverPort = textField({ label: "Server port", value: tunnel ? String(tunnel.port ?? "") : "", inputMode: "numeric" });
  const username = textField({ label: "Username", value: tunnel?.username ?? "" });
  const password = textField({
    label: tunnel?.encryptedPassword != null ? "New password (leave blank to keep)" : "Password",
    type: "password",
  });
  const standalone = h("div", { class: "stack" });
  const authBox = h("div", { class: "stack" });

  const renderAuth = () => {
    if (authType === "password") {
      authBox.replaceChildren(gap(10), password.el);
    } else if (authType === "key") {
      const identity = selectField({
        label: "Identity",
        icon: "vpn-key-outlined",
        value: keyId,
        searchable: data.identities.length >= 8,
        options: data.identities.map((i) => ({ value: i.id, label: i.name, subtitle: i.comment || null })),
        onChange: (value) => {
          keyId = value;
        },
      });
      authBox.replaceChildren(gap(10), identity.el);
    } else {
      authBox.replaceChildren();
    }
  };

  const authField = selectField({
    label: "Authentication",
    icon: "lock-outline",
    value: authType || null,
    options: [
      { value: "password", label: "Password" },
      { value: "key", label: "Private key" },
    ],
    onChange: (value) => {
      authType = value || "";
      if (authType !== "key") keyId = null;
      renderAuth();
    },
  });

  const renderSource = () => {
    standalone.replaceChildren(
      ...(hostId == null
        ? [gap(10), serverAddress.el, gap(10), serverPort.el, gap(10), authField.el, gap(10), username.el, authBox]
        : []),
    );
  };

  const hostField = selectField({
    label: "Linked host",
    icon: "dns-outlined",
    value: hostId,
    searchable: data.hosts.length >= 8,
    helper: "Inherit credentials from this saved host.",
    options: [
      { value: null, label: "Standalone (no host)", subtitle: "Enter credentials manually below" },
      ...data.hosts.map((host) => ({ value: host.id, label: host.name, subtitle: `${host.address}:${host.port}` })),
    ],
    onChange: (value) => {
      hostId = value;
      renderSource();
    },
  });

  const bindAddress = textField({ label: "Bind address", helper: "127.0.0.1 = loopback only; 0.0.0.0 = all interfaces.", value: tunnel?.bindAddress ?? "127.0.0.1" });
  const bindPort = textField({ label: "Bind port", helper: "Leave blank to let the OS pick.", value: tunnel?.bindPort != null ? String(tunnel.bindPort) : "", inputMode: "numeric" });
  const targetHost = textField({ label: "Target host", helper: "Hostname or IP on the remote side.", value: tunnel?.targetHost ?? "" });
  const targetPort = textField({ label: "Target port", value: tunnel?.targetPort != null ? String(tunnel.targetPort) : "", inputMode: "numeric" });
  const target = h("div", { class: "stack" });
  const renderRule = () => {
    target.replaceChildren(...(type === "local" || type === "remote" ? [gap(10), targetHost.el, gap(10), targetPort.el] : []));
  };
  const notes = textField({ hint: "Optional notes…", multiline: true, rows: 3, value: tunnel?.notes ?? "" });

  renderAuth();
  renderSource();
  renderRule();

  async function save() {
    const tunnelName = name.value.trim();
    if (!tunnelName) return;
    const int = (field) => {
      const n = parseInt(field.value.trim(), 10);
      return Number.isNaN(n) ? null : n;
    };
    const isStandalone = hostId == null;
    const newPassword = password.value;
    const ok = await app.save(async (d) => {
      const existing = d.tunnels.find((t) => t.id === tunnel?.id);
      let encryptedPassword = null;
      if (authType === "password" && newPassword) encryptedPassword = await store.vault.encrypt(newPassword, d);
      else if (existing && authType === "password") encryptedPassword = existing.encryptedPassword;

      const fields = {
        id: tunnel?.id ?? uuid(),
        name: tunnelName,
        hostId,
        type,
        address: isStandalone ? serverAddress.value.trim() || null : null,
        port: isStandalone ? int(serverPort) ?? 22 : 22,
        username: isStandalone && username.value.trim() ? username.value.trim() : null,
        authType: isStandalone && authType ? authType : null,
        keyId: isStandalone ? keyId : null,
        encryptedPassword: isStandalone ? encryptedPassword : null,
        bindAddress: bindAddress.value.trim() || "127.0.0.1",
        bindPort: int(bindPort),
        targetHost: targetHost.value.trim() || null,
        targetPort: int(targetPort),
        autoStart: autoStart.input.checked,
        color: existing?.color ?? null,
        notes: notes.value,
        createdAt: existing?.createdAt ?? new Date().toISOString(),
      };
      if (existing) Object.assign(existing, fields);
      else d.tunnels.push({ workspaceId: null, ...fields });
    });
    if (ok) panel.close();
  }

  return panelLayout({
    children: [
      panelHeader({ title: tunnel ? "Edit tunnel" : "New tunnel", onClose: () => panel.close() }),
      label("General"),
      gap(6),
      name.el,
      gap(10),
      typeField.el,
      gap(10),
      autoStart.el,
      gap(18),
      label("Connection source"),
      gap(6),
      hostField.el,
      standalone,
      gap(18),
      label("Forward rule"),
      gap(6),
      bindAddress.el,
      gap(10),
      bindPort.el,
      target,
      gap(18),
      label("Notes"),
      gap(6),
      notes.el,
    ],
    footer: button({ icon: "check", label: "Save tunnel", block: true, className: "btn-h32", onClick: save }),
  });
}
