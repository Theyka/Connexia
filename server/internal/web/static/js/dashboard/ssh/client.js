import { sessionToken } from "../api.js";
import { h, icon } from "../dom.js";
import * as store from "../store.js";
import { openDialog, textField } from "../ui.js";
import { loadSSH } from "./runtime.js";

export function relayUrl(address, port) {
  const scheme = location.protocol === "https:" ? "wss" : "ws";
  return `${scheme}://${location.host}/api/relay?host=${encodeURIComponent(address)}&port=${port}`;
}

export async function resolveAuth(host) {
  const data = store.data();
  const group = host.groupId ? data.groups.find((g) => g.id === host.groupId) : null;
  const auth = {
    username: host.username || group?.username || "",
    authType: host.authType || group?.authType || "",
    password: null,
    privateKey: null,
    passphrase: null,
    missing: null,
    fatal: false,
  };
  if (!auth.username) {
    auth.missing = "No saved sign-in for this host";
    return auth;
  }
  if (auth.authType === "key") {
    const keyId = host.keyId ?? group?.keyId;
    if (!keyId) {
      auth.missing = "This host has no identity configured";
      return auth;
    }
    const identity = data.identities.find((i) => i.id === keyId);
    if (!identity) {
      auth.missing = "Identity not found";
      auth.fatal = true;
      return auth;
    }
    try {
      auth.privateKey = await store.vault.decrypt(identity.encryptedKeyPem);
      if (identity.encryptedPassphrase) auth.passphrase = await store.vault.decrypt(identity.encryptedPassphrase);
    } catch (err) {
      auth.missing = `Vault error: ${err.message}`;
      auth.fatal = true;
    }
    return auth;
  }
  const encrypted = host.encryptedPassword ?? group?.encryptedPassword;
  if (!encrypted) {
    auth.missing = "No saved password for this host";
    return auth;
  }
  try {
    auth.password = await store.vault.decrypt(encrypted);
  } catch {
    auth.missing = "Cannot read the saved password (vault error)";
  }
  return auth;
}

const isRsa = (type) => type === "ssh-rsa" || type.startsWith("rsa-sha2");

export function checkHostKey(address, port, wireType, fingerprint) {
  const keyType = wireType === "ssh-rsa" ? "rsa-sha2-512" : wireType;
  const known = store.data().knownHosts.find((k) => k.hostKey === `${address}:${port}`);
  if (!known) return { status: "unknown", keyType };
  const sameType = known.keyType === keyType || (isRsa(known.keyType) && isRsa(keyType));
  if (sameType && known.fingerprint === fingerprint) return { status: "trusted", keyType };
  return {
    status: "changed",
    keyType,
    message: `Host key for ${address}:${port} changed!\nExpected: ${known.keyType} ${known.fingerprint}\nReceived: ${keyType} ${fingerprint}`,
  };
}

export function autoAcceptHostKeys() {
  return store.setting("autoAcceptHostKeys", "false") === "true";
}

export function trustHostKey(app, address, port, keyType, fingerprint) {
  const hostKey = `${address}:${port}`;
  const now = new Date().toISOString();
  return app.save((d) => {
    const existing = d.knownHosts.find((k) => k.hostKey === hostKey);
    if (existing) Object.assign(existing, { keyType, fingerprint, lastSeen: now });
    else d.knownHosts.push({ hostKey, keyType, fingerprint, firstSeen: now, lastSeen: now });
  });
}

export function askAnswers(label, name, instruction, questions, echos) {
  let continueButton = null;
  const fields = questions.map((question, i) =>
    textField({
      label: question.replace(/:\s*$/, ""),
      type: echos[i] ? "text" : "password",
      autofocus: i === 0,
      onEnter: () => continueButton?.click(),
    }),
  );
  return openDialog({
    title: name || `Sign in to ${label}`,
    className: "prompt-dialog",
    content: h(
      "div",
      { class: "stack" },
      instruction && h("div", { class: "prompt-text", text: instruction }),
      fields.map((field, i) => [i > 0 && h("div", { class: "sp-10" }), field.el]),
    ),
    actions: [
      { label: "Cancel", value: null },
      {
        label: "Continue",
        variant: "filled",
        ref: (node) => (continueButton = node),
        onClick: (close) => close(fields.map((field) => field.value)),
      },
    ],
  }).then((answers) => answers ?? null);
}

export function promptCredentials(host, { message = "No saved credentials for this host. Enter them to connect.", confirmLabel = "Connect" } = {}) {
  let connectButton = null;
  const username = textField({ label: "Username", value: host.username || "", autofocus: !host.username });
  const password = textField({ label: "Password", type: "password", autofocus: Boolean(host.username), onEnter: () => connectButton?.click() });
  return openDialog({
    title: h("div", { class: "prompt-title" }, icon("lock-outline", 24, "prompt-icon"), h("span", { text: `Credentials for ${host.name}` })),
    className: "prompt-dialog",
    content: h(
      "div",
      { class: "stack" },
      h("div", { class: "prompt-text", text: message }),
      h("div", { class: "sp-12" }),
      username.el,
      h("div", { class: "sp-10" }),
      password.el,
    ),
    actions: [
      { label: "Cancel", value: null },
      {
        label: confirmLabel,
        variant: "filled",
        ref: (node) => (connectButton = node),
        onClick: (close) => {
          if (!username.value.trim()) return;
          close({ username: username.value.trim(), password: password.value });
        },
      },
    ],
  });
}

export async function openClient({ address, port, auth, verifyHostKey, prompt, onClose }) {
  const ssh = await loadSSH();
  return ssh.connect({
    url: relayUrl(address, port),
    protocols: ["connexia-relay", "token." + sessionToken()],
    username: auth.username,
    password: auth.password || "",
    privateKey: auth.privateKey || "",
    passphrase: auth.passphrase || "",
    shell: false,
    verifyHostKey,
    prompt,
    onClose,
  });
}

export function withTimeout(promise, ms, onTimeout) {
  let timer = 0;
  return Promise.race([
    promise.finally(() => clearTimeout(timer)),
    new Promise((_, reject) => {
      timer = setTimeout(() => {
        onTimeout?.();
        reject(new Error("Timed out"));
      }, ms);
    }),
  ]);
}

function parseOs(output) {
  const upper = output.toUpperCase();
  if (["MINGW", "CYGWIN", "MSYS", "MICROSOFT WINDOWS"].some((word) => upper.includes(word))) return "Windows";
  if (upper.includes("DARWIN")) return "macOS";
  if (upper.includes("FREEBSD")) return "FreeBSD";
  if (upper.includes("OPENBSD")) return "OpenBSD";
  if (upper.includes("NETBSD")) return "NetBSD";
  if (upper.includes("SUNOS")) return "Solaris";
  if (upper.includes("LINUX")) {
    const pretty = /PRETTY_NAME="?([^"\n]+)"?/.exec(output);
    if (pretty) return pretty[1];
    const id = /^ID="?([a-z]+)"?/m.exec(output);
    if (id) return id[1][0].toUpperCase() + id[1].slice(1);
    return "Linux";
  }
  return null;
}

export async function detectOs(app, handle, { hostId, address, port }) {
  try {
    let { output } = await handle.exec("uname -s; uname -m; cat /etc/os-release 2>/dev/null");
    if (!output.trim()) ({ output } = await handle.exec("ver"));
    const os = parseOs(output);
    if (!os) return null;
    const find = (d) => d.hosts.find((host) => host.id === hostId) || d.hosts.find((host) => host.address === address && Number(host.port) === port);
    const host = find(store.data());
    if (host && host.os !== os) {
      app.save((d) => {
        const target = find(d);
        if (target) target.os = os;
      });
    }
    return os;
  } catch {
    return null;
  }
}

export function markConnected(app, hostId) {
  const now = new Date().toISOString();
  return app.save((d) => {
    const host = d.hosts.find((entry) => entry.id === hostId);
    if (host) host.lastConnected = now;
  });
}
