import { h, icon, osIconName } from "../dom.js";
import { showMenu } from "../ui.js";
import * as terminals from "./sessions.js";

export function createSessionTabs({ strip, end, mobileRow, app }) {
  let renaming = null;

  function activate(session) {
    terminals.setActive(session.id);
    app.go("terminals");
  }

  function startRename(session, label) {
    renaming = session.id;
    const input = h("input", { class: "tab-rename", value: session.label, spellcheck: false });
    let done = false;
    const finish = (commit) => {
      if (done) return;
      done = true;
      renaming = null;
      if (commit) terminals.rename(session, input.value);
      else render();
    };
    input.addEventListener("keydown", (event) => {
      event.stopPropagation();
      if (event.key === "Enter") finish(true);
      if (event.key === "Escape") finish(false);
    });
    input.addEventListener("blur", () => finish(true));
    input.addEventListener("click", (event) => event.stopPropagation());
    label.replaceWith(input);
    input.focus();
    input.select();
  }

  function menu(session, x, y, label) {
    const broken = session.status === "error" || session.status === "disconnected";
    showMenu({
      x,
      y,
      items: [
        broken && { icon: "refresh", label: "Reconnect", onSelect: () => terminals.reconnect(session) },
        { icon: "content-copy-outlined", label: "Duplicate", onSelect: () => terminals.duplicate(session) },
        { icon: "drive-file-rename-outline", label: "Rename", onSelect: () => startRename(session, label) },
        { icon: "close", label: "Close", danger: true, onSelect: () => terminals.closeSession(session) },
      ]
        .filter(Boolean)
        .map((item) => ({ ...item, iconSize: 15 })),
    });
  }

  function tab(session, inTerminals) {
    const selected = inTerminals && session.id === terminals.state.activeId;
    const label = h("span", { class: "tab-label", text: session.label });
    const close = h(
      "span",
      {
        class: "tab-close",
        role: "button",
        "data-tip": "Close session",
        onClick: (event) => {
          event.stopPropagation();
          terminals.closeSession(session);
        },
      },
      icon(session.os ? osIconName(session.os) : "close", 13, "tab-os"),
      icon("close", 13, "tab-x"),
    );
    label.addEventListener("dblclick", (event) => {
      event.stopPropagation();
      startRename(session, label);
    });
    return h(
      "div",
      {
        class: ["session-tab", selected && "is-selected"],
        role: "tab",
        style: { "--tab-status": terminals.statusColor(session.status) },
        onClick: () => activate(session),
        onContextmenu: (event) => {
          event.preventDefault();
          menu(session, event.clientX, event.clientY, label);
        },
      },
      close,
      label,
      session.hasUnseenOutput && !selected && h("span", { class: "output-dot" }),
    );
  }

  function chip(session, inTerminals) {
    const selected = inTerminals && session.id === terminals.state.activeId;
    return h(
      "button",
      { type: "button", class: ["session-chip", selected && "is-selected"], onClick: () => activate(session) },
      h(
        "span",
        {
          class: "session-chip-close",
          role: "button",
          onClick: (event) => {
            event.stopPropagation();
            terminals.closeSession(session);
          },
        },
        icon("close", 13),
      ),
      h("span", { class: "session-chip-label", text: session.label }),
      session.hasUnseenOutput && !selected && h("span", { class: "output-dot" }),
    );
  }

  function render() {
    if (renaming) return;
    const inTerminals = app.current() === "terminals";
    const list = terminals.sessions;
    strip.replaceChildren(...(list.length ? [h("span", { class: "titlebar-divider" }), ...list.map((s) => tab(s, inTerminals))] : []));
    const open = terminals.state.snippetsOpen;
    end.replaceChildren(
      ...(inTerminals
        ? [
            h(
              "button",
              { type: "button", class: "titlebar-icon", "data-tip": open ? "Hide snippets panel" : "Show snippets panel", onClick: terminals.toggleSnippets },
              icon(open ? "menu-open" : "menu", 17),
            ),
          ]
        : []),
    );
    mobileRow.replaceChildren(...list.map((s) => chip(s, inTerminals)));
  }

  return { render };
}
