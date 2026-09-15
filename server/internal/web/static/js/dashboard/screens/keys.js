import { isEncryptedPrivateKey, generateSshKey, publicKeyFromPrivate } from "../crypto.js";
import { fmt, h, icon, uuid } from "../dom.js";
import { enableBandSelection } from "../selection.js";
import * as store from "../store.js";
import {
  button, cardAction, confirmDialog, emptyState, iconButton, noResults, openDialog, openPanel, panelHeader,
  panelLayout, segmented, showMenu, snackbar, switchTile, textField,
} from "../ui.js";
import { card, gap, grid, markSelected, modKey, replaceKeepingScroll, searchBox, tile, trackHover } from "./common.js";

const KEY_TYPES = [
  { value: "ED25519", label: "ED25519", info: "OpenSSH 6.5+" },
  { value: "ECDSA", label: "ECDSA", info: "OpenSSH 5.7+" },
  { value: "RSA", label: "RSA", info: "Legacy devices" },
  { value: "ML-DSA", label: "ML-DSA", info: "Supported only on ML-DSA-enabled servers" },
];

const CIPHERS = [
  { value: "aes256-ctr", label: "AES-256" },
  { value: "aes128-ctr", label: "AES-128" },
  { value: "3des-cbc", label: "3DES" },
  { value: "des-cbc", label: "DES" },
];

export function createKeysScreen(app) {
  let query = "";
  let visible = false;
  let panel = null;
  const multi = new Set();
  const lockState = new Map();

  const search = searchBox("Search keys...", (value) => {
    query = value;
    render();
  });
  const toolbar = h(
    "div",
    { class: "toolbar" },
    search.el,
    h(
      "div",
      { class: "toolbar-actions is-wide" },
      button({ icon: "vpn-key-outlined", label: "New Key", size: "toolbar", onClick: () => openKeyForm(null) }),
      button({ variant: "outlined", icon: "autorenew", label: "Generate Key", size: "toolbar", onClick: openGenerator }),
    ),
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
      actions: [{ icon: "delete-outline", label: "Delete", danger: true, onClick: deleteSelection }],
      onClose: () => {
        multi.clear();
        refreshSelection();
      },
    });
  }

  async function scanPassphrases() {
    let changed = false;
    for (const identity of store.data().identities) {
      const known = lockState.get(identity.id);
      if (known && known.ciphertext === identity.encryptedKeyPem) continue;
      const pem = await store.vault.decrypt(identity.encryptedKeyPem);
      const locked = pem ? isEncryptedPrivateKey(pem) : false;
      lockState.set(identity.id, { ciphertext: identity.encryptedKeyPem, locked });
      if (locked !== (known?.locked ?? false)) changed = true;
    }
    if (changed) render();
  }

  function render() {
    const identities = store.data().identities;
    const q = query.trim().toLowerCase();
    const filtered = q
      ? identities.filter((i) => [i.name, i.comment, i.publicKey].some((v) => (v || "").toLowerCase().includes(q)))
      : identities;

    let nodes;
    if (identities.length === 0) {
      nodes = [
        emptyState({
          icon: "vpn-key-outlined",
          title: "No keys yet",
          message: "Add an existing SSH key or generate a new one.",
          action: button({ icon: "vpn-key-outlined", label: "New Key", size: "toolbar", onClick: () => openKeyForm(null) }),
        }),
      ];
    } else if (filtered.length === 0) {
      nodes = [noResults("No keys match your search")];
    } else {
      nodes = [grid(filtered.map(keyCard), { rowHeight: 60, padding: "top" })];
    }
    replaceKeepingScroll(scroll, nodes);
    syncSelectionBar();
  }

  function keyCard(identity) {
    return card({
      key: identity.id,
      selected: multi.has(identity.id),
      tile: tile("vpn-key"),
      title: identity.name,
      extras: lockState.get(identity.id)?.locked && icon("lock", 12, "card-lock"),
      sub: identity.comment || fmt.day(identity.createdAt),
      action: cardAction({ icon: "edit-outlined", size: 14, tooltip: "Edit key", onClick: () => openKeyForm(identity) }),
      onClick: (event) => {
        if (modKey(event)) {
          if (multi.has(identity.id)) multi.delete(identity.id);
          else multi.add(identity.id);
          refreshSelection();
          return;
        }
        if (multi.size > 0) {
          multi.clear();
          refreshSelection();
        }
        openKeyForm(identity);
      },
      onMenu: (x, y) =>
        showMenu({
          x,
          y,
          items: [
            { icon: "edit-outlined", label: "Edit", onSelect: () => openKeyForm(identity) },
            { icon: "lock-outline", label: "Set passphrase", onSelect: () => setPassphrase(identity) },
            { icon: "delete-outline", label: "Delete", danger: true, onSelect: () => deleteKey(identity) },
          ],
        }),
    });
  }

  async function setPassphrase(identity) {
    const field = textField({ label: "Passphrase", type: "password", autofocus: true });
    const confirmed = await openDialog({
      title: "Set passphrase",
      content: field.el,
      actions: [
        { label: "Cancel", value: false },
        { label: "Save", variant: "filled", value: true },
      ],
    });
    if (!confirmed) return;
    const passphrase = field.value;
    app.save(async (d) => {
      const row = d.identities.find((i) => i.id === identity.id);
      if (row) row.encryptedPassphrase = await store.vault.encrypt(passphrase, d);
    });
  }

  async function deleteKey(identity) {
    const confirmed = await confirmDialog({ title: "Delete key?", message: `Delete "${identity.name}"?` });
    if (!confirmed) return;
    await app.save((d) => {
      d.identities = d.identities.filter((i) => i.id !== identity.id);
    });
  }

  async function deleteSelection() {
    const ids = [...multi];
    if (ids.length === 0) return;
    const confirmed = await confirmDialog({ title: "Delete keys?", message: `Delete ${ids.length} key(s)? This cannot be undone.` });
    if (!confirmed) return;
    await app.save((d) => {
      d.identities = d.identities.filter((i) => !ids.includes(i.id));
    });
    multi.clear();
    render();
  }

  function openKeyForm(identity) {
    panel?.close();
    panel = openPanel(el, {
      width: 320,
      build: (p) => keyForm(app, p, identity, () => deleteKey(identity)),
      onClose: () => {
        panel = null;
      },
    });
    panel.targetId = identity?.id ?? null;
  }

  function openGenerator() {
    panel?.close();
    panel = openPanel(el, {
      width: 320,
      build: (p) =>
        generateForm(app, p, (id) => {
          const identity = store.data().identities.find((i) => i.id === id);
          openKeyForm(identity);
        }),
      onClose: () => {
        panel = null;
      },
    });
  }

  return {
    el,
    update() {
      render();
      scanPassphrases();
      if (panel?.targetId && !store.data().identities.some((i) => i.id === panel.targetId)) {
        panel.close();
      }
    },
    show() {
      visible = true;
      render();
      scanPassphrases();
    },
    hide() {
      visible = false;
      multi.clear();
    },
    editHovered() {
      const identity = store.data().identities.find((i) => i.id === hover.key);
      if (identity) openKeyForm(identity);
      return Boolean(identity);
    },
  };
}

function sectionLabel(text) {
  return h("div", { class: "panel-label", text });
}

function keyForm(app, panel, identity, onDelete) {
  const editing = Boolean(identity);
  const id = identity?.id ?? uuid();

  const label = textField({ label: "Label", hint: "e.g. My Production Key", value: identity?.name });
  const privateKey = textField({
    label: "Private key *",
    hint: "Paste the OpenSSH private key (-----BEGIN ...)",
    multiline: true,
    rows: 10,
    mono: true,
    onInput: () => privateKey.setError(null),
  });
  const publicKey = textField({ label: "Public key", hint: "ssh-ed25519 AAAA... or leave empty", multiline: true, rows: 4, mono: true, value: identity?.publicKey });
  const certificate = textField({ label: "Certificate", multiline: true, rows: 4, mono: true, value: identity?.certificate });
  const passphrase = textField({
    label: "Passphrase (optional)",
    hint: "Leave empty to keep the current one",
    reveal: "passphrase",
    helper: identity?.encryptedPassphrase != null ? "A passphrase is currently set. Empty keeps it." : "Protects the private key when connecting.",
  });

  const loadText = (text) => {
    privateKey.value = text;
    privateKey.setError(null);
    if (!publicKey.value.trim()) publicKey.value = publicKeyFromPrivate(text) ?? "";
  };
  const readFile = (file) => {
    file.text().then(loadText, (err) => snackbar(`Could not read file: ${err.message}`));
  };

  const fileInput = h("input", { type: "file", hidden: true });
  fileInput.addEventListener("change", () => {
    if (fileInput.files[0]) readFile(fileInput.files[0]);
    fileInput.value = "";
  });

  const dropText = h("div", { class: "drop-area-text", text: "Drag and drop a private key file to import" });
  const dropIcon = icon("file-download-outlined", 26);
  const drop = h("div", { class: "drop-area" }, dropIcon, dropText);
  drop.addEventListener("dragover", (event) => {
    event.preventDefault();
    drop.classList.add("is-dragging");
  });
  drop.addEventListener("dragleave", () => drop.classList.remove("is-dragging"));
  drop.addEventListener("drop", (event) => {
    event.preventDefault();
    drop.classList.remove("is-dragging");
    const file = event.dataTransfer.files[0];
    if (file) readFile(file);
  });

  const footer = h("div", { class: "panel-footer is-loading" }, h("div", { class: "spinner" }));
  const saveButton = button({ icon: "check", label: "Save key", block: true, className: "btn-h36", onClick: save });
  const showSaveButton = () => {
    footer.className = "panel-footer";
    footer.replaceChildren(saveButton);
  };

  if (editing) {
    store.vault.decrypt(identity.encryptedKeyPem).then((pem) => {
      if (pem != null) privateKey.value = pem;
      showSaveButton();
    });
  } else {
    showSaveButton();
  }

  async function save() {
    const pem = privateKey.value.trim();
    if (!pem) {
      privateKey.setError("Private key is required");
      return;
    }
    const secret = passphrase.value;
    const ok = await app.save(async (d) => {
      const existing = d.identities.find((i) => i.id === id);
      const fields = {
        id,
        name: label.value.trim() || "SSH key",
        encryptedKeyPem: await store.vault.encrypt(pem, d),
        publicKey: publicKey.value.trim(),
        certificate: certificate.value.trim(),
      };
      if (secret) fields.encryptedPassphrase = await store.vault.encrypt(secret, d);
      else if (existing?.encryptedPassphrase == null) fields.encryptedPassphrase = null;
      if (existing) Object.assign(existing, fields);
      else d.identities.push({ comment: "", createdAt: new Date().toISOString(), workspaceId: null, ...fields });
    });
    if (ok) panel.close();
  }

  const layout = panelLayout({
    children: [
      panelHeader({
        title: editing ? "Edit key" : "New key",
        subtitle: editing ? identity.comment || null : "Enter a private key manually or import one from a file.",
        onClose: () => panel.close(),
        actions: editing ? [iconButton({ icon: "delete-outline", size: 19, tooltip: "Delete key", onClick: onDelete })] : [],
      }),
      sectionLabel("KEY FIELDS"),
      label.el,
      gap(12),
      privateKey.el,
      gap(12),
      publicKey.el,
      gap(12),
      certificate.el,
      sectionLabel("PASSPHRASE"),
      passphrase.el,
      sectionLabel("KEY FILE IMPORT"),
      drop,
      gap(10),
      button({ variant: "outlined", icon: "upload-file", label: "Import from key file", block: true, className: "btn-h36", onClick: () => fileInput.click() }),
      fileInput,
    ],
  });
  layout.append(footer);
  return layout;
}

function generateForm(app, panel, onGenerated) {
  let type = "ED25519";
  let curve = 521;
  let rsaBits = 4096;
  let cipher = "aes256-ctr";
  let generating = false;

  const label = textField({ label: "Label (optional)", hint: "e.g. My Production Key" });
  const rounds = textField({ label: "Rounds", value: "100", inputMode: "numeric", onInput: () => rounds.setError(null) });
  const passphrase = textField({ label: "Passphrase", hint: "Leave empty for no passphrase", reveal: true });
  const savePassphrase = switchTile({
    title: "Save passphrase",
    subtitle: "Store the passphrase with the key so you are not prompted for it when connecting.",
    checked: true,
    className: "is-dense",
  });

  const infoText = h("span", { class: "info-note-text" });
  const options = h("div", { class: "stack" });
  const caption = (text) => h("div", { class: "panel-caption", text });

  const renderType = () => {
    infoText.textContent = KEY_TYPES.find((t) => t.value === type).info;
    if (type === "ED25519") {
      options.replaceChildren(
        rounds.el,
        gap(6),
        h("div", {
          class: "panel-help",
          text: "Number of KDF rounds when saving ED25519 key. Higher numbers can increase protection of the private key but slower passphrase verification.",
        }),
      );
    } else if (type === "ECDSA") {
      options.replaceChildren(
        caption("ELLIPTIC CURVE SIZE"),
        gap(6),
        segmented({ small: true, options: [521, 384, 256].map((v) => ({ value: v, label: String(v) })), value: curve, onChange: (v) => (curve = v) }).el,
      );
    } else if (type === "RSA") {
      options.replaceChildren(
        caption("KEY SIZE"),
        gap(6),
        segmented({ small: true, options: [4096, 2048, 1024].map((v) => ({ value: v, label: String(v) })), value: rsaBits, onChange: (v) => (rsaBits = v) }).el,
      );
    } else {
      options.replaceChildren(caption("PARAMETER SET"), gap(6), segmented({ small: true, options: [87, 65, 44].map((v) => ({ value: v, label: String(v) })), value: 87 }).el);
    }
  };
  renderType();

  const typeControl = segmented({
    small: true,
    options: KEY_TYPES,
    value: type,
    onChange: (value) => {
      type = value;
      renderType();
    },
  });

  const generateButton = button({ icon: "vpn-key-outlined", label: "Generate & save", block: true, className: "btn-h36", onClick: generate });

  async function generate() {
    if (generating) return;
    if (type === "ED25519") {
      const n = parseInt(rounds.value.trim(), 10);
      if (!(n >= 1)) {
        rounds.setError("Enter a valid round count");
        return;
      }
    }
    if (type === "ML-DSA") {
      snackbar("ML-DSA keys require OpenSSH 9.9 or newer, which the browser can't run. Generate them in the Connexia app.");
      return;
    }
    if (passphrase.value) {
      snackbar("Passphrase-protected keys are generated by ssh-keygen in the Connexia app. Leave the passphrase empty to generate the key here.");
      return;
    }

    generating = true;
    generateButton.disabled = true;
    generateButton.replaceChildren(h("div", { class: "spinner is-small" }), h("span", { class: "btn-label", text: "Generate & save" }));
    try {
      const comment = label.value.trim() || "connexia";
      const generated = await generateSshKey({ type, bits: type === "ECDSA" ? curve : rsaBits, comment });
      const id = uuid();
      const ok = await app.save(async (d) => {
        d.identities.push({
          id,
          name: label.value.trim() || `${type} key`,
          encryptedKeyPem: await store.vault.encrypt(generated.privatePem, d),
          encryptedPassphrase: null,
          comment: `${type} (generated)`,
          publicKey: generated.publicKey,
          certificate: "",
          createdAt: new Date().toISOString(),
          workspaceId: null,
        });
      });
      if (ok) onGenerated(id);
    } catch (err) {
      snackbar(err.name === "NotSupportedError" ? `This browser can't generate ${type} keys.` : `Could not generate key: ${err.message}`);
    } finally {
      generating = false;
      generateButton.disabled = false;
      generateButton.replaceChildren(icon("vpn-key-outlined", 16), h("span", { class: "btn-label", text: "Generate & save" }));
    }
  }

  return panelLayout({
    children: [
      panelHeader({ title: "Create SSH key", subtitle: "Generate a new key pair inside Connexia.", onClose: () => panel.close() }),
      sectionLabel("KEY CONFIGURATION"),
      label.el,
      gap(12),
      typeControl.el,
      gap(10),
      h("div", { class: "info-note" }, icon("info-outline", 15), infoText),
      gap(12),
      options,
      sectionLabel("PASSPHRASE & ENCRYPTION"),
      passphrase.el,
      gap(12),
      caption("CIPHER"),
      gap(6),
      segmented({ small: true, options: CIPHERS, value: cipher, onChange: (v) => (cipher = v) }).el,
      gap(4),
      savePassphrase.el,
    ],
    footer: generateButton,
  });
}
