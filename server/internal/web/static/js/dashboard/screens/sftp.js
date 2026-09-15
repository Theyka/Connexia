import { h, icon } from "../dom.js";
import { askAnswers, autoAcceptHostKeys, checkHostKey, detectOs, markConnected, openClient, promptCredentials, resolveAuth, trustHostKey } from "../ssh/client.js";
import * as store from "../store.js";
import { button, cardAction, confirmDialog, iconButton, openDialog, sectionHeader, showMenu, textField } from "../ui.js";
import { card, colorFromInt, grid, searchBox, tile } from "./common.js";

const DRAG_TYPE = "application/x-connexia-sftp";
const canOpenFolders = typeof window.showDirectoryPicker === "function";

const FILE_ICONS = {
  sh: "terminal", bash: "terminal",
  zip: "archive-outlined", tar: "archive-outlined", gz: "archive-outlined", bz2: "archive-outlined",
  png: "image-outlined", jpg: "image-outlined", jpeg: "image-outlined", gif: "image-outlined", svg: "image-outlined",
  md: "description-outlined", txt: "description-outlined", log: "description-outlined",
};

function fileIcon(name) {
  const dot = name.lastIndexOf(".");
  return (dot > 0 && FILE_ICONS[name.slice(dot + 1).toLowerCase()]) || "insert-drive-file-outlined";
}

function formatSize(bytes) {
  if (bytes == null || bytes < 0) return "";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

function normalizePath(path) {
  const parts = [];
  for (const part of path.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") parts.pop();
    else parts.push(part);
  }
  return "/" + parts.join("/");
}

const joinPath = (dir, name) => (dir === "/" ? "/" + name : `${dir}/${name}`);
const parentPath = (path) => normalizePath(path.slice(0, path.lastIndexOf("/")) || "/");
const byName = (a, b) => (a.isDir !== b.isDir ? (a.isDir ? -1 : 1) : a.name.toLowerCase().localeCompare(b.name.toLowerCase()));

function remoteState(name) {
  return {
    name,
    host: null,
    handle: null,
    sftp: null,
    connecting: false,
    error: null,
    path: "/",
    items: [],
    loading: false,
    listError: null,
    pickerOpen: false,
    groupId: null,
    query: "",
    search: null,
    pickerList: null,
    scroller: h("div", { class: "sftp-list" }),
    resetScroll: false,
  };
}

export function createSftpScreen(app) {
  const right = remoteState("right");
  const leftRemote = remoteState("leftRemote");
  const left = { isRemote: false, picker: false };
  const local = { stack: [], items: [], loading: false, error: null, scroller: h("div", { class: "sftp-list" }), resetScroll: false };
  const transfers = [];
  const errors = [];
  let dragging = null;

  const leftRoot = h("div", { class: "sftp-pane" });
  const rightRoot = h("div", { class: "sftp-pane" });
  const transfersBar = h("div", { class: "sftp-transfers" });
  const errorStack = h("div", { class: "sftp-errors" });
  const el = h(
    "section",
    { class: "screen sftp-screen" },
    h("div", { class: "sftp" }, h("div", { class: "sftp-panes" }, leftRoot, h("div", { class: "sftp-divider" }), rightRoot), transfersBar),
    errorStack,
  );

  function showError(message) {
    const existing = errors.find((entry) => entry.message === message);
    if (existing) clearTimeout(existing.timer);
    const entry = existing ?? { message };
    if (!existing) errors.push(entry);
    entry.timer = setTimeout(() => dismissError(entry), 6000);
    renderErrors();
  }

  function dismissError(entry) {
    clearTimeout(entry.timer);
    const index = errors.indexOf(entry);
    if (index >= 0) errors.splice(index, 1);
    renderErrors();
  }

  function renderErrors() {
    errorStack.replaceChildren(
      ...errors.map((entry) =>
        h(
          "div",
          { class: "sftp-error" },
          icon("error-outline", 16),
          h("span", { class: "sftp-error-text", text: entry.message }),
          h("button", { type: "button", class: "sftp-error-close", "aria-label": "Dismiss", onClick: () => dismissError(entry) }, icon("close", 16)),
        ),
      ),
    );
  }

  function beginTransfer(name, message, total = 0) {
    const task = { name, message, total, progress: 0, canceled: false, cancel: null, fill: null, lastTick: 0 };
    transfers.push(task);
    renderTransfers();
    return task;
  }

  function updateTransfer(task, bytes) {
    if (task.total <= 0) return;
    const now = Date.now();
    if (now - task.lastTick < 200) return;
    task.lastTick = now;
    task.progress = Math.min(1, Math.max(0, bytes / task.total));
    if (task.fill) {
      task.fill.classList.toggle("is-indeterminate", task.progress <= 0);
      task.fill.style.width = task.progress > 0 ? `${task.progress * 100}%` : "";
    }
  }

  function endTransfer(task) {
    const index = transfers.indexOf(task);
    if (index >= 0) transfers.splice(index, 1);
    renderTransfers();
  }

  function cancelTransfer(task) {
    if (task.canceled) return;
    task.canceled = true;
    task.cancel?.();
  }

  function renderTransfers() {
    transfersBar.hidden = transfers.length === 0;
    transfersBar.replaceChildren(
      ...transfers.map((task) => {
        const indeterminate = task.total <= 0 || task.progress <= 0;
        task.fill = h("div", { class: ["sftp-progress-fill", indeterminate && "is-indeterminate"], style: { width: indeterminate ? null : `${task.progress * 100}%` } });
        return h(
          "div",
          { class: "sftp-transfer" },
          h("span", { class: "sftp-transfer-name", text: `${task.name} — ${task.message}` }),
          h("div", { class: "sftp-progress" }, task.fill),
          h("button", { type: "button", class: "sftp-transfer-cancel", "data-tip": "Cancel", onClick: () => cancelTransfer(task) }, icon("close", 14)),
        );
      }),
    );
  }

  function promptText(title, label, initial = "") {
    let okButton = null;
    const field = textField({ label, value: initial, autofocus: true, onEnter: () => okButton?.click() });
    return openDialog({
      title,
      className: "sftp-prompt",
      content: field.el,
      actions: [
        { label: "Cancel", value: null },
        { label: "OK", variant: "filled", ref: (node) => (okButton = node), onClick: (close) => close(field.value.trim()) },
      ],
    }).then((value) => (value == null ? null : value));
  }

  async function verifyHostKey(host, address, port, wireType, fingerprint) {
    const check = checkHostKey(address, port, wireType, fingerprint);
    if (check.status === "trusted") return true;
    if (check.status === "changed") {
      showError(check.message);
      return check.message;
    }
    if (autoAcceptHostKeys()) {
      await trustHostKey(app, address, port, check.keyType, fingerprint);
      return true;
    }
    const accepted = await confirmDialog({
      title: "Verify host key",
      message: h("div", { class: "sftp-hostkey", text: `The authenticity of "${address}" cannot be established.\n\n${check.keyType} key fingerprint is:\n${fingerprint}\n\nConnect anyway?` }),
      confirmLabel: "Connect",
      danger: false,
    });
    if (!accepted) return "Connection cancelled: host key not trusted.";
    await trustHostKey(app, address, port, check.keyType, fingerprint);
    return true;
  }

  function resetSide(side) {
    const { sftp, handle } = side;
    Object.assign(side, { handle: null, sftp: null, host: null, connecting: false, error: null, path: "/", items: [], loading: false, listError: null });
    sftp?.close();
    handle?.close();
  }

  async function connectRemote(side, host) {
    if (app.account.webSSH === false) {
      showError("Web SSH is turned off on this server. An admin can turn it on in the admin page.");
      return;
    }
    resetSide(side);
    Object.assign(side, { host, connecting: true, error: null });
    if (side === leftRemote) Object.assign(left, { picker: false, isRemote: true });
    render();

    const stillWanted = () => side.host === host && side.connecting;
    try {
      let auth = await resolveAuth(host);
      if (!auth.username) {
        const entered = await promptCredentials(host);
        if (!entered) {
          if (!stillWanted()) return;
          resetSide(side);
          if (side === leftRemote) Object.assign(left, { picker: true, isRemote: false });
          else side.pickerOpen = true;
          render();
          return;
        }
        auth = { ...auth, username: entered.username, password: entered.password, privateKey: null, passphrase: null };
      } else if (auth.fatal) {
        throw new Error(auth.missing);
      }
      markConnected(app, host.id);
      const address = host.address;
      const port = parseInt(host.port, 10) || 22;
      let handle = null;
      handle = await openClient({
        address,
        port,
        auth,
        verifyHostKey: (wireType, fingerprint) => verifyHostKey(host, address, port, wireType, fingerprint),
        prompt: (name, instruction, questions, echos) => askAnswers(host.name, name, instruction, questions, echos),
        onClose: (reason) => {
          if (!handle || side.handle !== handle) return;
          showError(`Disconnected from ${host.name}${reason ? `: ${reason}` : ""}`);
          dropSide(side);
        },
      });
      if (!stillWanted()) {
        handle.close();
        return;
      }
      detectOs(app, handle, { hostId: host.id, address, port });
      const sftp = await handle.sftp();
      if (!stillWanted()) {
        handle.close();
        return;
      }
      Object.assign(side, { handle, sftp, connecting: false, path: "/", items: [], listError: null, resetScroll: true });
      render();
      await list(side);
    } catch (err) {
      if (!stillWanted()) return;
      side.connecting = false;
      side.error = err?.message || String(err);
      render();
    }
  }

  function dropSide(side) {
    resetSide(side);
    if (side === leftRemote) Object.assign(left, { isRemote: false, picker: false });
    render();
  }

  function disconnectRight() {
    for (const task of [...transfers]) cancelTransfer(task);
    for (const entry of [...errors]) dismissError(entry);
    dropSide(right);
  }

  async function list(side) {
    if (!side.sftp) return;
    const path = side.path;
    side.loading = true;
    side.listError = null;
    render();
    try {
      const entries = await side.sftp.list(path);
      if (side.path !== path) return;
      side.items = entries.sort(byName);
    } catch (err) {
      if (side.path !== path) return;
      side.listError = `Failed to list: ${err.message}`;
    }
    side.loading = false;
    render();
  }

  function navigate(side, path) {
    side.path = normalizePath(path);
    side.items = [];
    side.resetScroll = true;
    list(side);
  }

  async function navigateInput(side, input) {
    const value = input.trim();
    if (!value) return;
    if (value === "~" || value.startsWith("~/")) {
      const home = await side.sftp.home();
      navigate(side, home + value.slice(1));
      return;
    }
    navigate(side, value.startsWith("/") ? value : "/" + value);
  }

  async function newRemoteFolder(side) {
    if (!side.sftp) return;
    const name = await promptText("New folder", "Folder name");
    if (!name) return;
    try {
      await side.sftp.mkdir(joinPath(side.path, name));
      await list(side);
    } catch (err) {
      showError(`Failed to create folder: ${err.message}`);
    }
  }

  async function renameRemote(side, item) {
    const name = await promptText("Rename", "New name", item.name);
    if (!name || name === item.name) return;
    try {
      await side.sftp.rename(joinPath(side.path, item.name), joinPath(side.path, name));
      await list(side);
    } catch (err) {
      showError(`Rename failed: ${err.message}`);
    }
  }

  async function chmodRemote(side, item) {
    let applyButton = null;
    const field = textField({
      label: "Mode (octal, e.g. 644 or 755)",
      value: item.mode != null ? (item.mode & 0o7777).toString(8) : "644",
      inputMode: "numeric",
      autofocus: true,
      onEnter: () => applyButton?.click(),
    });
    const result = await openDialog({
      title: `Permissions for "${item.name}"`,
      className: "sftp-prompt",
      content: field.el,
      actions: [
        { label: "Cancel", value: null },
        { label: "Apply", variant: "filled", ref: (node) => (applyButton = node), onClick: (close) => close(field.value) },
      ],
    });
    if (result == null) return;
    if (!/^[0-7]{1,4}$/.test(result.trim())) {
      showError("Invalid octal mode");
      return;
    }
    try {
      await side.sftp.chmod(joinPath(side.path, item.name), parseInt(result.trim(), 8));
      await list(side);
    } catch (err) {
      showError(`chmod failed: ${err.message}`);
    }
  }

  async function deleteRemote(side, item) {
    const ok = await confirmDialog({ title: "Delete?", message: item.isDir ? `Delete directory "${item.name}"?` : `Delete file "${item.name}"?` });
    if (!ok) return;
    try {
      const target = joinPath(side.path, item.name);
      if (item.isDir) await side.sftp.rmdir(target);
      else await side.sftp.remove(target);
      side.items = side.items.filter((entry) => entry.name !== item.name);
      render();
    } catch (err) {
      showError(`Delete failed: ${err.message}`);
    }
  }

  const folder = () => local.stack[local.stack.length - 1]?.handle ?? null;

  async function openFolder() {
    try {
      const handle = await window.showDirectoryPicker({ mode: "readwrite" });
      local.stack = [{ name: handle.name, handle }];
      local.resetScroll = true;
      await listLocal();
    } catch (err) {
      if (err?.name !== "AbortError") showError(`Could not open the folder: ${err.message}`);
    }
  }

  async function listLocal() {
    const dir = folder();
    if (!dir) {
      render();
      return;
    }
    local.loading = true;
    local.error = null;
    render();
    try {
      const items = [];
      for await (const entry of dir.values()) {
        const item = { name: entry.name, isDir: entry.kind === "directory", handle: entry, size: null };
        if (!item.isDir) {
          try {
            item.size = (await entry.getFile()).size;
          } catch {
            item.size = null;
          }
        }
        items.push(item);
      }
      if (folder() !== dir) return;
      local.items = items.sort(byName);
    } catch (err) {
      local.error = `Failed to list: ${err.message}`;
    }
    local.loading = false;
    render();
  }

  function enterLocal(item) {
    local.stack.push({ name: item.name, handle: item.handle });
    local.items = [];
    local.resetScroll = true;
    listLocal();
  }

  function localCrumb(index) {
    local.stack = local.stack.slice(0, index + 1);
    local.items = [];
    local.resetScroll = true;
    listLocal();
  }

  async function newLocalFolder() {
    const dir = folder();
    if (!dir) return;
    const name = await promptText("New folder", "Folder name");
    if (!name) return;
    try {
      await dir.getDirectoryHandle(name, { create: true });
      await listLocal();
    } catch (err) {
      showError(`Failed to create folder: ${err.message}`);
    }
  }

  async function renameLocal(item) {
    if (typeof item.handle.move !== "function") {
      showError("This browser can't rename files on your computer.");
      return;
    }
    const name = await promptText("Rename", "New name", item.name);
    if (!name || name === item.name) return;
    try {
      await item.handle.move(name);
      await listLocal();
    } catch (err) {
      showError(`Rename failed: ${err.message}`);
    }
  }

  async function deleteLocal(item) {
    const ok = await confirmDialog({
      title: "Delete?",
      message: item.isDir ? `Delete directory "${item.name}"? This cannot be undone.` : `Delete file "${item.name}"? This cannot be undone.`,
    });
    if (!ok) return;
    try {
      await folder().removeEntry(item.name, { recursive: item.isDir });
      local.items = local.items.filter((entry) => entry.name !== item.name);
      render();
    } catch (err) {
      showError(`Delete failed: ${err.message}`);
    }
  }

  async function uploadFile(file) {
    const side = right;
    if (!side.sftp) {
      showError("Connect to a host first.");
      return;
    }
    const sftp = side.sftp;
    const dir = side.path;
    const task = beginTransfer(file.name, "Uploading...", file.size);
    let writer = null;
    let reader = null;
    try {
      writer = await sftp.openWrite(joinPath(dir, file.name));
      if (task.canceled) return;
      reader = file.stream().getReader();
      task.cancel = () => {
        reader?.cancel().catch(() => {});
        writer?.close().catch(() => {});
      };
      let sent = 0;
      for (;;) {
        const { done, value } = await reader.read();
        if (done || task.canceled) break;
        await writer.write(value);
        sent += value.length;
        updateTransfer(task, sent);
      }
      await writer.close();
      if (!task.canceled && side.sftp === sftp && side.path === dir) await list(side);
    } catch (err) {
      if (!task.canceled) showError(`Upload "${file.name}" failed: ${err.message}`);
    } finally {
      writer?.close().catch(() => {});
      endTransfer(task);
    }
  }

  async function uploadLocalItem(item) {
    if (item.isDir) return;
    try {
      await uploadFile(await item.handle.getFile());
    } catch (err) {
      showError(`Upload "${item.name}" failed: ${err.message}`);
    }
  }

  function saveBlob(blob, name) {
    const url = URL.createObjectURL(blob);
    const link = h("a", { href: url, download: name, hidden: true });
    document.body.append(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 60000);
  }

  async function download(item) {
    const side = right;
    if (!side.sftp || item.isDir) return;
    const dir = folder();
    const task = beginTransfer(item.name, "Downloading...", item.size ?? 0);
    let reader = null;
    let writable = null;
    try {
      reader = await side.sftp.openRead(joinPath(side.path, item.name));
      if (task.canceled) return;
      task.cancel = () => reader.close();
      let received = 0;
      if (dir) {
        const fileHandle = await dir.getFileHandle(item.name, { create: true });
        writable = await fileHandle.createWritable();
        await reader.readAll((chunk) => {
          if (task.canceled) return false;
          received += chunk.length;
          updateTransfer(task, received);
          return writable.write(chunk);
        });
        await writable.close();
        writable = null;
        if (folder() === dir) await listLocal();
      } else {
        const chunks = [];
        await reader.readAll((chunk) => {
          if (task.canceled) return false;
          chunks.push(chunk);
          received += chunk.length;
          updateTransfer(task, received);
          return true;
        });
        saveBlob(new Blob(chunks), item.name);
      }
    } catch (err) {
      if (writable) {
        await writable.abort().catch(() => {});
        if (task.canceled) await dir.removeEntry(item.name).catch(() => {});
      }
      if (!task.canceled) showError(`Download "${item.name}" failed: ${err.message}`);
    } finally {
      reader?.close();
      endTransfer(task);
    }
  }

  async function copyBetween(src, srcPath, dst, dstPath, name) {
    if (!src.sftp || !dst.sftp) return;
    const task = beginTransfer(name, "Host to host...");
    let reader = null;
    let writer = null;
    try {
      reader = await src.sftp.openRead(srcPath);
      if (reader.size > 0) task.total = reader.size;
      if (task.canceled) return;
      writer = await dst.sftp.openWrite(dstPath);
      task.cancel = () => {
        reader.close();
        writer.close().catch(() => {});
      };
      let copied = 0;
      await reader.readAll((chunk) => {
        if (task.canceled) return false;
        return writer.write(chunk).then(() => {
          copied += chunk.length;
          updateTransfer(task, copied);
        });
      });
      await writer.close();
      if (task.canceled) return;
      await list(right);
      await list(leftRemote);
    } catch (err) {
      if (!task.canceled) showError(`Transfer "${name}" failed: ${err.message}`);
    } finally {
      endTransfer(task);
      reader?.close();
      writer?.close().catch(() => {});
    }
  }

  const copyLeftToRight = (name) => copyBetween(leftRemote, joinPath(leftRemote.path, name), right, joinPath(right.path, name), name);
  const copyRightToLeft = (name) => copyBetween(right, joinPath(right.path, name), leftRemote, joinPath(leftRemote.path, name), name);

  function transferRightOut(item) {
    if (left.isRemote) copyRightToLeft(item.name);
    else download(item);
  }

  async function importLocalFiles(files) {
    const dir = folder();
    if (!dir) {
      showError("Open a local folder first.");
      return;
    }
    for (const file of files) {
      try {
        const handle = await dir.getFileHandle(file.name, { create: true });
        await file.stream().pipeTo(await handle.createWritable());
      } catch (err) {
        showError(`Import "${file.name}" failed: ${err.message}`);
      }
    }
    await listLocal();
  }

  function droppedFiles(dataTransfer) {
    return [...dataTransfer.items]
      .filter((item) => item.kind === "file")
      .map((item) => ({ entry: item.webkitGetAsEntry?.(), file: item.getAsFile() }))
      .filter(({ entry, file }) => file && !entry?.isDirectory)
      .map(({ file }) => file);
  }

  function acceptsDrop(sideName, event) {
    const types = [...event.dataTransfer.types];
    if (dragging && types.includes(DRAG_TYPE)) {
      if (sideName === "right") return dragging.from !== "right" && Boolean(right.sftp);
      if (dragging.from !== "right") return false;
      return left.isRemote ? Boolean(leftRemote.sftp) : true;
    }
    if (!types.includes("Files")) return false;
    if (sideName === "right") return Boolean(right.sftp);
    return !left.isRemote && Boolean(folder());
  }

  function setupDrop(root, sideName) {
    let depth = 0;
    const clear = () => {
      depth = 0;
      root.classList.remove("is-drop");
    };
    root.addEventListener("dragenter", (event) => {
      if (!acceptsDrop(sideName, event)) return;
      event.preventDefault();
      depth++;
      root.classList.add("is-drop");
    });
    root.addEventListener("dragover", (event) => {
      if (!acceptsDrop(sideName, event)) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = "copy";
    });
    root.addEventListener("dragleave", () => {
      depth = Math.max(0, depth - 1);
      if (depth === 0) root.classList.remove("is-drop");
    });
    root.addEventListener("drop", async (event) => {
      const accepted = acceptsDrop(sideName, event);
      clear();
      if (!accepted) return;
      event.preventDefault();
      const drag = dragging;
      dragging = null;
      if (drag) {
        if (sideName === "right") {
          if (drag.from === "local") {
            const item = local.items.find((entry) => entry.name === drag.name);
            if (item) uploadLocalItem(item);
          } else {
            copyLeftToRight(drag.name);
          }
        } else if (left.isRemote) {
          copyRightToLeft(drag.name);
        } else {
          const item = right.items.find((entry) => entry.name === drag.name);
          if (item) download(item);
        }
        return;
      }
      const files = droppedFiles(event.dataTransfer);
      if (sideName === "right") {
        for (const file of files) await uploadFile(file);
      } else {
        importLocalFiles(files);
      }
    });
  }

  setupDrop(leftRoot, "left");
  setupDrop(rightRoot, "right");
  document.addEventListener("dragend", () => {
    dragging = null;
    leftRoot.classList.remove("is-drop");
    rightRoot.classList.remove("is-drop");
  });

  function headAction(iconName, tooltip, onClick) {
    return iconButton({ icon: iconName, size: 17, tooltip, className: "sftp-head-btn", onClick });
  }

  function paneHeader(iconName, title, actions = []) {
    return h("div", { class: "sftp-pane-head" }, icon(iconName, 16), h("span", { class: "sftp-pane-title", text: title }), h("span", { class: "sftp-spacer" }), actions);
  }

  function pathBar({ crumbs, onCrumb, onUp, onRefresh, onEdit, onNewFolder }) {
    const trail = h(
      "div",
      { class: "sftp-crumbs" },
      crumbs.map((crumb, i) => [
        i > 0 && h("span", { class: "sftp-crumb-sep" }, icon("chevron-right", 13)),
        h("button", { type: "button", class: ["sftp-crumb", i === crumbs.length - 1 && "is-current"], text: crumb, onClick: () => onCrumb(i) }),
      ]),
    );
    requestAnimationFrame(() => (trail.scrollLeft = trail.scrollWidth));
    return h(
      "div",
      { class: "sftp-pathbar" },
      iconButton({ icon: "arrow-upward", size: 16, tooltip: "Up", className: "sftp-bar-btn", disabled: !onUp, onClick: onUp }),
      iconButton({ icon: "refresh", size: 16, tooltip: "Refresh", className: "sftp-bar-btn", onClick: onRefresh }),
      trail,
      onEdit && iconButton({ icon: "edit-outlined", size: 16, tooltip: "Go to path", className: "sftp-bar-btn", onClick: onEdit }),
      iconButton({ icon: "create-new-folder-outlined", size: 18, tooltip: "New folder", className: "sftp-bar-btn", onClick: onNewFolder }),
    );
  }

  function paneAction(iconName, tooltip, onClick) {
    return h(
      "button",
      {
        type: "button",
        class: "sftp-row-action",
        "data-tip": tooltip,
        onClick: (event) => {
          event.stopPropagation();
          onClick(event);
        },
        onDblclick: (event) => event.stopPropagation(),
      },
      icon(iconName, iconName === "more-horiz" ? 16 : 15),
    );
  }

  function menuAt(items, x, y) {
    showMenu({ x, y, items: items.filter(Boolean).map((item) => ({ ...item, iconSize: 15 })) });
  }

  function fileRow({ item, from, onOpen, primary, menuItems }) {
    const openMenu = (x, y) => menuAt(menuItems(), x, y);
    const row = h(
      "div",
      {
        class: "sftp-row",
        draggable: !item.isDir,
        onClick: item.isDir ? onOpen : null,
        onContextmenu: (event) => {
          event.preventDefault();
          event.stopPropagation();
          openMenu(event.clientX, event.clientY);
        },
      },
      h("span", { class: ["sftp-row-icon", item.isDir && "is-dir"] }, icon(item.isDir ? "folder" : fileIcon(item.name), 17)),
      h("div", { class: "sftp-row-text" }, h("div", { class: "sftp-row-name", text: item.name }), !item.isDir && item.size != null && h("div", { class: "sftp-row-size", text: formatSize(item.size) })),
      h(
        "div",
        { class: "sftp-row-actions" },
        !item.isDir && primary && paneAction(primary.icon, primary.tooltip, primary.onClick),
        paneAction("more-horiz", "More", (event) => {
          const rect = event.currentTarget.getBoundingClientRect();
          openMenu(rect.left + rect.width / 2, rect.top + rect.height / 2);
        }),
      ),
    );
    if (!item.isDir) {
      row.addEventListener("dragstart", (event) => {
        dragging = { from, name: item.name };
        event.dataTransfer.setData(DRAG_TYPE, item.name);
        event.dataTransfer.effectAllowed = "copy";
        row.classList.add("is-dragging");
      });
      row.addEventListener("dragend", () => row.classList.remove("is-dragging"));
    }
    return row;
  }

  function listContent(state, rows, emptyText, paneMenu) {
    const scroller = state.scroller;
    const top = state.resetScroll ? 0 : scroller.scrollTop;
    state.resetScroll = false;
    scroller.replaceChildren(...(rows.length ? rows : [h("div", { class: "sftp-empty", text: emptyText })]));
    scroller.oncontextmenu = (event) => {
      event.preventDefault();
      menuAt(paneMenu(), event.clientX, event.clientY);
    };
    requestAnimationFrame(() => (scroller.scrollTop = top));
    return scroller;
  }

  function centered(...children) {
    return h("div", { class: "sftp-center" }, children);
  }

  function paneError(message) {
    return centered(h("span", { class: "sftp-danger" }, icon("error-outline", 36)), h("div", { class: "sftp-pane-error", text: message }));
  }

  function loadingView() {
    return centered(h("div", { class: "spinner sftp-spinner" }));
  }

  function remotePane(side, actions, primaryFor) {
    const menuItems = (item) => () => [
      !item.isDir && primaryFor(item).menu,
      { icon: "drive-file-rename-outline", label: "Rename", onSelect: () => renameRemote(side, item) },
      { icon: "lock-outline", label: "Permissions", onSelect: () => chmodRemote(side, item) },
      { icon: "delete-outline", label: "Delete", danger: true, onSelect: () => deleteRemote(side, item) },
      { icon: "refresh", label: "Refresh", onSelect: () => list(side) },
    ];
    const paneMenu = () => [
      { icon: "create-new-folder-outlined", label: "New folder", onSelect: () => newRemoteFolder(side) },
      { icon: "refresh", label: "Refresh", onSelect: () => list(side) },
      {
        icon: "folder-open-outlined",
        label: "Go to path...",
        onSelect: async () => {
          const input = await promptText("Go to path", "Path", side.path);
          if (input != null) navigateInput(side, input);
        },
      },
    ];
    const parts = side.path.split("/").filter(Boolean);
    let content;
    if (side.listError) content = paneError(side.listError);
    else if (side.loading && side.items.length === 0) content = loadingView();
    else {
      content = listContent(
        side,
        side.items.map((item) =>
          fileRow({
            item,
            from: side.name,
            onOpen: () => navigate(side, joinPath(side.path, item.name)),
            primary: primaryFor(item).action,
            menuItems: menuItems(item),
          }),
        ),
        "Empty directory",
        paneMenu,
      );
    }
    return [
      paneHeader("dns-outlined", side.host?.name ?? "Host", actions),
      pathBar({
        crumbs: ["/", ...parts],
        onCrumb: (i) => navigate(side, "/" + parts.slice(0, i).join("/")),
        onUp: side.path === "/" ? null : () => navigate(side, parentPath(side.path)),
        onRefresh: () => {
          side.items = [];
          list(side);
        },
        onEdit: async () => {
          const input = await promptText("Go to path", "Path", side.path);
          if (input != null) navigateInput(side, input);
        },
        onNewFolder: () => newRemoteFolder(side),
      }),
      h("div", { class: "sftp-content" }, content),
    ];
  }

  function localPane() {
    const actions = [
      canOpenFolders && folder() && headAction("folder-open-outlined", "Open another folder", openFolder),
      headAction("dns-outlined", "Browse remote host", () => {
        left.picker = true;
        render();
      }),
    ];
    if (!folder()) {
      return [
        paneHeader("computer-outlined", "Local", actions),
        h(
          "div",
          { class: "sftp-content" },
          centered(
            h("div", { class: "sftp-intro-icon" }, icon("computer-outlined", 30)),
            h("div", { class: "sftp-intro-title", text: "Local files" }),
            h("div", {
              class: "sftp-intro-text",
              text: canOpenFolders
                ? "Open a folder on this computer to browse it here, upload its files to a host and save downloads straight into it."
                : "This browser can't open folders on your computer. Drop files onto the host pane to upload them; downloads are saved to your Downloads folder.",
            }),
            h(
              "div",
              { class: "sftp-intro-actions" },
              canOpenFolders && button({ icon: "folder-open-outlined", label: "Open folder", className: "sftp-big-btn", onClick: openFolder }),
              button({ variant: canOpenFolders ? "outlined" : "filled", icon: "upload-outlined", label: "Upload files", className: "sftp-big-btn", onClick: pickFiles }),
            ),
          ),
        ),
      ];
    }
    const menuItems = (item) => () => [
      !item.isDir && { icon: "upload-outlined", label: "Transfer to host", onSelect: () => uploadLocalItem(item) },
      { icon: "drive-file-rename-outline", label: "Rename", onSelect: () => renameLocal(item) },
      { icon: "delete-outline", label: "Delete", danger: true, onSelect: () => deleteLocal(item) },
      { icon: "refresh", label: "Refresh", onSelect: listLocal },
    ];
    const paneMenu = () => [
      { icon: "create-new-folder-outlined", label: "New folder", onSelect: newLocalFolder },
      { icon: "refresh", label: "Refresh", onSelect: listLocal },
    ];
    let content;
    if (local.loading && local.items.length === 0) content = loadingView();
    else if (local.error) content = paneError(local.error);
    else {
      content = listContent(
        local,
        local.items.map((item) =>
          fileRow({
            item,
            from: "local",
            onOpen: () => enterLocal(item),
            primary: { icon: "upload-outlined", tooltip: "Upload to host", onClick: () => uploadLocalItem(item) },
            menuItems: menuItems(item),
          }),
        ),
        "Empty folder",
        paneMenu,
      );
    }
    return [
      paneHeader("computer-outlined", "Local", actions),
      pathBar({
        crumbs: local.stack.map((entry) => entry.name),
        onCrumb: localCrumb,
        onUp: local.stack.length > 1 ? () => localCrumb(local.stack.length - 2) : null,
        onRefresh: listLocal,
        onNewFolder: newLocalFolder,
      }),
      h("div", { class: "sftp-content" }, content),
    ];
  }

  function pickFiles() {
    if (!right.sftp) {
      showError("Connect to a host on the right first.");
      return;
    }
    const input = h("input", { type: "file", multiple: true, hidden: true });
    input.addEventListener("change", async () => {
      const files = [...input.files];
      input.remove();
      for (const file of files) await uploadFile(file);
    });
    document.body.append(input);
    input.click();
  }

  function renderPickerList(side, onConnect) {
    const data = store.data();
    const hosts = data.hosts;
    const groups = data.groups;
    const query = side.query.trim().toLowerCase();
    const matches = (host) => host.name.toLowerCase().includes(query) || host.address.toLowerCase().includes(query);
    const group = side.groupId && !query ? groups.find((g) => g.id === side.groupId) : null;
    const visibleGroups = group ? [] : groups.filter((g) => g.name.toLowerCase().includes(query) || hosts.some((host) => host.groupId === g.id && matches(host)));
    const visibleHosts = group ? hosts.filter((host) => host.groupId === group.id) : hosts.filter(matches);

    if (hosts.length === 0 && groups.length === 0) {
      side.pickerList.replaceChildren(centered(h("div", { class: "sftp-intro-text", text: "No saved hosts yet" })));
      return;
    }
    side.pickerList.replaceChildren(
      ...[
        group &&
          h(
            "div",
            { class: "sftp-back-row" },
            iconButton({ icon: "arrow-back", size: 17, tooltip: "Back to all groups", onClick: () => ((side.groupId = null), renderPickerList(side, onConnect)) }),
            h("span", { class: "sftp-back-title", text: group.name }),
          ),
        visibleGroups.length > 0 && [
          sectionHeader("Groups"),
          grid(
            visibleGroups.map((g) => {
              const count = hosts.filter((host) => host.groupId === g.id).length;
              const open = () => ((side.groupId = g.id), renderPickerList(side, onConnect));
              return card({
                key: "g:" + g.id,
                tile: tile("folder-outlined"),
                title: g.name,
                sub: count === 1 ? "1 host" : `${count} hosts`,
                action: cardAction({ icon: "chevron-right", tooltip: "Open group", onClick: open }),
                onClick: open,
              });
            }),
            { rowHeight: 60 },
          ),
        ],
        visibleHosts.length > 0 && [
          sectionHeader("Hosts"),
          grid(
            visibleHosts.map((host) =>
              card({
                key: "h:" + host.id,
                tile: tile("dns-outlined", colorFromInt(host.color)),
                title: host.name,
                extras: host.favorite && icon("star", 12, "sftp-star"),
                sub: h("span", { class: "card-sub sftp-mono", text: host.username ? `${host.username}@${host.address}` : host.address }),
                action: cardAction({ icon: "arrow-forward", tooltip: "Connect", onClick: () => onConnect(host) }),
                onClick: () => onConnect(host),
              }),
            ),
            { rowHeight: 60 },
          ),
        ],
      ]
        .flat(Infinity)
        .filter(Boolean),
    );
  }

  function pickerView(side, onConnect, header) {
    side.search ??= searchBox("Search hosts and groups...", (value) => {
      side.query = value;
      renderPickerList(side, onConnect);
    });
    side.pickerList ??= h("div", { class: "sftp-picker-list" });
    renderPickerList(side, onConnect);
    return [header, h("div", { class: "sftp-picker-search" }, side.search.el), side.pickerList];
  }

  function connectingView(name) {
    return centered(h("div", { class: "spinner sftp-connecting-spinner" }), h("div", { class: "sftp-status-title", text: `Connecting to ${name}...` }));
  }

  function connectErrorView(side, onBack) {
    return centered(
      h("span", { class: "sftp-danger" }, icon("error-outline", 40)),
      h("div", { class: "sftp-status-title", text: `Failed to connect to ${side.host?.name ?? "host"}` }),
      h("div", { class: "sftp-status-text", text: side.error }),
      button({ icon: "arrow-back", label: "Back to hosts", className: "sftp-big-btn", onClick: onBack }),
    );
  }

  function leftView() {
    if (left.picker) {
      return pickerView(
        leftRemote,
        (host) => connectRemote(leftRemote, host),
        h(
          "div",
          { class: "sftp-pane-head is-picker" },
          headAction("arrow-back", "Back to local files", () => {
            left.picker = false;
            render();
          }),
          h("span", { class: "sftp-pane-title", text: "Select source host" }),
        ),
      );
    }
    if (left.isRemote && leftRemote.connecting) return connectingView(leftRemote.host?.name ?? "");
    if (left.isRemote && leftRemote.error) {
      return connectErrorView(leftRemote, () => {
        resetSide(leftRemote);
        leftRemote.groupId = null;
        Object.assign(left, { isRemote: false, picker: true });
        render();
      });
    }
    if (left.isRemote && leftRemote.sftp) {
      return remotePane(leftRemote, [headAction("folder-outlined", "Back to local files", () => dropSide(leftRemote)), headAction("link-off", "Disconnect", () => dropSide(leftRemote))], (item) => ({
        action: { icon: "upload-outlined", tooltip: "Transfer to right host", onClick: () => copyLeftToRight(item.name) },
        menu: { icon: "upload-outlined", label: "Transfer to right host", onSelect: () => copyLeftToRight(item.name) },
      }));
    }
    return localPane();
  }

  function rightView() {
    if (right.connecting) return connectingView(right.host?.name ?? "");
    if (right.error) {
      return connectErrorView(right, () => {
        resetSide(right);
        Object.assign(right, { pickerOpen: true, groupId: null });
        render();
      });
    }
    if (right.sftp) {
      return remotePane(right, [headAction("link-off", "Disconnect", disconnectRight)], (item) => {
        const label = left.isRemote ? "Transfer to left host" : "Transfer to local";
        return {
          action: { icon: "download-outlined", tooltip: left.isRemote ? "Transfer to left host" : "Download to local", onClick: () => transferRightOut(item) },
          menu: { icon: left.isRemote ? "swap-horiz" : "download-outlined", label, onSelect: () => transferRightOut(item) },
        };
      });
    }
    if (right.pickerOpen) return pickerView(right, (host) => connectRemote(right, host), null);
    return centered(
      h("div", { class: "sftp-intro-icon is-large" }, icon("cloud-off-outlined", 30)),
      h("div", { class: "sftp-intro-title is-large", text: "Connect to host" }),
      h("div", { class: "sftp-intro-text is-large", text: "Pick a saved host to browse its files, move them between hosts, and sync with your local machine." }),
      button({
        icon: "dns-outlined",
        label: "Select host",
        className: "sftp-big-btn",
        onClick: () => {
          right.pickerOpen = true;
          render();
        },
      }),
    );
  }

  function render() {
    if (el.hidden) return;
    leftRoot.replaceChildren(...[leftView()].flat(Infinity).filter(Boolean));
    rightRoot.replaceChildren(...[rightView()].flat(Infinity).filter(Boolean));
    renderTransfers();
  }

  return {
    el,
    show: render,
    update() {
      if (left.picker && leftRemote.pickerList) renderPickerList(leftRemote, (host) => connectRemote(leftRemote, host));
      if (!right.sftp && right.pickerOpen && right.pickerList) renderPickerList(right, (host) => connectRemote(right, host));
    },
    busy: () => Boolean(right.handle || leftRemote.handle || transfers.length),
  };
}
