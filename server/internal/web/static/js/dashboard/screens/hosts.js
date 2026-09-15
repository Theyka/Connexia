import { h, icon, isTouch, osIconName, toDate, uuid } from "../dom.js";
import { enableBandSelection } from "../selection.js";
import * as store from "../store.js";
import {
  button, cardAction, checkboxTile, confirmDialog, emptyState, keySelectField, noResults,
  openDialog, openPanel, panelHeader, panelLayout, sectionHeader, segmented, selectField, showMenu, textField,
} from "../ui.js";
import {
  card, colorFromInt, gap, grid, markSelected, modKey, replaceKeepingScroll, searchBox, sectionCard, tile, trackHover,
} from "./common.js";

const hostKey = (id) => "h:" + id;
const groupKey = (id) => "g:" + id;

const AUTH_OPTIONS = [
  { value: "password", label: "Password", icon: "key-outlined" },
  { value: "key", label: "Key", icon: "vpn-key-outlined" },
];

const NEW_HOST = { color: null, notes: "", favorite: false, lastConnected: null, os: null, workspaceId: null };
const NEW_GROUP = { parentId: null, color: null, sortOrder: 0, workspaceId: null };

function sortedHosts(hosts) {
  const time = (host) => toDate(host.lastConnected)?.getTime() ?? -Infinity;
  return hosts
    .map((host, index) => ({ host, index }))
    .sort((a, b) => time(b.host) - time(a.host) || a.index - b.index)
    .map((entry) => entry.host);
}

export function createHostsScreen(app) {
  let query = "";
  let selectedId = null;
  let openGroupId = null;
  let visible = false;
  let panel = null;
  const multi = new Set();

  const search = searchBox("Search hosts, groups, addresses, tags...", (value) => {
    query = value;
    render();
  });
  const toolbar = h(
    "div",
    { class: "toolbar" },
    search.el,
    h(
      "div",
      { class: "toolbar-actions" },
      button({ icon: "add", iconSize: 15, label: "New host", size: "toolbar", onClick: () => openHostEditor(null, openGroupId) }),
      button({ variant: "outlined", icon: "create-new-folder-outlined", iconSize: 15, label: "New group", size: "toolbar", onClick: () => openGroupEditor(null) }),
    ),
  );
  const breadcrumb = h("div", { class: "breadcrumb" });
  const scroll = h("div", { class: "scroll" });
  const body = h("div", { class: "screen-body" }, scroll);
  const el = h("section", { class: "screen" }, toolbar, breadcrumb, body);
  const hover = trackHover(scroll);

  const isCardSelected = (key) => multi.has(key) || (multi.size === 0 && key.slice(2) === selectedId);

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
    markSelected(scroll, isCardSelected);
    syncSelectionBar();
  }

  function selectedHostIds() {
    const ids = new Set();
    for (const key of multi) {
      if (key.startsWith("h:")) {
        ids.add(key.slice(2));
      } else {
        for (const host of store.data().hosts) {
          if (host.groupId === key.slice(2)) ids.add(host.id);
        }
      }
    }
    return ids;
  }

  function connectHosts(hosts) {
    for (const host of hosts) app.connect(host);
  }

  function connectSelection() {
    const ids = selectedHostIds();
    connectHosts(store.data().hosts.filter((h) => ids.has(h.id)));
  }

  function syncSelectionBar() {
    if (!visible || multi.size === 0) {
      app.selectionBar.hide();
      return;
    }
    app.selectionBar.show({
      count: multi.size,
      actions: [
        { icon: "terminal", label: "Connect", onClick: selectedHostIds().size > 0 ? connectSelection : null },
        { icon: "delete-outline", label: "Delete", danger: true, onClick: deleteSelection },
      ],
      onClose: () => {
        multi.clear();
        refreshSelection();
      },
    });
  }

  function onTap(key, event, openOnTouch) {
    if (modKey(event)) {
      if (multi.has(key)) multi.delete(key);
      else multi.add(key);
    } else if (multi.size > 0) {
      multi.clear();
      selectedId = key.slice(2);
    } else {
      selectedId = key.slice(2);
      if (isTouch && openOnTouch) openOnTouch();
    }
    refreshSelection();
  }

  function render() {
    const data = store.data();
    const hosts = sortedHosts(data.hosts);
    const groups = data.groups;
    const openGroup = openGroupId ? groups.find((g) => g.id === openGroupId) : null;
    if (!openGroup) openGroupId = null;

    breadcrumb.hidden = !openGroup;
    if (openGroup) {
      breadcrumb.replaceChildren(
        h("button", { type: "button", class: "breadcrumb-back", onClick: () => openFolder(null) }, icon("arrow-back-ios-new", 13), h("span", { text: "Groups" })),
        icon("chevron-right", 16, "breadcrumb-chevron"),
        h("span", { class: "breadcrumb-name", text: openGroup.name }),
      );
    }

    const q = query.trim().toLowerCase();
    const searching = q !== "";
    const matches = (value) => (value || "").toLowerCase().includes(q);
    const filtered = hosts.filter(
      (host) =>
        (!openGroupId || host.groupId === openGroupId) &&
        (!searching || matches(host.name) || matches(host.address) || matches(host.username) || matches(host.tags)),
    );
    const counts = new Map();
    for (const host of hosts) {
      if (host.groupId) counts.set(host.groupId, (counts.get(host.groupId) || 0) + 1);
    }

    const hostGrid = (list) => grid(list.map(hostCard), { rowHeight: 64 });
    const groupGrid = (list) => grid(list.map((g) => groupCard(g, counts.get(g.id) || 0)), { rowHeight: 64 });
    const nodes = [];

    if (searching && !openGroup) {
      const matchedIds = new Set(filtered.map((host) => host.groupId).filter(Boolean));
      const matchedGroups = groups.filter((g) => matchedIds.has(g.id));
      if (matchedGroups.length) nodes.push(sectionHeader("Groups"), groupGrid(matchedGroups));
      if (filtered.length) nodes.push(sectionHeader("Hosts"), hostGrid(filtered));
      if (nodes.length === 0) nodes.push(noResults("No hosts match your search"));
    } else if (openGroup) {
      if (filtered.length) nodes.push(sectionHeader("Hosts"), hostGrid(filtered));
      else nodes.push(searching ? noResults("No hosts match your search") : groupEmpty(openGroup));
    } else {
      if (groups.length) nodes.push(sectionHeader("Groups"), groupGrid(groups));
      if (filtered.length) {
        nodes.push(sectionHeader("Hosts"), hostGrid(filtered));
      } else if (groups.length === 0 && hosts.length === 0) {
        nodes.push(
          emptyState({
            icon: "dns-outlined",
            title: "No hosts yet",
            message: "Add your first host to start connecting.",
            action: button({ icon: "add", label: "Add your first host", size: "toolbar", onClick: () => openHostEditor(null) }),
          }),
        );
      }
    }

    replaceKeepingScroll(scroll, nodes);
    syncSelectionBar();
  }

  function hostCard(host) {
    const key = hostKey(host.id);
    const tileNode = tile(osIconName(host.os), colorFromInt(host.color) || "#3ddc97");
    tileNode.dataset.tip = host.os || "Host";
    tileNode.dataset.tipWait = "600";
    return card({
      key,
      selected: isCardSelected(key),
      thickBorder: true,
      tile: tileNode,
      title: host.name,
      extras: host.favorite && icon("star", 12, "card-star"),
      sub: host.username ? `${host.username}@${host.address}` : host.address,
      action: cardAction({ icon: "edit-outlined", tooltip: "Edit host", onClick: () => openHostEditor(host) }),
      onClick: (event) => onTap(key, event, () => openHostEditor(host)),
      onDoubleClick: () => app.connect(host),
      onMenu: (x, y) => hostMenu(host, x, y),
    });
  }

  function groupCard(group, count) {
    const key = groupKey(group.id);
    return card({
      key,
      selected: isCardSelected(key),
      thickBorder: true,
      tile: tile("folder-outlined"),
      title: group.name,
      titleClass: "is-group",
      sub: h("span", { class: "card-sub is-count", text: count === 1 ? "1 host" : `${count} hosts` }),
      action: cardAction({ icon: "edit-outlined", tooltip: "Edit Group", onClick: () => openGroupEditor(group) }),
      onClick: (event) => onTap(key, event, null),
      onDoubleClick: () => openFolder(group.id),
      onMenu: (x, y) => groupMenu(group, x, y),
    });
  }

  function groupEmpty(group) {
    const empty = emptyState({
      icon: "folder-open-outlined",
      title: `"${group.name}" is empty`,
      message: "Add a host to this group to see it here.",
      action: button({ icon: "add", iconSize: 15, label: "New host in this group", size: "toolbar", onClick: () => openHostEditor(null, group.id) }),
    });
    empty.classList.add("group-empty");
    empty.querySelector(".empty-icon").replaceChildren(icon("folder-open-outlined", 26));
    return empty;
  }

  function openFolder(groupId) {
    openGroupId = groupId;
    selectedId = null;
    multi.clear();
    render();
  }

  function hostMenu(host, x, y) {
    const items = multi.has(hostKey(host.id))
      ? [
          selectedHostIds().size > 0 && { icon: "play-arrow-outlined", label: "Connect selection", onSelect: connectSelection },
          { icon: "delete-outline", label: "Delete selection", danger: true, onSelect: deleteSelection },
        ]
      : [
          { icon: "play-arrow-outlined", label: "Connect", onSelect: () => app.connect(host) },
          { icon: "edit-outlined", label: "Edit", onSelect: () => openHostEditor(host) },
          { icon: "content-copy-outlined", label: "Duplicate", onSelect: () => duplicateHost(host) },
          { icon: "delete-outline", label: "Delete", danger: true, onSelect: () => deleteHost(host) },
        ];
    showMenu({ x, y, items });
  }

  function groupMenu(group, x, y) {
    const items = multi.has(groupKey(group.id))
      ? [
          selectedHostIds().size > 0 && { icon: "play-arrow-outlined", label: "Connect selection", onSelect: connectSelection },
          { icon: "delete-outline", label: "Delete selection", danger: true, onSelect: deleteSelection },
        ]
      : [
          {
            icon: "play-arrow-outlined",
            label: "Connect to all hosts",
            onSelect: () => {
              selectedId = group.id;
              multi.clear();
              refreshSelection();
              connectHosts(store.data().hosts.filter((h) => h.groupId === group.id));
            },
          },
          { icon: "folder-open-outlined", label: "Open", onSelect: () => openFolder(group.id) },
          { icon: "edit-outlined", label: "Rename", onSelect: () => openGroupEditor(group) },
          { icon: "delete-outline", label: "Delete", danger: true, onSelect: () => deleteGroup(group) },
        ];
    showMenu({ x, y, items });
  }

  function duplicateHost(host) {
    app.save((data) => {
      data.hosts.push({
        ...NEW_HOST,
        id: uuid(),
        name: `${host.name} (copy)`,
        address: host.address,
        username: host.username,
        port: host.port,
        authType: host.authType,
        keyId: host.keyId,
        encryptedPassword: host.encryptedPassword,
        groupId: host.groupId,
        tags: host.tags,
        color: host.color,
        notes: host.notes,
      });
    });
  }

  async function deleteHost(host) {
    const confirmed = await confirmDialog({ title: "Delete host?", message: `Delete "${host.name}"? This cannot be undone.` });
    if (!confirmed) return;
    app.save((data) => {
      data.hosts = data.hosts.filter((h) => h.id !== host.id);
    });
  }

  async function deleteGroup(group) {
    const choice = await openDialog({
      title: "Delete group?",
      content: `What should happen to hosts inside "${group.name}"?`,
      actions: [
        { label: "Cancel", variant: "outlined", className: "btn-dense-text", value: null },
        { label: "Delete, keep hosts", variant: "filled", className: "btn-dense-text", value: "keep" },
        { label: "Delete with hosts", variant: "filled", danger: true, className: "btn-dense-text", value: "all" },
      ],
    });
    if (!choice) return;
    await app.save((data) => {
      if (choice === "all") data.hosts = data.hosts.filter((h) => h.groupId !== group.id);
      data.groups = data.groups.filter((g) => g.id !== group.id);
    });
    if (openGroupId === group.id) openFolder(null);
  }

  async function deleteSelection() {
    const hostIds = [...multi].filter((k) => k.startsWith("h:")).map((k) => k.slice(2));
    const groupIds = [...multi].filter((k) => k.startsWith("g:")).map((k) => k.slice(2));
    if (hostIds.length === 0 && groupIds.length === 0) return;
    const confirmed = await confirmDialog({
      title: "Delete selection?",
      message:
        groupIds.length === 0
          ? `Delete ${hostIds.length} host(s)? This cannot be undone.`
          : `Delete ${groupIds.length} group(s) and ${hostIds.length} host(s)? Hosts in groups stay, but lose their group. This cannot be undone.`,
    });
    if (!confirmed) return;
    await app.save((data) => {
      data.hosts = data.hosts.filter((h) => !hostIds.includes(h.id));
      data.groups = data.groups.filter((g) => !groupIds.includes(g.id));
    });
    if (groupIds.includes(openGroupId)) openGroupId = null;
    multi.clear();
    render();
  }

  function openHostEditor(host, groupId = null) {
    panel?.close();
    panel = openPanel(el, {
      width: 320,
      build: (p) => hostForm(app, p, host, groupId),
      onClose: () => {
        panel = null;
      },
    });
    panel.target = host ? { table: "hosts", id: host.id } : null;
  }

  function openGroupEditor(group) {
    panel?.close();
    panel = openPanel(el, {
      width: 320,
      build: (p) => groupForm(app, p, group),
      onClose: () => {
        panel = null;
      },
    });
    panel.target = group ? { table: "groups", id: group.id } : null;
  }

  return {
    el,
    update() {
      render();
      const target = panel?.target;
      if (target && !store.data()[target.table].some((row) => row.id === target.id)) {
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
      const key = hover.key;
      if (!key) return false;
      const id = key.slice(2);
      if (key.startsWith("h:")) {
        const host = store.data().hosts.find((h) => h.id === id);
        if (host) openHostEditor(host);
        return Boolean(host);
      }
      const group = store.data().groups.find((g) => g.id === id);
      if (group) openGroupEditor(group);
      return Boolean(group);
    },
  };
}

function credentialFields({ editing, authType, keyId, onKey, onChange, withSaveToggle, onSaveToggle }) {
  const password = textField({ label: editing ? "Password (leave blank to keep)" : "Password", reveal: true, onInput: onChange });
  const saveToggle = withSaveToggle && editing ? checkboxTile({ label: "Save password with host", checked: true, onChange: onSaveToggle }) : null;
  const identities = store.data().identities;
  const keySelect = keySelectField({ value: keyId, identities, onChange: onKey });
  const box = h("div", { class: "stack" });

  const render = (type) => {
    if (type === "password") {
      box.replaceChildren(password.el, saveToggle ? saveToggle.el : "");
    } else if (type === "key") {
      box.replaceChildren(
        keySelect.el,
        identities.length === 0 ? h("div", { class: "panel-warning", text: "No keys imported yet. Add one in the Keys section." }) : "",
      );
    } else {
      box.replaceChildren(
        h(
          "div",
          { class: "inherit-note" },
          icon("folder-copy-outlined", 15),
          h("span", { class: "inherit-note-text", text: "Uses the group credentials. If the group has none, you will be asked when connecting." }),
        ),
      );
    }
  };
  render(authType);
  return { box, password, keySelect, render };
}

function hostForm(app, panel, host, initialGroupId) {
  const editing = Boolean(host);
  const id = host?.id ?? uuid();
  const data = store.data();
  let authType = host?.authType ?? "password";
  let keyId = host?.keyId ?? null;
  let groupId = host?.groupId ?? initialGroupId ?? null;
  let savePassword = true;
  let initializing = !editing;
  let timer = 0;

  const defaultsFrom = !editing && groupId ? data.groups.find((g) => g.id === groupId) : null;
  if (defaultsFrom) {
    authType = defaultsFrom.authType || "password";
    if (authType === "key") keyId = defaultsFrom.keyId;
  }

  const status = h("div", { class: "panel-status" });
  const setStatus = (state) => {
    status.replaceChildren(
      ...(state === "saving"
        ? [h("div", { class: "spinner is-small" })]
        : state === "saved"
          ? [icon("check-circle-outline", 13), h("span", { text: "Saved" })]
          : []),
    );
  };

  const changed = () => {
    if (initializing) return;
    setStatus("saving");
    clearTimeout(timer);
    timer = setTimeout(saveNow, 700);
  };

  const address = textField({ label: "Address", hint: "e.g. 192.168.1.10 or host.example.com", value: host?.address, onInput: changed });
  const port = textField({ label: "Port", value: String(host?.port ?? 22), inputMode: "numeric", onInput: changed });
  const name = textField({ label: "Name", hint: "Leave blank to use the address", value: host?.name, onInput: changed });
  const group = selectField({
    label: "Group",
    icon: "folder-outlined",
    value: groupId,
    searchable: data.groups.length >= 8,
    options: [{ value: null, label: "Ungrouped" }, ...data.groups.map((g) => ({ value: g.id, label: g.name }))],
    onChange: (value) => {
      groupId = value;
      changed();
    },
  });
  const tags = textField({ label: "Tags (comma separated)", value: host?.tags, onInput: changed });
  const username = textField({ label: "Username", value: host?.username ?? defaultsFrom?.username ?? "", onInput: changed });
  const credentials = credentialFields({
    editing,
    authType,
    keyId,
    withSaveToggle: true,
    onChange: changed,
    onKey: (value) => {
      keyId = value;
      changed();
    },
    onSaveToggle: (value) => {
      savePassword = value;
      changed();
    },
  });
  const auth = segmented({
    options: AUTH_OPTIONS,
    value: authType,
    onChange: (value) => {
      authType = value;
      credentials.render(value);
      changed();
    },
  });

  async function saveNow() {
    clearTimeout(timer);
    const addressValue = address.value.trim();
    const effectiveName = name.value.trim() || addressValue;
    if (!effectiveName && !addressValue) {
      setStatus(null);
      return;
    }
    const password = credentials.password.value.trim();
    const ok = await app.save(async (d) => {
      const existing = d.hosts.find((row) => row.id === id);
      let encryptedPassword = existing?.encryptedPassword ?? null;
      if (authType === "password") {
        if (password) encryptedPassword = await store.vault.encrypt(password, d);
        else if (!existing && savePassword) encryptedPassword = await store.vault.encrypt("", d);
      }
      const fields = {
        id,
        name: effectiveName,
        address: addressValue,
        port: parseInt(port.value, 10) || 22,
        username: authType === "" ? "" : username.value.trim(),
        authType,
        keyId: authType === "key" ? keyId : null,
        encryptedPassword: authType === "password" && savePassword ? encryptedPassword : null,
        groupId,
        tags: tags.value.trim(),
      };
      if (existing) Object.assign(existing, fields);
      else d.hosts.push({ ...NEW_HOST, ...fields });
    });
    if (!panel.closed) setStatus(ok ? "saved" : null);
  }

  if (defaultsFrom) {
    const finish = () => {
      initializing = false;
      changed();
    };
    if (authType === "password" && defaultsFrom.encryptedPassword) {
      store.vault.decrypt(defaultsFrom.encryptedPassword).then((value) => {
        if (value != null) credentials.password.value = value;
        finish();
      });
    } else {
      finish();
    }
  } else {
    initializing = false;
  }

  return panelLayout({
    children: [
      panelHeader({ title: editing ? "Edit host" : "New host", status, onClose: () => panel.close() }),
      sectionCard("lan-outlined", "ADDRESS", [address.el, gap(10), port.el]),
      sectionCard("folder-outlined", "GENERAL", [name.el, gap(10), group.el, gap(10), tags.el]),
      sectionCard("lock-outline", "CONNECTION", [username.el, gap(12), auth.el, gap(12), credentials.box]),
    ],
    footer: button({
      icon: "play-arrow",
      label: "Connect",
      block: true,
      className: "btn-h32",
      onClick: async () => {
        await saveNow();
        const saved = store.data().hosts.find((h) => h.id === id);
        if (!saved) return;
        panel.close();
        app.connect(saved);
      },
    }),
  });
}

function groupForm(app, panel, group) {
  const editing = Boolean(group);
  let authType = group?.authType || "password";
  let keyId = group?.keyId ?? null;

  const name = textField({ label: "Group name", value: group?.name, onInput: () => name.setError(null) });
  const username = textField({ label: "Username", value: group?.username ?? "" });
  const credentials = credentialFields({
    editing,
    authType,
    keyId,
    onKey: (value) => {
      keyId = value;
    },
  });
  const auth = segmented({
    options: AUTH_OPTIONS,
    value: authType,
    onChange: (value) => {
      authType = value;
      credentials.render(value);
    },
  });

  async function save() {
    let valid = true;
    if (!name.value.trim()) {
      name.setError("Name is required");
      valid = false;
    }
    if (authType === "key" && !keyId) {
      credentials.keySelect.setError("Select a key");
      valid = false;
    }
    if (!valid) return;

    const password = credentials.password.value.trim();
    const id = group?.id ?? uuid();
    const ok = await app.save(async (d) => {
      const existing = d.groups.find((row) => row.id === id);
      let encryptedPassword = null;
      if (authType === "password") {
        if (password) encryptedPassword = await store.vault.encrypt(password, d);
        else if (existing?.encryptedPassword) encryptedPassword = existing.encryptedPassword;
      }
      const fields = {
        id,
        name: name.value.trim(),
        username: username.value.trim() || null,
        authType,
        keyId: authType === "key" ? keyId : null,
        encryptedPassword,
      };
      if (existing) Object.assign(existing, fields);
      else d.groups.push({ ...NEW_GROUP, ...fields });
    });
    if (ok) panel.close();
  }

  return panelLayout({
    children: [
      panelHeader({ title: editing ? "Edit group" : "New group", onClose: () => panel.close() }),
      sectionCard("folder-outlined", "GENERAL", [name.el]),
      sectionCard("lock-outline", "GROUP CREDENTIALS", [
        h("div", { class: "panel-help", text: "Used by hosts that do not define their own credentials." }),
        gap(12),
        username.el,
        gap(12),
        auth.el,
        gap(12),
        credentials.box,
      ]),
    ],
    footer: button({ icon: "check", label: "Save group", block: true, className: "btn-h32", onClick: save }),
  });
}
