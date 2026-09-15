import { h, icon, isTouch, toDate, uuid } from "../dom.js";
import { enableBandSelection } from "../selection.js";
import * as terminals from "../ssh/sessions.js";
import * as store from "../store.js";
import {
  button, cardAction, confirmDialog, copyToClipboard, emptyState, noResults, openDialog, openPanel, panelHeader,
  panelLayout, showMenu, snackbar, textField,
} from "../ui.js";
import { card, gap, grid, markSelected, modKey, replaceKeepingScroll, searchBox, tile, trackHover } from "./common.js";

const SORTS = [
  { value: "alphaAsc", label: "A-z" },
  { value: "alphaDesc", label: "Z-a" },
  { value: "newest", label: "Newest to oldest" },
  { value: "oldest", label: "Oldest to newest" },
];

function compare(sort) {
  const title = (s) => (s.title || "").toLowerCase();
  const time = (s) => toDate(s.updatedAt)?.getTime() ?? 0;
  switch (sort) {
    case "alphaAsc":
      return (a, b) => title(a).localeCompare(title(b));
    case "alphaDesc":
      return (a, b) => title(b).localeCompare(title(a));
    case "oldest":
      return (a, b) => time(a) - time(b);
    default:
      return (a, b) => time(b) - time(a);
  }
}

export function createSnippetsScreen(app) {
  let query = "";
  let sort = "newest";
  let visible = false;
  let panel = null;
  const multi = new Set();

  const search = searchBox("Search snippets...", (value) => {
    query = value;
    render();
  });
  const sortButton = button({
    variant: "outlined",
    icon: "sort",
    label: "Sort",
    size: "toolbar",
    onClick: () =>
      showMenu({
        anchor: sortButton,
        items: SORTS.map((option) => ({
          render: () => [
            h("span", { class: "menu-lead" }, option.value === sort ? icon("check", 16) : null),
            h("span", { class: "menu-label", text: option.label }),
          ],
          onSelect: () => {
            sort = option.value;
            render();
          },
        })),
      }),
  });
  const toolbar = h(
    "div",
    { class: "toolbar" },
    search.el,
    h("div", { class: "toolbar-actions is-wide" }, button({ icon: "code", label: "New snippet", size: "toolbar", onClick: () => openEditor(null) }), sortButton),
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

  function render() {
    const snippets = store.data().snippets;
    const q = query.trim().toLowerCase();
    const filtered = snippets
      .filter((s) => !q || (s.title || "").toLowerCase().includes(q) || (s.command || "").toLowerCase().includes(q))
      .sort(compare(sort));

    let nodes;
    if (snippets.length === 0) {
      nodes = [
        emptyState({
          icon: "code",
          title: "No snippets yet",
          message: "Save reusable commands and run or paste them into any terminal session with one click.",
          roomy: true,
          action: button({ icon: "code", label: "New snippet", size: "toolbar", onClick: () => openEditor(null) }),
        }),
      ];
    } else if (filtered.length === 0) {
      nodes = [noResults("No snippets match your search")];
    } else {
      nodes = [grid(filtered.map(snippetCard), { rowHeight: 60, padding: "top" })];
    }
    replaceKeepingScroll(scroll, nodes);
    syncSelectionBar();
  }

  function snippetCard(snippet) {
    return card({
      key: snippet.id,
      selected: multi.has(snippet.id),
      tooltip: snippet.command,
      tile: tile("code"),
      title: snippet.title,
      sub: (snippet.command || "").replace(/\n/g, " "),
      action: cardAction({ icon: "edit-outlined", size: 14, tooltip: "Edit snippet", onClick: () => openEditor(snippet) }),
      actionOnTouch: true,
      onClick: (event) => {
        if (modKey(event)) {
          if (multi.has(snippet.id)) multi.delete(snippet.id);
          else multi.add(snippet.id);
        } else if (multi.size > 0) {
          multi.clear();
        } else if (isTouch) {
          openEditor(snippet);
        }
        refreshSelection();
      },
      onMenu: (x, y) =>
        showMenu({
          x,
          y,
          items: [
            { icon: "edit-outlined", label: "Edit", onSelect: () => openEditor(snippet) },
            { icon: "playlist-play", label: "Run in all tabs", onSelect: () => terminals.runAll(snippet.command) === 0 && snackbar("No connected terminals", 2000) },
            { icon: "content-paste", label: "Paste", onSelect: () => snackbar(terminals.paste(snippet.command) ? "Pasted into the active terminal" : "No connected terminal to paste into", 2000) },
            { icon: "copy-outlined", label: "Copy", onSelect: () => copyToClipboard(snippet.command, "Command copied to clipboard") },
            { icon: "visibility-outlined", label: "View more", onSelect: () => viewMore(snippet) },
            { icon: "delete-outline", label: "Remove", danger: true, onSelect: () => deleteSnippet(snippet) },
          ],
        }),
    });
  }

  function viewMore(snippet) {
    openDialog({
      title: [icon("code", 18), h("span", { class: "ellipsis", text: snippet.title })],
      content: h("div", { class: "snippet-view", text: snippet.command }),
      actions: [
        {
          label: "Copy",
          icon: "copy-outlined",
          onClick: (close) => {
            copyToClipboard(snippet.command, "Command copied to clipboard");
            close();
          },
        },
        { label: "Close", variant: "filled" },
      ],
    });
  }

  async function deleteSnippet(snippet) {
    const confirmed = await confirmDialog({ title: "Delete snippet?", message: `Delete "${snippet.title}"?` });
    if (!confirmed) return;
    app.save((d) => {
      d.snippets = d.snippets.filter((s) => s.id !== snippet.id);
    });
  }

  async function deleteSelection() {
    const ids = [...multi];
    if (ids.length === 0) return;
    const confirmed = await confirmDialog({ title: "Delete snippets?", message: `Delete ${ids.length} snippet(s)? This cannot be undone.` });
    if (!confirmed) return;
    await app.save((d) => {
      d.snippets = d.snippets.filter((s) => !ids.includes(s.id));
    });
    multi.clear();
    render();
  }

  function openEditor(snippet) {
    panel?.close();
    panel = openPanel(el, {
      width: 320,
      build: (p) => snippetForm(app, p, snippet),
      onClose: () => {
        panel = null;
      },
    });
    panel.targetId = snippet?.id ?? null;
  }

  return {
    el,
    update() {
      render();
      if (panel?.targetId && !store.data().snippets.some((s) => s.id === panel.targetId)) {
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
      const snippet = store.data().snippets.find((s) => s.id === hover.key);
      if (snippet) openEditor(snippet);
      return Boolean(snippet);
    },
  };
}

function snippetForm(app, panel, snippet) {
  const title = textField({ label: "Title", value: snippet?.title, autofocus: true });
  const command = textField({
    label: "Command",
    hint: 'e.g. docker ps --format "table {{.Names}}"',
    multiline: true,
    rows: 10,
    mono: true,
    className: "is-mono-large",
    value: snippet?.command,
  });

  async function save() {
    const text = command.value.trim();
    if (!text) return;
    let name = title.value.trim();
    if (!name) {
      const firstLine = text.split("\n")[0].trim();
      name = firstLine || "Untitled";
      if (name.length > 40) name = name.slice(0, 40) + "…";
    }
    const now = new Date().toISOString();
    const id = snippet?.id ?? uuid();
    const ok = await app.save((d) => {
      const existing = d.snippets.find((s) => s.id === id);
      const fields = { id, title: name, command: text, createdAt: existing?.createdAt ?? now, updatedAt: now };
      if (existing) Object.assign(existing, fields);
      else d.snippets.push({ workspaceId: null, ...fields });
    });
    if (ok) panel.close();
  }

  return panelLayout({
    children: [
      panelHeader({ title: snippet ? "Edit snippet" : "New snippet", onClose: () => panel.close() }),
      title.el,
      gap(12),
      command.el,
    ],
    footer: button({ icon: "check", label: "Save snippet", block: true, className: "btn-h32", onClick: save }),
  });
}

export function openSnippetPanel(host, app, snippet) {
  return openPanel(host, { width: 320, build: (panel) => snippetForm(app, panel, snippet) });
}
