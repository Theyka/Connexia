import { h, icon } from "../dom.js";
import * as store from "../store.js";
import * as terminals from "../ssh/sessions.js";
import { button, confirmDialog, copyToClipboard, showMenu, snackbar } from "../ui.js";
import { openSnippetPanel } from "./snippets.js";

export function createTerminalsScreen(app) {
  const area = h("div", { class: "term-area" });
  const sidebar = h("aside", { class: "term-snippets" });
  const el = h("section", { class: "screen term-screen" }, h("div", { class: "term-row" }, area, sidebar));
  const panes = new Map();
  const expanded = new Set();
  let snippetsKey = "";
  let lastWheelZoom = 0;

  area.addEventListener(
    "wheel",
    (event) => {
      if (!event.ctrlKey) return;
      event.preventDefault();
      const now = Date.now();
      if (event.deltaY === 0 || now - lastWheelZoom < 80) return;
      lastWheelZoom = now;
      terminals.zoom(event.deltaY < 0 ? 1 : -1);
    },
    { passive: false },
  );

  function paneFor(session) {
    let entry = panes.get(session.id);
    if (entry) return entry;
    const overlay = h("div", { class: "term-overlay" });
    const pane = h("div", { class: "term-pane" }, session.el, overlay);
    session.el.addEventListener("contextmenu", (event) => {
      event.preventDefault();
      showMenu({
        x: event.clientX,
        y: event.clientY,
        items: [
          { icon: "copy-outlined", iconSize: 15, label: "Copy", onSelect: () => terminals.copySelection(session) },
          { icon: "content-paste", iconSize: 15, label: "Paste", onSelect: () => terminals.pasteClipboard(session) },
        ],
      });
    });
    entry = { pane, overlay, key: "" };
    panes.set(session.id, entry);
    area.append(pane);
    return entry;
  }

  function render() {
    const alive = new Set(terminals.sessions.map((s) => s.id));
    for (const [id, entry] of panes) {
      if (!alive.has(id)) {
        entry.pane.remove();
        panes.delete(id);
      }
    }
    for (const session of terminals.sessions) {
      const entry = paneFor(session);
      entry.pane.hidden = session.id !== terminals.state.activeId;
      const seconds = session.nextRetryAt ? Math.max(1, Math.ceil((session.nextRetryAt - Date.now()) / 1000)) : 0;
      const key = [session.status, session.error, session.autoRetry, seconds, session.pendingHostKey?.fingerprint].join("|");
      if (key !== entry.key) {
        entry.key = key;
        entry.overlay.replaceChildren(...overlayFor(session, seconds).filter(Boolean));
      }
    }
    sidebar.hidden = !terminals.state.snippetsOpen;
    if (terminals.state.snippetsOpen) renderSnippets();
  }

  function overlayFor(session, seconds) {
    const cover = (child) => h("div", { class: "term-cover" }, child);
    const retryBanner = () =>
      h(
        "div",
        { class: "float-chip retry-banner" },
        h("div", { class: "spinner is-tiny" }),
        h("span", { text: `Reconnecting in ${seconds}s…` }),
        h("button", { type: "button", class: "retry-stop", "data-tip": "Stop reconnecting", onClick: () => terminals.stopAutoRetry(session) }, icon("close", 15)),
      );
    const { address, port } = session.request;

    switch (session.status) {
      case "connecting":
        return [
          cover(
            h(
              "div",
              { class: "term-cover-center" },
              h("div", { class: "spinner is-large" }),
              h("div", { class: "term-cover-text", text: session.autoRetry ? "Reconnecting..." : "Connecting..." }),
              button({ variant: "outlined", label: "Cancel", className: "term-cancel", onClick: () => terminals.closeSession(session) }),
            ),
          ),
        ];
      case "verifying": {
        const pending = session.pendingHostKey;
        return [
          cover(
            h(
              "div",
              { class: "hostkey-card" },
              h("div", { class: "hostkey-title" }, icon("shield-outlined", 22), h("span", { text: "Unknown host key" })),
              h("div", {
                class: "hostkey-text",
                text: `The authenticity of ${address}:${port} cannot be established. This is the first time you connect to this host.`,
              }),
              h("div", { class: "hostkey-type", text: `Key type: ${pending?.keyType ?? "unknown"}` }),
              h("div", { class: "hostkey-fingerprint", text: pending?.fingerprint ?? "" }),
              h("div", { class: "hostkey-warning", text: "Continue only if you trust this host. An attacker could otherwise intercept your connection." }),
              h(
                "div",
                { class: "hostkey-actions" },
                button({ variant: "outlined", label: "Cancel", className: "btn-h32", onClick: () => terminals.resolveHostKey(session, false) }),
                button({ label: "Connect", className: "btn-h32", onClick: () => terminals.resolveHostKey(session, true) }),
              ),
            ),
          ),
        ];
      }
      case "error":
        return [
          cover(
            h(
              "div",
              { class: "term-cover-center" },
              icon("error-outline", 48, "term-error-icon"),
              h("div", { class: "term-error-text", text: session.error || "Connection failed" }),
              button({ icon: "refresh", label: "Reconnect", className: "btn-h32", onClick: () => terminals.reconnect(session) }),
            ),
          ),
          session.autoRetry && h("div", { class: "term-float" }, retryBanner()),
        ];
      case "disconnected":
        return [
          h(
            "div",
            { class: "term-float" },
            h("button", { type: "button", class: "float-chip", onClick: () => terminals.reconnect(session) }, icon("refresh", 14), h("span", { text: "Reconnect" })),
            session.autoRetry && retryBanner(),
          ),
        ];
      default:
        return [];
    }
  }

  const sideButton = (iconName, tooltip, onClick, disabled) =>
    h(
      "button",
      {
        type: "button",
        class: "side-icon-btn",
        "data-tip": tooltip,
        disabled,
        onClick: (event) => {
          event.stopPropagation();
          onClick();
        },
      },
      icon(iconName, 15),
    );

  function runSnippet(snippet) {
    if (!terminals.run(snippet.command)) snackbar("No connected terminal to run in", 2000);
  }

  function pasteSnippet(snippet) {
    snackbar(terminals.paste(snippet.command) ? "Pasted into the active terminal" : "No connected terminal to paste into", 2000);
  }

  function toggleExpanded(snippet) {
    if (expanded.has(snippet.id)) expanded.delete(snippet.id);
    else expanded.add(snippet.id);
    renderSnippets();
  }

  function snippetMenu(snippet, x, y) {
    showMenu({
      x,
      y,
      items: [
        { icon: "play-arrow", label: "Run", onSelect: () => runSnippet(snippet) },
        { icon: "edit-outlined", label: "Edit", onSelect: () => openSnippetPanel(el, app, snippet) },
        {
          icon: "playlist-play",
          label: "Run in all tabs",
          onSelect: () => {
            if (terminals.runAll(snippet.command) === 0) snackbar("No connected terminals", 2000);
          },
        },
        { icon: "content-paste", label: "Paste", onSelect: () => pasteSnippet(snippet) },
        { icon: "copy-outlined", label: "Copy to clipboard", onSelect: () => copyToClipboard(snippet.command, "Command copied to clipboard") },
        { icon: "visibility-outlined", label: "View more", onSelect: () => toggleExpanded(snippet) },
        {
          icon: "delete-outline",
          label: "Delete",
          danger: true,
          onSelect: async () => {
            const confirmed = await confirmDialog({ title: "Delete snippet?", message: `Delete "${snippet.title}"?` });
            if (!confirmed) return;
            app.save((d) => {
              d.snippets = d.snippets.filter((s) => s.id !== snippet.id);
            });
          },
        },
      ].map((item) => ({ ...item, iconSize: 15 })),
    });
  }

  function renderSnippets(force) {
    const snippets = store.data().snippets;
    const size = terminals.currentFontSize();
    const key = JSON.stringify([snippets.map((s) => [s.id, s.title, s.command]), size, [...expanded]]);
    if (!force && key === snippetsKey) return;
    snippetsKey = key;

    const list = snippets.length
      ? h(
          "div",
          { class: "term-snippets-list" },
          snippets.map((snippet) => {
            const open = expanded.has(snippet.id);
            return h(
              "div",
              {
                class: "snippet-row",
                onClick: () => runSnippet(snippet),
                onContextmenu: (event) => {
                  event.preventDefault();
                  snippetMenu(snippet, event.clientX, event.clientY);
                },
              },
              h("div", { class: "snippet-row-title", text: snippet.title }),
              !open && h("div", { class: "snippet-row-cmd", text: snippet.command.replace(/\n/g, " ") }),
              h(
                "div",
                { class: "snippet-row-actions" },
                sideButton("play-arrow", "Run in the active terminal", () => runSnippet(snippet)),
                sideButton("content-paste", "Paste into the active terminal", () => pasteSnippet(snippet)),
                sideButton(open ? "visibility-off-outlined" : "visibility-outlined", open ? "Collapse" : "View full command", () => toggleExpanded(snippet)),
              ),
              open && h("div", { class: "snippet-row-full", text: snippet.command, onClick: (event) => event.stopPropagation() }),
            );
          }),
        )
      : h(
          "div",
          { class: "term-snippets-empty" },
          icon("code", 30),
          h("div", { class: "term-snippets-empty-title", text: "No snippets yet" }),
          h("div", { class: "term-snippets-empty-text", text: "Save reusable commands and send them to any terminal." }),
          button({ variant: "text", icon: "add", iconSize: 15, label: "New snippet", onClick: () => openSnippetPanel(el, app, null) }),
        );

    sidebar.replaceChildren(
      h(
        "div",
        { class: "term-snippets-head" },
        icon("code", 16),
        h("span", { class: "term-snippets-title", text: "Snippets" }),
        sideButton("add", "New snippet", () => openSnippetPanel(el, app, null)),
      ),
      list,
      h(
        "div",
        { class: "term-zoom" },
        h("span", { class: "term-zoom-label", text: "Zoom" }),
        h("span", { class: "term-zoom-hint", text: "Ctrl+wheel / Ctrl+= / Ctrl+-" }),
        sideButton("remove", "Zoom out (Ctrl+-)", () => terminals.zoom(-1), size <= 8),
        h("span", { class: "term-zoom-value", text: `${Math.round((size / 14) * 100)}%` }),
        sideButton("add", "Zoom in (Ctrl+=)", () => terminals.zoom(1), size >= 28),
      ),
    );
  }

  terminals.onChange(render);

  return {
    el,
    update() {
      render();
    },
    show: render,
  };
}
