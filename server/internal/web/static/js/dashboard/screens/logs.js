import { fmt, h, icon, toDate } from "../dom.js";
import * as store from "../store.js";
import { button, confirmDialog, emptyState, snackbar } from "../ui.js";
import { replaceKeepingScroll } from "./common.js";

const PAGE_SIZE = 50;

export function createLogsScreen(app) {
  let tab = "sessions";
  let shown = PAGE_SIZE;

  const tabButton = (id, label) =>
    h("button", {
      type: "button",
      class: "logs-tab",
      text: label,
      dataset: { tab: id },
      onClick: () => {
        tab = id;
        render();
      },
    });
  const tabs = [tabButton("sessions", "Sessions"), tabButton("tunnels", "Tunnels")];
  const count = h("span", { class: "logs-count" });
  const clear = button({ variant: "text", danger: true, icon: "delete-sweep-outlined", iconSize: 15, label: "Clear logs", onClick: clearLogs });
  const bar = h("div", { class: "logs-bar" }, tabs, h("div", { class: "logs-bar-end" }, clear, count));
  const scroll = h("div", { class: "scroll" });
  const el = h("section", { class: "screen logs-screen" }, bar, h("div", { class: "screen-body" }, scroll));

  scroll.addEventListener("scroll", () => {
    const total = store.data().sessionLogs.length;
    if (tab === "sessions" && shown < total && scroll.scrollTop + scroll.clientHeight >= scroll.scrollHeight - 300) {
      shown += PAGE_SIZE;
      render();
    }
  });

  const sortedLogs = () =>
    [...store.data().sessionLogs].sort((a, b) => (toDate(b.connectedAt)?.getTime() ?? 0) - (toDate(a.connectedAt)?.getTime() ?? 0));

  function render() {
    for (const button of tabs) {
      button.classList.toggle("is-selected", button.dataset.tab === tab);
    }
    const logs = sortedLogs();
    count.textContent = tab === "sessions" ? `${logs.length} total` : "0 recent";

    let nodes;
    if (tab === "tunnels") {
      nodes = [
        emptyState({
          icon: "lan-outlined",
          title: "No tunnel events yet",
          message: "Tunnel starts, stops and errors are recorded here — including the full error message and stack trace when a tunnel fails.",
          roomy: true,
        }),
      ];
    } else if (logs.length === 0) {
      nodes = [
        emptyState({
          icon: "receipt-long-outlined",
          title: "No sessions logged yet",
          message: "Every SSH connection is recorded here with its connect and disconnect times.",
          roomy: true,
        }),
      ];
    } else {
      const list = h("div", { class: "logs-list" }, logs.slice(0, shown).map(logTile));
      if (shown < logs.length) {
        list.append(
          h(
            "div",
            { class: "logs-more" },
            button({
              variant: "text",
              label: "Load more",
              onClick: () => {
                shown += PAGE_SIZE;
                render();
              },
            }),
          ),
        );
      }
      nodes = [list];
    }
    replaceKeepingScroll(scroll, nodes);
  }

  function logTile(log) {
    const active = log.disconnectedAt == null;
    const badge = () => h("span", { class: "badge-active", text: "ACTIVE" });
    const details = () => {
      const duration = toDate(log.disconnectedAt) - toDate(log.connectedAt);
      return [
        h("span", { class: "log-line", text: `Disconnected ${fmt.second(log.disconnectedAt)}` }),
        h("span", { class: "log-line is-duration", text: `Duration ${fmt.duration(duration)}` }),
      ];
    };
    return h(
      "div",
      { class: "log-tile" },
      h("div", { class: ["log-icon", active && "is-active"] }, icon(active ? "link" : "link-off", 16)),
      h(
        "div",
        { class: "log-main" },
        h("div", { class: "log-title-row" }, h("span", { class: "log-title", text: `${log.username}@${log.address}` }), active && badge()),
        h("span", { class: "log-line", text: `Connected ${fmt.second(log.connectedAt)}${active ? " — still connected" : ""}` }),
        !active && h("div", { class: "log-extra" }, details()),
      ),
      active ? h("div", { class: "log-side" }, badge()) : h("div", { class: "log-side" }, details()),
    );
  }

  async function clearLogs() {
    if (tab === "tunnels") {
      snackbar("Tunnel logs are kept on the device that ran the tunnel.");
      return;
    }
    const total = store.data().sessionLogs.length;
    const confirmed = await confirmDialog({
      title: "Clear session logs?",
      message: total === 0 ? "All logged sessions will be removed. This cannot be undone." : `Remove all ${total} logged session(s)? This cannot be undone.`,
      confirmLabel: "Clear",
    });
    if (!confirmed) return;
    const ok = await app.save((d) => {
      d.sessionLogs = [];
    });
    if (ok) snackbar("Session logs cleared");
  }

  return { el, update: render, show: render };
}
