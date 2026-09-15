import { api } from "../api.js";
import { fmt, h, icon } from "../dom.js";
import { button, confirmDialog, iconButton, showMenu, snackbar } from "../ui.js";

function needsTeamCrypto(what) {
  snackbar(`${what} needs the Connexia app: workspace keys are exchanged end-to-end encrypted, which the web dashboard doesn't do yet.`);
}

function roleChip(role) {
  return h("span", { class: ["role-chip", "is-" + role], text: role });
}

export function createTeamsScreen(app) {
  let workspaces = [];
  let loading = false;
  let error = null;
  const expanded = new Set();
  const details = new Map();

  const scroll = h("div", { class: "scroll" });
  const el = h("section", { class: "screen" }, h("div", { class: "screen-body" }, scroll));

  async function refresh() {
    loading = true;
    render();
    try {
      const result = await api.get("/api/workspaces");
      workspaces = (result.workspaces || []).sort((a, b) => a.name.localeCompare(b.name));
      error = null;
    } catch (err) {
      error = err.message;
    }
    loading = false;
    render();
    for (const id of expanded) loadDetail(id);
  }

  async function loadDetail(id) {
    details.set(id, { loading: true });
    render();
    try {
      const [detail, audit] = await Promise.all([api.get(`/api/workspaces/${id}`), api.get(`/api/workspaces/${id}/audit`)]);
      details.set(id, { detail, audit: audit.events || [] });
    } catch (err) {
      details.set(id, { error: err.message });
    }
    render();
  }

  function render() {
    const top = scroll.scrollTop;
    scroll.replaceChildren(
      h(
        "div",
        { class: "teams" },
        h(
          "div",
          { class: "teams-head" },
          h("div", { class: "teams-title", text: "Team workspaces" }),
          button({ icon: "add", iconSize: 18, label: "New workspace", disabled: loading, onClick: () => needsTeamCrypto("Creating a workspace") }),
        ),
        h("div", { class: "sp-8" }),
        h("div", {
          class: "teams-text",
          text: "Workspaces sync hosts, groups, keys and snippets across every member of the team. The data is end-to-end encrypted: the server stores only ciphertext and metadata-only audit events (who did what, never the data content).",
        }),
        h("div", { class: "sp-16" }),
        error && h("div", { class: "error-banner" }, icon("error-outline", 18), h("span", { text: error })),
        workspaces.length === 0 && !loading
          ? h("div", { class: "teams-empty" }, icon("groups-outlined", 32), h("span", { text: "You have no workspaces yet. Create one to share hosts and keys with your team." }))
          : workspaces.map(workspaceCard),
      ),
    );
    scroll.scrollTop = top;
  }

  function workspaceCard(summary) {
    const open = expanded.has(summary.id);
    const header = h(
      "button",
      {
        type: "button",
        class: "ws-header",
        onClick: () => {
          if (open) {
            expanded.delete(summary.id);
            render();
          } else {
            expanded.add(summary.id);
            loadDetail(summary.id);
          }
        },
      },
      icon("folder-outlined", 24, "ws-leading"),
      h(
        "span",
        { class: "ws-text" },
        h(
          "span",
          { class: "ws-title-row" },
          h("span", { class: "ws-name", text: summary.name }),
          roleChip(summary.role),
          h("span", { class: "ws-members", text: `${summary.memberCount} member${summary.memberCount === 1 ? "" : "s"}` }),
        ),
        h("span", { class: "ws-sub", text: `Key v${summary.keyVersion} · created ${summary.createdAt ? fmt.day(summary.createdAt) : "recently"}` }),
      ),
      icon("expand-more", 24, open ? "ws-chevron is-open" : "ws-chevron"),
    );
    return h("div", { class: "ws-card" }, header, open && h("div", { class: "ws-body" }, workspaceDetail(summary.id)));
  }

  function workspaceDetail(id) {
    const state = details.get(id);
    if (!state || state.loading) return h("div", { class: "loading ws-loading" }, h("div", { class: "spinner" }));
    if (state.error) return h("div", { class: "ws-error", text: state.error });

    const { detail, audit } = state;
    const manager = detail.myRole === "owner" || detail.myRole === "admin";
    return h(
      "div",
      { class: "stack" },
      h(
        "div",
        { class: "ws-actions" },
        manager && button({ variant: "outlined", icon: "person-add", label: "Invite", onClick: () => needsTeamCrypto("Inviting a member") }),
        h("span", { class: "ws-spacer" }),
        detail.myRole === "owner" &&
          button({ variant: "text", danger: true, icon: "delete-outline", label: "Delete", onClick: () => deleteWorkspace(detail) }),
      ),
      h("div", { class: "sp-16" }),
      h("div", { class: "ws-heading", text: "Members" }),
      h("div", { class: "sp-4" }),
      detail.members.map((member) => memberRow(detail, member)),
      h("div", { class: "sp-16" }),
      manager &&
        h("div", {}, button({ variant: "text", icon: "vpn-key", label: "Rotate workspace key", onClick: () => needsTeamCrypto("Rotating the workspace key") })),
      h("div", { class: "sp-16" }),
      h("div", { class: "ws-divider" }),
      h("div", { class: "sp-8" }),
      h("div", { class: "ws-heading", text: "Audit log" }),
      h("div", { class: "sp-4" }),
      audit.length === 0
        ? h("div", { class: "ws-muted", text: "No audit events yet." })
        : audit.slice(0, 50).map(auditRow),
      audit.length > 50 && h("div", { class: "ws-muted is-small", text: "Showing the 50 most recent events." }),
    );
  }

  function memberRow(detail, member) {
    const canManage = detail.myRole === "owner" || (detail.myRole === "admin" && member.role !== "owner");
    const menuButton =
      canManage && member.role !== "owner"
        ? iconButton({
            icon: "more-vert",
            size: 18,
            onClick: (event) =>
              showMenu({
                anchor: event.currentTarget,
                items: [
                  member.role !== "admin" && { icon: "admin-panel-settings-outlined", iconSize: 15, label: "Make admin", onSelect: () => setRole(detail, member, "admin") },
                  member.role !== "member" && { icon: "person-outline", iconSize: 15, label: "Make member", onSelect: () => setRole(detail, member, "member") },
                  { icon: "person-remove-outlined", iconSize: 15, label: "Remove", danger: true, onSelect: () => removeMember(detail, member) },
                ],
              }),
          })
        : null;
    return h(
      "div",
      { class: "member-row" },
      h("span", { class: "member-avatar", text: member.email ? member.email[0].toUpperCase() : "?" }),
      h(
        "span",
        { class: "stack member-text" },
        h("span", { class: "member-email", text: member.email }),
        h("span", { class: "member-joined", text: `Joined ${member.joinedAt ? fmt.day(member.joinedAt) : "recently"}` }),
      ),
      roleChip(member.role),
      menuButton,
    );
  }

  function auditRow(event) {
    return h(
      "div",
      { class: "audit-row" },
      icon(event.source === "server" ? "cloud-outlined" : "devices", 14),
      h(
        "span",
        { class: "stack" },
        h(
          "span",
          { class: "audit-text" },
          h("b", { text: event.actorEmail || event.actorId }),
          ` ${event.action}`,
          event.target && h("span", { class: "audit-muted", text: ` ${event.target}` }),
          event.revision > 0 && h("span", { class: "audit-muted", text: ` (rev ${event.revision})` }),
        ),
        h("span", { class: "audit-meta", text: `${fmt.second(event.createdAt)} · ${event.ip}` }),
      ),
    );
  }

  async function setRole(detail, member, role) {
    try {
      await api.patch(`/api/workspaces/${detail.id}/members/${member.userId}`, { role });
    } catch (err) {
      snackbar(err.message);
    }
    loadDetail(detail.id);
  }

  async function removeMember(detail, member) {
    try {
      await api.delete(`/api/workspaces/${detail.id}/members/${member.userId}`);
    } catch (err) {
      snackbar(err.message);
    }
    refresh();
  }

  async function deleteWorkspace(detail) {
    const confirmed = await confirmDialog({
      title: "Delete workspace?",
      message: "This permanently deletes the workspace and its encrypted snapshot. Members will lose access immediately.",
    });
    if (!confirmed) return;
    try {
      await api.delete(`/api/workspaces/${detail.id}`);
      expanded.delete(detail.id);
    } catch (err) {
      error = err.message;
    }
    refresh();
  }

  return { el, show: refresh };
}
