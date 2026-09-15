import { fmt, h } from "../dom.js";
import { enableBandSelection } from "../selection.js";
import * as store from "../store.js";
import { cardAction, confirmDialog, copyToClipboard, emptyState, showMenu } from "../ui.js";
import { card, grid, markSelected, modKey, replaceKeepingScroll, tile } from "./common.js";

export function createKnownHostsScreen(app) {
  let visible = false;
  const multi = new Set();

  const scroll = h("div", { class: "scroll" });
  const body = h("div", { class: "screen-body" }, scroll);
  const el = h("section", { class: "screen" }, body);

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
      actions: [{ icon: "delete-outline", label: "Delete", danger: true, onClick: removeSelection }],
      onClose: () => {
        multi.clear();
        refreshSelection();
      },
    });
  }

  const copyFingerprint = (host) => copyToClipboard(host.fingerprint, "Fingerprint copied to clipboard");

  function render() {
    const hosts = store.data().knownHosts;
    const nodes = hosts.length
      ? [grid(hosts.map(hostCard), { rowHeight: 62, padding: "even" })]
      : [
          emptyState({
            icon: "shield-outlined",
            title: "No known hosts yet",
            message: "Host keys are recorded here after you accept the security prompt of a first connection.",
          }),
        ];
    replaceKeepingScroll(scroll, nodes);
    syncSelectionBar();
  }

  function hostCard(host) {
    return card({
      key: host.hostKey,
      className: "is-known",
      selected: multi.has(host.hostKey),
      tooltip: `First seen: ${fmt.minute(host.firstSeen)}\nLast seen: ${fmt.minute(host.lastSeen)}`,
      tile: tile("dns-outlined"),
      title: host.hostKey,
      extras: h("span", { class: "type-chip", text: host.keyType }),
      sub: host.fingerprint,
      action: cardAction({ icon: "delete-outline", size: 14, tooltip: "Remove host key", onClick: () => removeOne(host) }),
      onClick: (event) => {
        if (modKey(event)) {
          if (multi.has(host.hostKey)) multi.delete(host.hostKey);
          else multi.add(host.hostKey);
          refreshSelection();
        } else if (multi.size > 0) {
          multi.clear();
          refreshSelection();
        } else {
          copyFingerprint(host);
        }
      },
      onMenu: (x, y) =>
        showMenu({
          x,
          y,
          items: [
            { icon: "copy-outlined", label: "Copy fingerprint", onSelect: () => copyFingerprint(host) },
            { icon: "delete-outline", label: "Remove", danger: true, onSelect: () => removeOne(host) },
          ],
        }),
    });
  }

  async function removeOne(host) {
    const confirmed = await confirmDialog({
      title: "Remove host key?",
      message: `Forgetting "${host.hostKey}" means the next connection will ask you to verify the host key again.`,
      confirmLabel: "Remove",
    });
    if (!confirmed) return;
    multi.delete(host.hostKey);
    app.save((d) => {
      d.knownHosts = d.knownHosts.filter((k) => k.hostKey !== host.hostKey);
    });
  }

  async function removeSelection() {
    const keys = [...multi];
    if (keys.length === 0) return;
    const confirmed = await confirmDialog({
      title: "Remove host keys?",
      message: `Forget ${keys.length} host key(s)? The next connections will ask you to verify them again.`,
      confirmLabel: "Remove",
    });
    if (!confirmed) return;
    await app.save((d) => {
      d.knownHosts = d.knownHosts.filter((k) => !keys.includes(k.hostKey));
    });
    multi.clear();
    render();
  }

  return {
    el,
    update: render,
    show() {
      visible = true;
      render();
    },
    hide() {
      visible = false;
      multi.clear();
    },
  };
}
