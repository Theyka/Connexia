import { h, icon, osIconName } from "../dom.js";
import { hottestTemp } from "../metrics/collect.js";
import { metricsController, watchlistOf } from "../metrics/controller.js";
import { promptCredentials } from "../ssh/client.js";
import * as store from "../store.js";
import { button, checkbox, iconButton, openDialog, snackbar, textField } from "../ui.js";
import { colorFromInt } from "./common.js";

const LEVEL_COLOR = { good: "var(--success)", warn: "var(--warning)", bad: "var(--danger)" };
const PCT_WORD = { good: "Normal", warn: "High", bad: "Critical" };
const LEVEL_ORDER = { good: 0, warn: 1, bad: 2 };
const TRACK = "color-mix(in srgb, var(--text-faint) 25%, transparent)";
const spinning = new Set();

const clamp = (value, lo, hi) => Math.min(hi, Math.max(lo, value));
const pctLevel = (pct) => (pct >= 90 ? "bad" : pct >= 80 ? "warn" : "good");
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const sp = (height) => h("div", { style: { height: height + "px", flex: "none" } });

export function memF(mb) {
  if (mb >= 1024 * 1024) return `${(mb / 1024 / 1024).toFixed(1)} TB`;
  if (mb >= 1024) return `${(mb / 1024).toFixed(1)} GB`;
  return `${mb.toFixed(0)} MB`;
}

export function bytesF(b) {
  if (b >= 1024 * 1024 * 1024) return `${(b / 1024 / 1024 / 1024).toFixed(1)} GB`;
  if (b >= 1024 * 1024) return `${(b / 1024 / 1024).toFixed(1)} MB`;
  if (b >= 1024) return `${(b / 1024).toFixed(1)} KB`;
  return `${b.toFixed(0)} B`;
}

function formatUptime(seconds) {
  const d = Math.floor(seconds / 86400);
  const hrs = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return `${d} d ${hrs} h`;
  if (hrs > 0) return `${hrs} h ${m} m`;
  return `${m} m`;
}

function coresOf(s) {
  const cores = /^\d+$/.test(s?.sysInfo?.cores ?? "") ? parseInt(s.sysInfo.cores, 10) : null;
  return cores && cores > 0 ? cores : null;
}

function loadRatio(s) {
  if (s?.load1 == null) return null;
  return s.load1 / (coresOf(s) ?? 1);
}

function workloadWord(ratio) {
  if (ratio < 0.5) return ["good", "Light"];
  if (ratio < 1) return ["good", "Moderate"];
  if (ratio < 1.5) return ["warn", "Heavy"];
  return ["bad", "Overloaded"];
}

function tempWord(celsius) {
  if (celsius < 60) return ["good", "Cool"];
  if (celsius < 75) return ["good", "Warm"];
  if (celsius < 85) return ["warn", "Hot"];
  return ["bad", "Too hot"];
}

function mainDisk(s) {
  const disks = s?.disks ?? [];
  return disks.find((d) => d.mount === "/") ?? disks[0] ?? null;
}

function diskName(d) {
  if (d.mount === "/") return "System disk";
  if (d.mount === "/boot" || d.mount === "/boot/efi") return "Boot partition";
  if (d.mount === "/home") return "User files";
  if (d.device.includes(":")) return "Network share";
  return d.mount;
}

const memPctOf = (s) => (s && (s.memTotalMb ?? 0) > 0 ? s.memPct : null);

function healthIssues(s) {
  const issues = [];
  if (s.cpuPct != null && pctLevel(s.cpuPct) !== "good") {
    issues.push([pctLevel(s.cpuPct), `The processor is very busy (${s.cpuPct.toFixed(0)}% in use).`]);
  }
  if ((s.memTotalMb ?? 0) > 0 && pctLevel(s.memPct) !== "good") {
    issues.push([pctLevel(s.memPct), `Memory is ${s.memPct >= 90 ? "almost full" : "running low"} (${s.memPct.toFixed(0)}% used).`]);
  }
  for (const d of s.disks) {
    if (pctLevel(d.pct) === "good") continue;
    const name = diskName(d) === d.mount ? `Disk ${d.mount}` : `${diskName(d)} (${d.mount})`;
    issues.push([pctLevel(d.pct), `${name} is ${d.pct >= 90 ? "almost full" : "filling up"} — only ${memF(Math.max(0, d.totalMb - d.usedMb))} free.`]);
  }
  const ratio = loadRatio(s);
  if (ratio != null && ratio >= 1) {
    issues.push(ratio >= 1.5 ? ["bad", "The server has more work than it can keep up with."] : ["warn", "The server is working at full capacity."]);
  }
  const hot = hottestTemp(s);
  if (hot) {
    const [level] = tempWord(hot.celsius);
    if (level !== "good") issues.push([level, `It is running hot (${hot.celsius.toFixed(0)}°C).`]);
  }
  return issues.sort((a, b) => LEVEL_ORDER[b[0]] - LEVEL_ORDER[a[0]]);
}

function cleanCpuModel(model) {
  return model.replace(/\((R|TM)\)/gi, "").replace(/\s+CPU\b/g, "").replace(/\s+/g, " ").trim();
}

function archName(arch) {
  if (!arch) return "";
  if (arch === "x86_64" || arch === "amd64") return `64-bit Intel/AMD (${arch})`;
  if (arch === "aarch64" || arch === "arm64") return `64-bit ARM (${arch})`;
  if (arch === "i386" || arch === "i686") return `32-bit Intel/AMD (${arch})`;
  if (arch.startsWith("arm")) return `32-bit ARM (${arch})`;
  return arch;
}

function sensorName(t) {
  const raw = t.label || t.zone;
  const l = raw.toLowerCase();
  const core = /^core (\d+)$/.exec(l);
  if (core) return `Processor core ${core[1]}`;
  const pkg = /^package id (\d+)$/.exec(l);
  if (pkg) return `Processor ${parseInt(pkg[1], 10) + 1}`;
  if (["pkg", "package", "coretemp", "k10temp", "cpu"].some((word) => l.includes(word)) || l === "tctl" || l === "tdie") return "Processor";
  if (l === "acpitz") return "Motherboard";
  if (l.includes("nvme") || l === "composite") return "SSD";
  if (l.includes("pch")) return "Chipset";
  if (l.includes("wifi")) return "Wi-Fi card";
  if (l.includes("gpu")) return "Graphics";
  if (l.includes("soc")) return "Main chip";
  return raw;
}

const KNOWN_PORTS = {
  20: "File transfer (FTP)", 21: "File transfer (FTP)", 22: "Remote login (SSH)", 25: "Email sending (SMTP)",
  53: "Domain names (DNS)", 67: "IP addresses (DHCP)", 68: "IP addresses (DHCP)", 80: "Website (HTTP)",
  110: "Email (POP3)", 111: "RPC", 123: "Time sync (NTP)", 143: "Email (IMAP)", 443: "Secure website (HTTPS)",
  465: "Email sending (SMTPS)", 587: "Email sending (SMTP)", 631: "Printing (CUPS)", 993: "Email (IMAPS)",
  995: "Email (POP3S)", 1194: "VPN (OpenVPN)", 2375: "Docker", 2376: "Docker", 3306: "MySQL database",
  3389: "Remote desktop (RDP)", 5353: "Local discovery (mDNS)", 5432: "PostgreSQL database",
  5900: "Remote desktop (VNC)", 6379: "Redis", 8080: "Web (alternate)", 8443: "Secure web (alternate)",
  9090: "Prometheus", 9100: "Node exporter", 9200: "Elasticsearch", 11211: "Memcached",
  25565: "Minecraft server", 27017: "MongoDB database", 51820: "VPN (WireGuard)",
};

const portService = (p) => KNOWN_PORTS[p.port] ?? (p.process || "Unknown program");

function portIsPublic(p) {
  const i = p.bind.lastIndexOf(":");
  if (i <= 0) return true;
  const host = p.bind.slice(0, i).replace(/[[\]]/g, "").split("%")[0];
  return !(host.startsWith("127.") || host === "::1" || host === "localhost");
}

const WEEKDAY_START = /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\b/;
const IPV4 = /^\d{1,3}(\.\d{1,3}){3}$/;
const IPV6 = /^[0-9a-fA-F:]*::[0-9a-fA-F:.]*$|^([0-9a-fA-F]{1,4}:){3,}[0-9a-fA-F.:]*$/;
const DNS_NAME = /^[A-Za-z][\w-]*(\.[\w-]+)+$/;
const looksLikeHost = (s) => IPV4.test(s) || IPV6.test(s) || DNS_NAME.test(s);

function ttyWhere(tty) {
  if (tty.startsWith("pts/")) return "Remote session";
  if (tty.startsWith("tty") || tty === "console") return "Server console";
  return tty;
}

function formatDuration(days, hours, minutes) {
  if (days > 0) return hours > 0 ? `${days}d ${hours}h` : `${days}d`;
  if (hours > 0) return `${hours}h ${String(minutes).padStart(2, "0")}m`;
  if (minutes > 0) return `${minutes} min`;
  return "under a minute";
}

function describeLogin(l) {
  if (l.active) {
    const parts = l.detail.split(/\s+/).filter(Boolean);
    const host = parts.map((t) => t.replace(/[()]/g, "")).find(looksLikeHost);
    return { from: host ?? (parts.length ? ttyWhere(parts[0]) : ""), at: "", status: "Active now" };
  }
  const parts = l.detail.split(" | ").map((p) => p.trim()).filter(Boolean);
  if (parts.length === 0) return { from: "", at: "", status: "" };
  const host = parts.slice(1).find(looksLikeHost);
  const loginAt = parts.find((p) => WEEKDAY_START.test(p))?.split(" - ")[0].trim();
  if (host == null && loginAt == null) return { from: l.detail, at: "", status: "" };
  const duration = /\((?:(\d+)\+)?(\d+):(\d+)\)/.exec(l.detail);
  const status = l.detail.includes("still logged in")
    ? "Still signed in"
    : duration
      ? `Lasted ${formatDuration(parseInt(duration[1] ?? "0", 10), parseInt(duration[2], 10), parseInt(duration[3], 10))}`
      : "";
  return { from: host ?? ttyWhere(parts[0]), at: loginAt ?? "", status };
}

function friendlyElapsed(etime) {
  const m = /^(?:(\d+)-)?(\d+):(\d+)(?::(\d+))?$/.exec(etime.trim());
  if (!m) return etime;
  const days = parseInt(m[1] ?? "0", 10);
  const a = parseInt(m[2], 10);
  const b = parseInt(m[3], 10);
  const three = m[4] != null;
  return formatDuration(days, three || days > 0 ? a : 0, three || days > 0 ? b : a);
}

function ago(ts) {
  const secs = Math.floor((Date.now() - ts) / 1000);
  if (secs < 5) return "just now";
  if (secs < 60) return `${secs}s ago`;
  if (secs < 3600) return `${Math.floor(secs / 60)} min ago`;
  return `${Math.floor(secs / 3600)}h ago`;
}

function sinceDate(uptimeSec) {
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const d = new Date(Date.now() - uptimeSec * 1000);
  return `${months[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()}`;
}

function splitCronLine(raw) {
  const line = raw.trim();
  const m = /^(@\w+)\s+(.+)$/.exec(line) ?? /^(\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s+(.+)$/.exec(line);
  if (!m || m[1].includes("=")) return null;
  return [m[1].replace(/\s+/g, " "), m[2]];
}

function describeSchedule(expr) {
  const specials = {
    "@reboot": "When the server starts", "@yearly": "Once a year", "@annually": "Once a year", "@monthly": "Once a month",
    "@weekly": "Once a week", "@daily": "Every day at midnight", "@midnight": "Every day at midnight", "@hourly": "Every hour",
  };
  if (expr.startsWith("@")) return specials[expr] ?? expr;
  const f = expr.split(" ");
  if (f.length !== 5) return expr;
  const [min, hour, dom, mon, dow] = f;
  const isNum = (v) => /^\d+$/.test(v);
  const step = /^\*\/(\d+)$/;
  const anyDay = dom === "*" && mon === "*" && dow === "*";
  const time = () => `${hour.padStart(2, "0")}:${min.padStart(2, "0")}`;
  const weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
  if (min === "*" && hour === "*" && anyDay) return "Every minute";
  if (step.test(min) && hour === "*" && anyDay) return `Every ${step.exec(min)[1]} minutes`;
  if (isNum(min) && hour === "*" && anyDay) return min === "0" ? "Every hour" : `Every hour at :${min.padStart(2, "0")}`;
  if (isNum(min) && step.test(hour) && anyDay) return `Every ${step.exec(hour)[1]} hours`;
  if (isNum(min) && isNum(hour) && mon === "*") {
    if (dom === "*" && dow === "*") return `Every day at ${time()}`;
    if (dom === "*" && dow === "1-5") return `Weekdays at ${time()}`;
    if (dom === "*" && isNum(dow) && parseInt(dow, 10) <= 7) return `Every ${weekdays[parseInt(dow, 10)]} at ${time()}`;
    if (isNum(dom) && dow === "*") return `Monthly on day ${dom} at ${time()}`;
  }
  return expr;
}

function helpIcon(message) {
  return h("span", { class: "mx-help", "data-tip": message, "data-tip-wait": "250" }, icon("help-outline", 13));
}

function badge(text, color) {
  return h("span", { class: "mx-badge", style: { "--c": color }, text });
}

function pill(iconName, text, color) {
  return h("span", { class: "mx-pill", style: { "--c": color } }, icon(iconName, 12), h("span", { text }));
}

function bigValue(value, unit) {
  return h("div", { class: "mx-big" }, h("span", { class: "mx-big-value", text: value }), unit && h("span", { class: "mx-big-unit", text: "  " + unit }));
}

function progress(pct, color) {
  return h("div", { class: "mx-bar", style: { background: TRACK } }, h("div", { class: "mx-bar-fill", style: { width: clamp(pct, 0, 100) + "%", background: color ?? LEVEL_COLOR[pctLevel(pct)] } }));
}

function errorRow(message) {
  return h("div", { class: "mx-error-row" }, icon("error-outline", 14), h("span", { text: message }));
}

function spinnerBlock(padding = 18) {
  return h("div", { class: "mx-spinner-block", style: { padding: padding + "px" } }, h("div", { class: "spinner mx-spinner" }));
}

function metricHead(iconName, title, help, trailing) {
  return h(
    "div",
    { class: "mx-metric-head" },
    icon(iconName, 16),
    h("div", { class: "mx-metric-title" }, h("span", { class: "mx-metric-title-text", text: title }), help && helpIcon(help)),
    trailing,
  );
}

function metricCard({ icon: iconName, title, help, trailing, children }) {
  return h("div", { class: "mx-card mx-metric" }, metricHead(iconName, title, help, trailing), children);
}

function sectionHeader(title, subtitle) {
  return h("div", { class: "mx-section" }, h("div", { class: "mx-section-title", text: title }), h("div", { class: "mx-section-sub", text: subtitle }));
}

function cardRow(minWidth, children) {
  const el = h("div", { class: "mx-grid" }, children);
  new ResizeObserver(([entry]) => {
    const count = children.length;
    let columns = clamp(Math.floor((entry.contentRect.width + 12) / (minWidth + 12)), 1, count);
    while (columns > 1 && count % columns !== 0) columns--;
    el.style.gridTemplateColumns = `repeat(${columns}, minmax(0, 1fr))`;
  }).observe(el);
  return el;
}

function iconAction({ key, icon: iconName, tooltip, busy, onClick, refresh }) {
  const active = busy || spinning.has(key);
  return h(
    "button",
    {
      type: "button",
      class: "mx-action",
      disabled: active,
      "data-tip": active ? "Refreshing…" : tooltip,
      onClick: async () => {
        spinning.add(key);
        refresh();
        try {
          await Promise.all([onClick(), delay(400)]);
        } finally {
          spinning.delete(key);
          refresh();
        }
      },
    },
    active ? h("div", { class: "spinner mx-action-spinner" }) : icon(iconName, 15),
  );
}

function pollDotColor(state) {
  if (state.pollState === "ok") return "var(--success)";
  if (state.pollState === "error") return "var(--danger)";
  if (state.pollState === "connecting") return "var(--warning)";
  return "var(--text-faint)";
}

function statTile({ icon: iconName, title, help, value, unit, caption, level, pct }) {
  return h(
    "div",
    { class: "mx-card mx-stat" },
    h(
      "div",
      { class: "mx-stat-head" },
      icon(iconName, 16),
      h("div", { class: "mx-stat-title" }, h("span", { class: "mx-stat-title-text", text: title }), helpIcon(help)),
      level && badge(PCT_WORD[level], LEVEL_COLOR[level]),
    ),
    sp(12),
    bigValue(value, unit),
    sp(4),
    h("div", { class: "mx-label mx-caption", text: caption }),
    pct != null && h("div", { class: "mx-push" }, sp(10), progress(pct)),
  );
}

function lineChart(series, color) {
  if (series.length < 2) return h("div", { class: "mx-chart-empty", text: "Not enough readings yet" });
  let pts = series;
  const target = 240;
  if (series.length > target) {
    const bucket = series.length / target;
    pts = [];
    for (let i = 0; i < target; i++) {
      const start = Math.floor(i * bucket);
      const end = Math.min(Math.ceil((i + 1) * bucket), series.length);
      let sum = 0;
      for (let j = start; j < end; j++) sum += series[j][1];
      pts.push([series[Math.min(start, series.length - 1)][0], sum / Math.max(1, end - start)]);
    }
  }
  const W = 1000;
  const padX = 4;
  const padT = 6;
  const plotH = 100 - padT - 6;
  const minX = pts[0][0];
  const span = Math.max(1, pts[pts.length - 1][0] - minX);
  const maxY = Math.max(1, ...pts.map((p) => p[1])) * 1.15;
  const x = (t) => (padX + (W - 2 * padX) * ((t - minX) / span)).toFixed(1);
  const y = (v) => (padT + plotH * (1 - clamp(v, 0, maxY) / maxY)).toFixed(2);
  const line = pts.map((p, i) => `${i ? "L" : "M"}${x(p[0])} ${y(p[1])}`).join("");
  const guides = [0.25, 0.5, 0.75, 1]
    .map((frac) => `<line x1="${padX}" x2="${W - padX}" y1="${padT + plotH * frac}" y2="${padT + plotH * frac}" class="mx-chart-guide" vector-effect="non-scaling-stroke"/>`)
    .join("");
  const wrap = h("div", { class: "mx-chart" });
  wrap.innerHTML =
    `<svg viewBox="0 0 ${W} 100" preserveAspectRatio="none" aria-hidden="true">${guides}` +
    `<path d="${line}L${W - padX} ${padT + plotH}L${padX} ${padT + plotH}Z" style="fill: color-mix(in srgb, ${color} 14%, transparent)"/>` +
    `<path d="${line}" fill="none" style="stroke: ${color}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke"/></svg>`;
  return wrap;
}

function createDashboard(app, controller, hostId) {
  const parts = [];
  const timers = [];
  const hostOf = () => store.data().hosts.find((entry) => entry.id === hostId);
  const stateOf = () => controller.stateOf(hostId);

  const refresh = () => {
    for (const p of parts) p();
  };

  function part(className, build) {
    const el = h("div", { class: className });
    let key = null;
    parts.push(() => {
      const [nextKey, content] = build();
      if (nextKey === key) return;
      key = nextKey;
      el.replaceChildren(...[content].flat(Infinity).filter((node) => node != null && node !== false));
    });
    return el;
  }

  const sampleKey = () => String(stateOf().last?.ts ?? "");

  const header = part("mx-part", () => {
    const host = hostOf();
    const state = stateOf();
    const s = state.last;
    const needs = controller.needsCredentials(hostId);
    const updated = state.lastUpdated ? ago(state.lastUpdated) : "";
    const key = JSON.stringify([host?.name, host?.username, host?.address, host?.port, state.pollState, state.error, updated, needs, s?.ts, spinning.has("refresh:" + hostId)]);
    if (!host) return [key, null];
    const port = parseInt(host.port, 10) || 22;
    const os = s?.sysInfo?.prettyName ?? "";
    const statusPill =
      state.pollState === "ok"
        ? pill("circle", updated ? `Online · updated ${updated}` : "Online", "var(--success)")
        : state.pollState === "connecting"
          ? pill("circle", "Connecting…", "var(--warning)")
          : state.pollState === "error"
            ? pill("circle", "Offline", "var(--danger)")
            : pill("circle", "Waiting");
    return [
      key,
      h(
        "div",
        { class: "mx-card mx-header" },
        h(
          "div",
          { class: "mx-header-row" },
          h("div", { class: "mx-header-icon" }, icon("dns-outlined", 22)),
          h(
            "div",
            { class: "mx-header-text" },
            h("div", { class: "mx-header-name", text: host.name }),
            h("div", { class: "mx-header-sub", text: `${host.username}@${host.address}${port === 22 ? "" : ":" + port}` }),
          ),
          button({ variant: "outlined", icon: "terminal", iconSize: 14, label: "Terminal", className: "mx-terminal", onClick: () => app.connect(host) }),
          iconAction({
            key: "refresh:" + hostId,
            icon: "refresh",
            tooltip: "Refresh now",
            busy: state.pollState === "connecting",
            onClick: () => controller.refresh(hostId),
            refresh,
          }),
        ),
        h(
          "div",
          { class: "mx-pills" },
          statusPill,
          s?.uptimeSec != null && pill("schedule", `Running for ${formatUptime(s.uptimeSec)}`),
          os && pill("computer-outlined", os),
        ),
        state.error && h("div", { class: "mx-error-box" }, icon("error-outline", 15), h("span", { text: state.error })),
        needs &&
          h(
            "div",
            { class: "mx-signin" },
            icon("lock-outline", 18),
            h(
              "div",
              { class: "mx-signin-text" },
              h("div", { class: "mx-signin-title", text: "Sign-in needed" }),
              h("div", { class: "mx-cell", text: "Metrics are paused for this server. Enter its username and password; they are kept only until this tab closes." }),
            ),
            button({
              icon: "key",
              iconSize: 15,
              label: "Enter password",
              onClick: async () => {
                const result = await promptCredentials(host);
                if (result) controller.provideCredentials(hostId, result.username, result.password);
              },
            }),
          ),
        s && healthSummary(s),
      ),
    ];
  });

  function healthSummary(s) {
    const issues = healthIssues(s);
    const level = issues.length ? issues[0][0] : "good";
    const title = { good: "Everything looks healthy", warn: "Worth keeping an eye on", bad: "Needs attention" }[level];
    return h(
      "div",
      { class: "mx-health", style: { "--c": LEVEL_COLOR[level] } },
      icon(level === "good" ? "check-circle-outline" : "warning-amber-rounded", 18),
      h(
        "div",
        { class: "mx-health-text" },
        h("div", { class: "mx-health-title", text: title }),
        issues.length === 0
          ? h("div", { class: "mx-cell", text: "Processor, memory, disks and temperature are all within normal ranges." })
          : issues.map(([l, text]) => h("div", { class: "mx-issue" }, h("span", { class: "mx-issue-dot", style: { "--c": LEVEL_COLOR[l] } }), h("span", { class: "mx-cell", text }))),
      ),
    );
  }

  const cpuTile = part("mx-part", () => {
    const s = stateOf().last;
    const cpu = s?.cpuPct ?? null;
    const cores = coresOf(s);
    return [
      sampleKey(),
      statTile({
        icon: "memory-outlined",
        title: "Processor",
        help: "How much of the processor (CPU) is in use right now. Short spikes are normal; staying above 80% slows things down.",
        value: cpu == null ? "--" : cpu.toFixed(cpu < 10 ? 1 : 0),
        unit: "% in use",
        caption: cpu == null ? "Measuring…" : cores == null ? "Across all cores" : `Across ${cores} ${cores === 1 ? "core" : "cores"}`,
        level: cpu == null ? null : pctLevel(cpu),
        pct: cpu ?? 0,
      }),
    ];
  });

  const memoryTile = part("mx-part", () => {
    const s = stateOf().last;
    const pct = memPctOf(s);
    return [
      sampleKey(),
      statTile({
        icon: "developer-board-outlined",
        title: "Memory",
        help: "Working memory (RAM) used by running programs. When it fills up, the server slows down or starts closing programs.",
        value: pct == null ? "--" : pct.toFixed(0),
        unit: "% used",
        caption: s?.memUsedMb == null || s?.memTotalMb == null ? "Waiting for data…" : `${memF(s.memUsedMb)} of ${memF(s.memTotalMb)}`,
        level: pct == null ? null : pctLevel(pct),
        pct: pct ?? 0,
      }),
    ];
  });

  const storageTile = part("mx-part", () => {
    const d = mainDisk(stateOf().last);
    return [
      sampleKey(),
      statTile({
        icon: "save-outlined",
        title: "Storage",
        help: "Space used on the main disk. Every disk is listed under Storage below.",
        value: d ? d.pct.toFixed(0) : "--",
        unit: "% used",
        caption: d ? `${memF(Math.max(0, d.totalMb - d.usedMb))} free of ${memF(d.totalMb)}` : "Waiting for data…",
        level: d ? pctLevel(d.pct) : null,
        pct: d?.pct ?? 0,
      }),
    ];
  });

  const networkTile = part("mx-part", () => {
    const s = stateOf().last;
    return [
      sampleKey(),
      statTile({
        icon: "swap-vert",
        title: "Network",
        help: "Data the server is downloading and uploading per second, across all network cards.",
        value: s ? `↓ ${bytesF(s.netRxRate)}/s` : "--",
        unit: "",
        caption: s ? `↑ ${bytesF(s.netTxRate)}/s upload` : "Waiting for data…",
      }),
    ];
  });

  const about = part("mx-part", () => {
    const s = stateOf().last;
    const sys = s?.sysInfo;
    if (!s || !sys) return [sampleKey(), h("div", { class: "mx-card mx-pad16" }, h("span", { class: "mx-label", text: "Waiting for the first reading…" }))];
    const cores = coresOf(s);
    const storageTotal = s.disks.reduce((sum, d) => sum + d.totalMb, 0);
    const items = [
      ["computer-outlined", "Operating system", sys.prettyName],
      ["memory-outlined", "Processor", cleanCpuModel(sys.cpuModel)],
      ["grid-view", "Processor cores", cores == null ? "" : `${cores} ${cores === 1 ? "core" : "cores"}`],
      ["developer-board-outlined", "Memory (RAM)", s.memTotalMb == null ? "" : memF(s.memTotalMb)],
      ["save-outlined", "Total storage", s.disks.length === 0 ? "" : `${memF(storageTotal)}${s.disks.length > 1 ? ` on ${s.disks.length} disks` : ""}`],
      ["schedule", "Running for", s.uptimeSec == null ? "" : `${formatUptime(s.uptimeSec)} (since ${sinceDate(s.uptimeSec)})`],
      ["badge-outlined", "Server name", sys.hostname],
      ["architecture", "Architecture", archName(sys.arch)],
      ["settings-suggest-outlined", "Linux kernel", sys.kernel],
    ];
    return [
      sampleKey(),
      h(
        "div",
        { class: "mx-card mx-about" },
        h(
          "div",
          { class: "mx-about-grid" },
          items.map(([iconName, label, value]) =>
            h(
              "div",
              { class: "mx-info" },
              h("div", { class: "mx-info-icon" }, icon(iconName, 15)),
              h(
                "div",
                { class: "mx-info-text" },
                h("div", { class: "mx-label", text: label }),
                h("div", { class: ["mx-info-value", !value && "is-unknown"], text: value || "Unknown" }),
              ),
            ),
          ),
        ),
      ),
    ];
  });

  const workload = part("mx-part", () => {
    const s = stateOf().last;
    const ratio = loadRatio(s);
    const cores = coresOf(s);
    const word = ratio == null ? null : workloadWord(ratio);
    const trend = (label, load) => {
      const pct = load == null ? null : (load / (cores ?? 1)) * 100;
      return h("div", {}, h("div", { class: "mx-label", text: label }), h("div", { class: "mx-trend-value", text: pct == null ? "--" : `${Math.round(pct)}%` }));
    };
    return [
      sampleKey(),
      metricCard({
        icon: "speed",
        title: "Workload",
        help: 'How many tasks want the processor compared to how many it can run at once (Linux "load average"). Above 100% means tasks are queuing up and the server feels slow.',
        trailing: word && badge(word[1], LEVEL_COLOR[word[0]]),
        children:
          ratio == null
            ? h("span", { class: "mx-label", text: "Waiting for data…" })
            : [
                bigValue(`${Math.round(ratio * 100)}%`, "of capacity"),
                sp(4),
                h("div", {
                  class: "mx-label",
                  text: ratio <= 1 ? "The server could take on more work." : `More work than ${cores == null ? "it" : `its ${cores} cores`} can handle — some tasks are waiting.`,
                }),
                sp(10),
                progress(ratio * 100, LEVEL_COLOR[word[0]]),
                sp(14),
                h("div", { class: "mx-trend" }, trend("Last minute", s.load1), trend("Last 5 minutes", s.load5), trend("Last 15 minutes", s.load15)),
                h("div", {
                  class: "mx-foot",
                  text: `Load average: ${[s.load1, s.load5, s.load15].map((v) => (v == null ? "--" : v.toFixed(2))).join(" · ")}${cores == null ? "" : ` on ${cores} ${cores === 1 ? "core" : "cores"}`}`,
                }),
              ],
      }),
    ];
  });

  const temps = part("mx-part", () => {
    const s = stateOf().last;
    const list = [...(s?.temps ?? [])].sort((a, b) => b.celsius - a.celsius);
    const hottest = list[0];
    const word = hottest ? tempWord(hottest.celsius) : null;
    return [
      sampleKey(),
      metricCard({
        icon: "thermostat",
        title: "Temperature",
        help: "Readings from the hardware sensors. Most servers are fine below 75°C.",
        trailing: word && badge(word[1], LEVEL_COLOR[word[0]]),
        children: !s
          ? h("span", { class: "mx-label", text: "Waiting for data…" })
          : !hottest
            ? h("div", { class: "mx-cell", text: "This server doesn't report any temperature sensors. That's normal for virtual and cloud servers." })
            : [
                bigValue(`${hottest.celsius.toFixed(0)}°C`, `hottest · ${sensorName(hottest)}`),
                sp(12),
                list.slice(1, 6).map((t) => {
                  const [level] = tempWord(t.celsius);
                  return h(
                    "div",
                    { class: "mx-temp-row" },
                    h("span", { class: "mx-cell mx-ellipsis", text: sensorName(t) }),
                    h("span", { class: "mx-temp-value", style: { color: level === "good" ? "var(--text-secondary)" : LEVEL_COLOR[level] }, text: `${t.celsius.toFixed(0)}°C` }),
                  );
                }),
              ],
      }),
    ];
  });

  const disks = part("mx-part", () => {
    const s = stateOf().last;
    const list = [...(s?.disks ?? [])].sort((a, b) => ((a.mount === "/") !== (b.mount === "/") ? (a.mount === "/" ? -1 : 1) : b.totalMb - a.totalMb));
    if (list.length === 0) return [sampleKey(), h("div", { class: "mx-card mx-pad16" }, h("span", { class: "mx-label", text: s ? "No disks found" : "Waiting for data…" }))];
    return [
      sampleKey(),
      h(
        "div",
        { class: "mx-card mx-pad16" },
        list.slice(0, 8).map((disk, i) => {
          const level = pctLevel(disk.pct);
          const name = diskName(disk);
          return [
            i > 0 && h("div", { class: "mx-divider" }),
            h(
              "div",
              { class: "mx-disk" },
              h(
                "div",
                { class: "mx-disk-head" },
                icon(disk.device.includes(":") ? "cloud-outlined" : "save-outlined", 16),
                h(
                  "div",
                  { class: "mx-disk-names" },
                  h("span", { class: "mx-disk-name", text: name }),
                  h("span", { class: "mx-label mx-disk-device", text: disk.mount === name ? disk.device : `${disk.mount} · ${disk.device}` }),
                ),
                level !== "good" && badge(level === "bad" ? "Almost full" : "Filling up", LEVEL_COLOR[level]),
                h("span", { class: "mx-disk-pct", text: `${disk.pct.toFixed(0)}% used` }),
              ),
              sp(8),
              progress(disk.pct),
              sp(6),
              h("div", { class: "mx-label", text: `${memF(disk.usedMb)} used · ${memF(Math.max(0, disk.totalMb - disk.usedMb))} free · ${memF(disk.totalMb)} total` }),
            ),
          ];
        }),
      ),
    ];
  });

  const procs = part("mx-part", () => {
    const s = stateOf().last;
    const list = s?.procs ?? [];
    const hasMem = list.some((p) => p.mem != null);
    const hasElapsed = list.some((p) => p.elapsed);
    return [
      sampleKey(),
      metricCard({
        icon: "apps",
        title: "Busiest programs",
        help: "The programs using the most processor time right now.",
        trailing: s?.procCount != null && h("span", { class: "mx-label", text: `${s.procCount} running in total` }),
        children:
          list.length === 0
            ? h("span", { class: "mx-label", text: "Waiting for data…" })
            : [
                h(
                  "div",
                  { class: "mx-table-head" },
                  h("span", { class: "mx-col-name", text: "Program" }),
                  h("span", { class: "mx-col-cpu", text: "Processor" }),
                  hasMem && h("span", { class: "mx-col-mem", text: "Memory" }),
                  hasElapsed && h("span", { class: "mx-col-elapsed", text: "Running for" }),
                ),
                list.slice(0, 10).map((p) =>
                  h(
                    "div",
                    { class: "mx-proc" },
                    h("span", { class: "mx-col-name mx-proc-name", text: p.name }),
                    h("span", { class: "mx-col-cpu", style: { color: (p.cpu ?? 0) > 50 ? "var(--warning)" : "var(--text-secondary)" }, text: p.cpu == null ? "--" : `${p.cpu.toFixed(1)}%` }),
                    hasMem && h("span", { class: "mx-col-mem mx-cell", text: p.mem == null ? "--" : `${p.mem.toFixed(1)}%` }),
                    hasElapsed && h("span", { class: "mx-col-elapsed mx-label", text: friendlyElapsed(p.elapsed) }),
                  ),
                ),
              ],
      }),
    ];
  });

  const portRow = (p) => {
    const service = portService(p);
    const details = [p.proto.toUpperCase(), p.process && service !== p.process && p.process].filter(Boolean).join(" · ");
    return h(
      "div",
      { class: "mx-port" },
      h("span", { class: "mx-port-number", text: String(p.port) }),
      h("span", { class: "mx-port-text" }, h("span", { class: "mx-port-service", text: service }), h("span", { class: "mx-label", text: "  " + details })),
      portIsPublic(p) ? badge("Reachable", "var(--info)") : badge("This server only", "var(--text-faint)"),
    );
  };

  function openPortsDialog(ports) {
    const reachable = ports.filter(portIsPublic).length;
    openDialog({
      title: "Open ports",
      className: "mx-ports-dialog",
      content: () => {
        const list = h("div", { class: "mx-ports-list" });
        const render = (query) => {
          const q = query.trim().toLowerCase();
          const shown = ports.filter((p) => !q || `${p.port} ${portService(p)} ${p.process} ${p.proto}`.toLowerCase().includes(q));
          list.replaceChildren(...(shown.length ? shown.map(portRow) : [h("div", { class: "mx-ports-empty mx-label", text: "No matching ports" })]));
        };
        render("");
        return h(
          "div",
          { class: "mx-ports-body" },
          h("div", { class: "mx-label", text: `${ports.length} open · ${reachable} reachable from other computers` }),
          sp(10),
          searchInput("Search by port, service or program", render, true),
          sp(12),
          list,
        );
      },
      actions: [{ label: "Close" }],
    });
  }

  const ports = part("mx-part", () => {
    const s = stateOf().last;
    const list = [...(s?.ports ?? [])].sort((a, b) => a.port - b.port);
    return [
      sampleKey(),
      metricCard({
        icon: "cable",
        title: "Open ports",
        help: 'Ports are doors that let other computers reach a program on this server. "Reachable" ports accept outside connections; "This server only" ports can only be used locally.',
        trailing: list.length > 0 && h("span", { class: "mx-label", text: `${list.length} open` }),
        children: !s
          ? h("span", { class: "mx-label", text: "Waiting for data…" })
          : list.length === 0
            ? h("div", { class: "mx-cell", text: "No open ports reported (listing them may need admin rights)." })
            : [
                list.slice(0, 10).map(portRow),
                list.length > 10 &&
                  h(
                    "div",
                    { class: "mx-push" },
                    button({ variant: "text", icon: "list", iconSize: 15, label: `Show all ${list.length} ports`, className: "mx-link-btn", onClick: () => openPortsDialog(list) }),
                  ),
              ],
      }),
    ];
  });

  const logins = part("mx-part", () => {
    const s = stateOf().last;
    if (!s) return [sampleKey(), h("div", { class: "mx-card mx-pad16" }, h("span", { class: "mx-label", text: "Waiting for data…" }))];
    const active = s.logins.filter((l) => l.active);
    const recent = s.logins.filter((l) => !l.active).slice(0, 10);
    const avatar = (l) => h("span", { class: ["mx-avatar", l.active && "is-active"] }, icon("person-outline", 14));
    const status = (l, info) => (l.active ? badge("Active now", "var(--success)") : h("span", { class: "mx-cell mx-ellipsis", text: info.status }));
    const wideRow = (l) => {
      const info = describeLogin(l);
      return h(
        "div",
        { class: "mx-login-row mx-login-wide" },
        h("span", { class: "mx-login-avatar-col" }, avatar(l)),
        h("span", { class: "mx-login-user mx-login-user-col", text: l.user }),
        h("span", { class: "mx-cell mx-login-flex", text: info.from }),
        h("span", { class: "mx-cell mx-login-flex", text: info.at || "—" }),
        h("span", { class: "mx-login-status-col" }, status(l, info)),
      );
    };
    const narrowRow = (l) => {
      const info = describeLogin(l);
      const second = [info.at, !l.active && info.status].filter(Boolean).join(" · ");
      return h(
        "div",
        { class: "mx-login-narrow mx-login-compact" },
        avatar(l),
        h(
          "div",
          { class: "mx-login-lines" },
          h("div", { class: "mx-ellipsis" }, h("span", { class: "mx-login-user", text: l.user }), info.from && h("span", { class: "mx-cell", text: "  " + info.from })),
          second && h("div", { class: "mx-label mx-ellipsis", text: second }),
        ),
        l.active && status(l, info),
      );
    };
    const headerRow = () =>
      h(
        "div",
        { class: "mx-login-head mx-login-wide" },
        h("span", { class: "mx-login-avatar-col" }),
        h("span", { class: "mx-login-user-col", text: "User" }),
        h("span", { class: "mx-login-flex", text: "Connected from" }),
        h("span", { class: "mx-login-flex", text: "Signed in at" }),
        h("span", { class: "mx-login-status-col", text: "Session" }),
      );
    const group = (title, rows, emptyText) => [
      h("div", { class: "mx-login-group" }, h("span", { class: "mx-login-group-title", text: title }), h("span", { class: "mx-label", text: String(rows.length) })),
      rows.length === 0 ? h("div", { class: "mx-cell", text: emptyText }) : [headerRow(), rows.map(wideRow), rows.map(narrowRow)],
    ];
    return [
      sampleKey(),
      h(
        "div",
        { class: "mx-card mx-logins" },
        h("div", {}, group("Signed in now", active, "Nobody is signed in right now."), sp(18), group("Recent sign-ins", recent, "No recent sign-ins recorded.")),
      ),
    ];
  });

  function historySection() {
    const ranges = [
      [1, "Last hour"],
      [24, "Last day"],
      [168, "Last week"],
    ];
    let rangeHours = 24;
    let rows = null;
    let error = null;

    const el = h("div", { class: "mx-card mx-history" });
    const chips = h("div", { class: "mx-range-chips" });
    const body = h("div", { class: "mx-history-body" });
    el.append(h("div", { class: "mx-history-head" }, chips, h("span", { class: "mx-label", text: "Updates automatically" })), body);

    const render = () => {
      chips.replaceChildren(
        ...ranges.map(([hours, label]) =>
          h("button", {
            type: "button",
            class: ["mx-range-chip", hours === rangeHours && "is-selected"],
            text: label,
            onClick: () => {
              rangeHours = hours;
              render();
            },
          }),
        ),
      );
      if (error) {
        body.replaceChildren(h("div", { class: "mx-error-text", text: error }));
        return;
      }
      if (rows == null) {
        body.replaceChildren(spinnerBlock(28));
        return;
      }
      const since = Date.now() - rangeHours * 3600 * 1000;
      const inRange = rows.filter((r) => r.ts > since);
      if (inRange.length === 0) {
        body.replaceChildren(h("div", { class: "mx-history-empty mx-label", text: "No readings in this time range yet.\nTracked servers record data automatically." }));
        return;
      }
      const pctF = (v) => `${v.toFixed(0)}%`;
      const rateF = (v) => `${bytesF(v)}/s`;
      const seriesOf = (field) => inRange.filter((r) => r[field] != null).map((r) => [r.ts, r[field]]);
      const charts = [
        ["Processor usage", seriesOf("cpuPct"), "var(--success)", pctF],
        ["Memory usage", seriesOf("memPct"), "var(--accent)", pctF],
        ["System disk usage", seriesOf("diskPct"), "var(--warning)", pctF],
        ["Workload (load average)", seriesOf("load1"), "var(--warning)", (v) => v.toFixed(2)],
        ["Download speed", seriesOf("netRx"), "var(--info)", rateF],
        ["Upload speed", seriesOf("netTx"), "var(--accent)", rateF],
      ];
      const temp = seriesOf("temp");
      if (temp.length >= 2) charts.push(["Temperature", temp, "var(--danger)", (v) => `${v.toFixed(0)}°C`]);
      body.replaceChildren(
        h(
          "div",
          { class: "mx-charts" },
          charts.map(([title, series, color, format]) => {
            let sum = 0;
            let peak = -Infinity;
            for (const [, v] of series) {
              sum += v;
              peak = Math.max(peak, v);
            }
            return h(
              "div",
              { class: "mx-history-chart" },
              h(
                "div",
                { class: "mx-chart-head" },
                h("span", { class: "mx-chart-title", text: title }),
                series.length > 0 && h("span", { class: "mx-label", text: `average ${format(sum / series.length)} · peak ${format(peak)}` }),
              ),
              sp(6),
              lineChart(series, color),
            );
          }),
        ),
      );
    };

    const load = async () => {
      try {
        rows = await controller.history(hostId, Date.now() - 168 * 3600 * 1000);
        error = null;
      } catch (err) {
        error = String(err?.message || err);
      }
      render();
    };
    load();
    timers.push(setInterval(load, 15000));
    render();
    return el;
  }

  function searchInput(placeholder, onInput, autofocus) {
    const input = h("input", { class: "mx-search-input", placeholder, spellcheck: false });
    if (autofocus) input.setAttribute("autofocus", "");
    input.addEventListener("input", () => onInput(input.value));
    return h("label", { class: "mx-search" }, icon("search", 16), input);
  }

  function servicesCard() {
    const pageSizes = [10, 20, 40, 80];
    let query = "";
    let page = 0;
    let pageSize = 10;
    let mode = null;
    let listKey = null;
    let trailingKey = null;

    const trailing = h("div", { class: "mx-metric-trailing" });
    const body = h("div", { class: "mx-metric-body" });
    const listRegion = h("div");
    const filter = searchInput("Filter services", (value) => {
      query = value;
      page = 0;
      update();
    });
    const el = h("div", { class: "mx-card mx-metric" }, metricHead("settings", "System services", null, trailing), body);

    function pager(total) {
      const pageCount = Math.max(1, Math.ceil(total / pageSize));
      const from = total === 0 ? 0 : page * pageSize + 1;
      const to = Math.min(total, (page + 1) * pageSize);
      const nav = (iconName, tooltip, target) =>
        iconButton({ icon: iconName, size: 18, tooltip, className: "mx-pager-btn", disabled: target == null, onClick: () => ((page = target), update()) });
      const select = h(
        "select",
        { class: "mx-select" },
        pageSizes.map((size) => h("option", { value: String(size), text: String(size) })),
      );
      select.value = String(pageSize);
      select.addEventListener("change", () => {
        const size = parseInt(select.value, 10);
        page = Math.floor((page * pageSize) / size);
        pageSize = size;
        update();
      });
      return h(
        "div",
        { class: "mx-pager" },
        h("div", { class: "mx-pager-group" }, h("span", { class: "mx-label", text: "Rows per page" }), select),
        h(
          "div",
          { class: "mx-pager-group is-tight" },
          h("span", { class: "mx-pager-range", text: `${from}–${to} of ${total}` }),
          nav("first-page", "First page", page > 0 ? 0 : null),
          nav("chevron-left", "Previous page", page > 0 ? page - 1 : null),
          h("span", { class: "mx-label mx-pager-page", text: `Page ${page + 1} of ${pageCount}` }),
          nav("chevron-right", "Next page", page < pageCount - 1 ? page + 1 : null),
          nav("last-page", "Last page", page < pageCount - 1 ? pageCount - 1 : null),
        ),
      );
    }

    function serviceRow(unit, busy) {
      const failed = unit.active === "failed";
      const running = unit.active === "active";
      const color = failed ? "var(--danger)" : running ? "var(--success)" : "var(--text-faint)";
      const actions = running
        ? [["Restart", "restart"], ["Stop", "stop"]]
        : [["Start", "start"], ["Enable", "enable"]];
      const words = { active: "Running", inactive: "Stopped", failed: "Failed", activating: "Starting…", deactivating: "Stopping…" };
      return h(
        "div",
        { class: "mx-service" },
        h("span", { class: "mx-service-dot", style: { background: color } }),
        h(
          "div",
          { class: "mx-service-text" },
          h("div", { class: "mx-service-name", text: unit.description || unit.unit }),
          unit.description && h("div", { class: "mx-service-unit", text: unit.unit }),
        ),
        h("span", { class: "mx-service-state", style: { color }, text: words[unit.active] ?? unit.active }),
        h(
          "div",
          { class: "mx-service-actions" },
          actions.map(([label, action]) =>
            h("button", {
              type: "button",
              class: "mx-chip-btn",
              text: label,
              disabled: busy,
              "data-tip": `systemctl ${action}`,
              onClick: async () => {
                const error = await controller.serviceAction(hostId, unit.unit, action);
                if (error) snackbar(error);
              },
            }),
          ),
        ),
      );
    }

    function update() {
      const st = controller.servicesOf(hostId);
      const pending = controller.cardsPending(hostId);
      const pollError = controller.stateOf(hostId).pollState === "error";

      const nextTrailingKey = JSON.stringify([st.loading, spinning.has("services:" + hostId)]);
      if (nextTrailingKey !== trailingKey) {
        trailingKey = nextTrailingKey;
        trailing.replaceChildren(
          iconAction({ key: "services:" + hostId, icon: "refresh", tooltip: "Refresh services", busy: st.loading, onClick: () => controller.loadServices(hostId), refresh }),
        );
      }

      let next;
      if (pending && pollError && st.units.length === 0) next = "offline";
      else if ((st.loading || pending) && st.units.length === 0) next = "loading";
      else if (st.error) next = "error:" + st.error;
      else if (st.unsupported) next = "unsupported";
      else if (st.units.length === 0) next = "empty";
      else next = "list";

      if (next !== mode) {
        mode = next;
        listKey = null;
        if (next === "offline") body.replaceChildren(h("div", { class: "mx-cell", text: "Can't reach the server right now. Services will load as soon as it connects." }));
        else if (next === "loading") body.replaceChildren(spinnerBlock());
        else if (next.startsWith("error:")) body.replaceChildren(errorRow(st.error));
        else if (next === "unsupported") body.replaceChildren(h("div", { class: "mx-cell", text: "This server doesn't use systemd, so services can't be managed from here." }));
        else if (next === "empty") body.replaceChildren(h("div", { class: "mx-cell", text: "No services found." }));
        else body.replaceChildren(filter, sp(8), listRegion);
      }
      if (mode !== "list") return;

      const q = query.toLowerCase();
      const units = st.units.filter((s) => s.unit.toLowerCase().includes(q) || s.description.toLowerCase().includes(q));
      const pageCount = Math.max(1, Math.ceil(units.length / pageSize));
      page = clamp(page, 0, pageCount - 1);
      const nextListKey = JSON.stringify([st.units, st.loading, query, page, pageSize]);
      if (nextListKey === listKey) return;
      listKey = nextListKey;
      if (units.length === 0) {
        listRegion.replaceChildren(h("div", { class: "mx-cell mx-no-match", text: `No services match "${query}".` }));
        return;
      }
      const visible = units.slice(page * pageSize, (page + 1) * pageSize);
      listRegion.replaceChildren(...visible.map((unit) => serviceRow(unit, st.loading)), sp(6), pager(units.length));
    }

    parts.push(update);
    return el;
  }

  function openCronDialog() {
    const presets = [
      ["Every minute", "* * * * *"],
      ["Every hour", "0 * * * *"],
      ["Daily at midnight", "0 0 * * *"],
      ["Weekly (Sunday 00:00)", "0 0 * * 0"],
      ["Monthly (1st 00:00)", "0 0 1 * *"],
    ];
    let schedule = "";
    let custom = false;
    let addButton = null;
    let commandField = null;
    return openDialog({
      title: "Add cron job",
      className: "mx-cron-dialog",
      content: () => {
        const chipRow = h("div", { class: "mx-choices" });
        const expression = textField({ label: "Cron expression", hint: "* * * * *", mono: true, onInput: (v) => ((schedule = v.trim()), sync()) });
        const expressionWrap = h("div", {}, sp(10), expression.el);
        const command = textField({ hint: "e.g. /usr/local/bin/backup.sh > /var/log/backup.log 2>&1", multiline: true, rows: 3, mono: true, onInput: () => sync() });
        const preview = h("div", { class: "mx-label" });
        const sync = () => {
          chipRow.replaceChildren(
            ...presets.map(([label, expr]) => choice(label, !custom && expr === schedule, () => ((custom = false), (schedule = expr), sync()))),
            choice("Custom", custom, () => ((custom = true), (schedule = expression.value.trim()), sync())),
          );
          expressionWrap.hidden = !custom;
          preview.textContent =
            custom && !schedule ? "Preset or expression required." : `Preview: ${schedule || "<schedule>"} ${command.value || "<command>"}`;
          if (addButton) addButton.disabled = !command.value.trim() || !schedule.trim();
        };
        const choice = (label, selected, onSelect) =>
          h("button", { type: "button", class: ["mx-choice", selected && "is-selected"], onClick: onSelect }, selected && icon("check", 14), h("span", { text: label }));
        sync();
        commandField = command;
        return h("div", { class: "stack" }, chipRow, expressionWrap, sp(10), h("div", { class: "mx-label", text: "Command" }), sp(4), command.el, sp(8), preview);
      },
      actions: [
        { label: "Cancel", value: null },
        {
          label: "Add",
          variant: "filled",
          disabled: true,
          ref: (node) => (addButton = node),
          onClick: (close) => {
            if (!schedule.trim() || !commandField.value.trim()) return;
            close([schedule.trim(), commandField.value.trim()]);
          },
        },
      ],
    });
  }

  const cron = part("mx-part", () => {
    const st = controller.cronOf(hostId);
    const pending = controller.cardsPending(hostId);
    const pollError = controller.stateOf(hostId).pollState === "error";
    const key = JSON.stringify([st, pending, pollError, spinning.has("cron:" + hostId)]);
    const lines = st.crontab.split("\n").filter((l) => l.trim());
    const empty = !st.crontab.trim();

    const write = async (body) => {
      const error = await controller.writeCron(hostId, body);
      if (error) snackbar(`Failed to write crontab: ${error}`);
    };

    let children;
    if (pending && pollError && empty) {
      children = h("div", { class: "mx-cell", text: "Can't reach the server right now. Scheduled tasks will load as soon as it connects." });
    } else if ((st.loading || pending) && empty) {
      children = spinnerBlock();
    } else if (st.error) {
      children = errorRow(st.error);
    } else {
      children = [
        h(
          "div",
          { class: "mx-cron-actions" },
          button({
            variant: "outlined",
            icon: "add",
            iconSize: 13,
            label: "Add task",
            className: "mx-add-task",
            onClick: async () => {
              const result = await openCronDialog();
              if (!result) return;
              const [schedule, command] = result;
              if (!schedule || !command) return;
              const current = controller.cronOf(hostId).crontab.trimEnd();
              const line = `${schedule} ${command}`;
              write(current ? `${current}\n${line}` : line);
            },
          }),
        ),
        sp(8),
        empty
          ? h("div", { class: "mx-cell", text: "No scheduled tasks yet." })
          : lines.map((raw, i) => {
              const comment = raw.trimStart().startsWith("#");
              const job = comment ? null : splitCronLine(raw);
              return h(
                "div",
                { class: ["mx-cron", comment && "is-comment"] },
                h(
                  "div",
                  { class: "mx-cron-text" },
                  job == null
                    ? h("div", { class: "mx-mono mx-selectable", text: raw })
                    : [
                        h(
                          "div",
                          {},
                          h("span", { class: "mx-cron-when", text: describeSchedule(job[0]) }),
                          describeSchedule(job[0]) !== job[0] && h("span", { class: "mx-mono mx-cron-expr", text: "   " + job[0] }),
                        ),
                        sp(2),
                        h("div", { class: "mx-mono mx-selectable", text: job[1] }),
                      ],
                ),
                !comment &&
                  iconButton({
                    icon: "delete-outline",
                    size: 14,
                    tooltip: "Delete job",
                    className: "mx-cron-delete",
                    disabled: st.loading,
                    onClick: () => write(lines.filter((_, index) => index !== i).filter((l) => l.trim()).join("\n")),
                  }),
              );
            }),
      ];
    }
    return [
      key,
      metricCard({
        icon: "schedule",
        title: "Crontab",
        trailing: iconAction({ key: "cron:" + hostId, icon: "refresh", tooltip: "Refresh scheduled tasks", busy: st.loading, onClick: () => controller.loadCron(hostId), refresh }),
        children,
      }),
    ];
  });

  const el = h(
    "div",
    { class: "mx-dash" },
    header,
    sectionHeader("At a glance", "Live readings, refreshed automatically."),
    cardRow(210, [cpuTile, memoryTile, storageTile, networkTile]),
    sectionHeader("About this server", "The hardware and software this server runs on."),
    about,
    sectionHeader("Workload & temperature", "How hard the server is working and how warm it runs."),
    cardRow(380, [workload, temps]),
    sectionHeader("Storage", "Space used and free on each disk."),
    disks,
    sectionHeader("What's running", "Programs using the most processor time, and the ports other computers can connect to."),
    cardRow(380, [procs, ports]),
    sectionHeader("Sign-ins", "Who is signed in to this server now, and recently."),
    logins,
    sectionHeader("History", "Readings saved in this browser while the server is tracked."),
    historySection(),
    sectionHeader("Services", "Background programs managed by systemd. You can start, stop or restart them here."),
    servicesCard(),
    sectionHeader("Scheduled tasks", "Commands that run automatically on a schedule (this user's crontab)."),
    cron,
    sp(16),
  );
  refresh();

  return {
    el,
    hostId,
    update: refresh,
    destroy() {
      for (const timer of timers) clearInterval(timer);
    },
  };
}

export function createMetricsScreen(app) {
  const controller = metricsController(app);
  const el = h("section", { class: "screen metrics-screen" });
  const railList = h("div", { class: "metrics-rail-list" });
  const chips = h("div", { class: "metrics-chips" });
  const main = h("div", { class: "metrics-main" }, chips);
  let dashboard = null;
  let railKey = null;
  let chipsKey = null;

  el.append(
    h(
      "div",
      { class: "metrics" },
      h(
        "div",
        { class: "metrics-rail" },
        h(
          "div",
          { class: "metrics-rail-head" },
          h("span", { class: "metrics-rail-title", text: "SERVERS" }),
          h("button", { type: "button", class: "metrics-add", "data-tip": "Add server", onClick: openTrackDialog }, icon("add", 14)),
        ),
        railList,
      ),
      main,
    ),
  );

  const tracked = () => {
    const data = store.data();
    return watchlistOf(data.settings)
      .map((id) => data.hosts.find((host) => host.id === id))
      .filter(Boolean);
  };

  function toggleWatch(hostId) {
    let added = false;
    return app
      .save((d) => {
        const list = watchlistOf(d.settings);
        const index = list.indexOf(hostId);
        if (index >= 0) list.splice(index, 1);
        else {
          list.push(hostId);
          added = true;
        }
        d.settings.metricsWatchlist = JSON.stringify(list);
      })
      .then((ok) => {
        if (ok && added) controller.select(hostId);
      });
  }

  function railTile(host) {
    const s = controller.stateOf(host.id);
    const sample = s.last;
    const selected = host.id === controller.selectedId;
    const [statusText, statusColor] =
      s.pollState === "error"
        ? [s.error ?? "Offline", "var(--danger)"]
        : s.pollState === "connecting"
          ? ["Connecting…", "var(--warning)"]
          : [`${host.username}@${host.address}`, "var(--text-faint)"];
    const meter = (label, value) =>
      h(
        "div",
        { class: "rail-meter" },
        h("span", { class: "rail-meter-label", text: label }),
        h("span", { class: "rail-meter-track", style: { background: TRACK } }, h("span", { class: "rail-meter-fill", style: { width: clamp(value ?? 0, 0, 100) + "%", background: LEVEL_COLOR[pctLevel(value ?? 0)] } })),
        h("span", { class: "rail-meter-value", text: value == null ? "--" : `${value.toFixed(0)}%` }),
      );
    const rate = (iconName, color, value, what) =>
      h("span", { class: "rail-rate", "data-tip": `${what} speed` }, h("span", { class: "rail-rate-icon", style: { color } }, icon(iconName, 11)), h("span", { class: "mx-ellipsis", text: `${bytesF(value)}/s` }));
    return h(
      "button",
      { type: "button", class: ["rail-tile", selected && "is-selected"], onClick: () => controller.select(host.id) },
      h(
        "span",
        { class: "rail-tile-row" },
        h("span", { class: "rail-dot", style: { background: pollDotColor(s) } }),
        h("span", { class: "rail-name", text: host.name }),
        h(
          "span",
          {
            class: "rail-remove",
            role: "button",
            "data-tip": "Stop tracking",
            onClick: (event) => {
              event.stopPropagation();
              toggleWatch(host.id);
            },
          },
          icon("close", 14),
        ),
      ),
      h("span", { class: "rail-status", style: { color: statusColor }, text: statusText }),
      sample &&
        h(
          "span",
          { class: ["rail-meters", s.pollState === "error" && "is-stale"] },
          meter("CPU", sample.cpuPct),
          meter("RAM", memPctOf(sample)),
          h("span", { class: "rail-rates" }, rate("arrow-downward", "var(--success)", sample.netRxRate, "Download"), rate("arrow-upward", "var(--info)", sample.netTxRate, "Upload")),
        ),
    );
  }

  function render() {
    if (el.hidden) return;
    const hosts = tracked();
    const selectedId = controller.selectedId;

    const nextRailKey = JSON.stringify([selectedId, hosts.map((host) => [host.id, host.name, host.username, host.address, controller.stateOf(host.id)])]);
    if (nextRailKey !== railKey) {
      railKey = nextRailKey;
      railList.replaceChildren(
        ...(hosts.length
          ? hosts.map(railTile)
          : [
              h(
                "div",
                { class: "metrics-rail-empty" },
                icon("query-stats-outlined", 32),
                h("div", { class: "metrics-rail-empty-title", text: "No servers tracked" }),
                h("div", { class: "metrics-rail-empty-text", text: "Add a saved host to start collecting metrics." }),
              ),
            ]),
      );
    }

    const nextChipsKey = JSON.stringify([selectedId, hosts.map((host) => [host.id, host.name, controller.stateOf(host.id).pollState])]);
    if (nextChipsKey !== chipsKey) {
      chipsKey = nextChipsKey;
      chips.replaceChildren(
        ...hosts.map((host) =>
          h(
            "button",
            { type: "button", class: ["mx-chip", host.id === selectedId && "is-selected"], onClick: () => controller.select(host.id) },
            h("span", { class: "mx-chip-dot", style: { background: pollDotColor(controller.stateOf(host.id)) } }),
            h("span", { text: host.name }),
            h(
              "span",
              {
                class: "mx-chip-close",
                role: "button",
                onClick: (event) => {
                  event.stopPropagation();
                  toggleWatch(host.id);
                },
              },
              icon("close", 13),
            ),
          ),
        ),
        h("button", { type: "button", class: "mx-chip is-add", onClick: openTrackDialog }, icon("add", 14), h("span", { text: "Add" })),
      );
    }

    const selectedHost = hosts.find((host) => host.id === selectedId);
    const wanted = selectedHost ? selectedHost.id : null;
    if (!dashboard || dashboard.hostId !== wanted) {
      dashboard?.destroy();
      dashboard = wanted ? createDashboard(app, controller, wanted) : emptyDashboard();
      main.replaceChildren(chips, dashboard.el);
    } else {
      dashboard.update();
    }
  }

  function emptyDashboard() {
    return {
      hostId: null,
      el: h(
        "div",
        { class: "mx-empty" },
        icon("query-stats-outlined", 42),
        h("div", { class: "mx-empty-title", text: "Track a server to see its metrics" }),
        h("div", { class: "mx-empty-text", text: "Use the add button to pick from your saved hosts.\nEach host is polled over SSH; history is stored in this browser." }),
      ),
      update() {},
      destroy() {},
    };
  }

  function openTrackDialog() {
    openDialog({
      className: "track-dialog",
      content: (close) => {
        let query = "";
        const list = h("div", { class: "track-body" });
        const footText = h("span");

        const renderList = () => {
          const data = store.data();
          const trackedIds = new Set(watchlistOf(data.settings));
          const q = query.trim().toLowerCase();
          const hosts = data.hosts.filter((host) => !q || [host.name, host.address, host.username, host.tags].some((v) => (v || "").toLowerCase().includes(q)));
          const count = data.hosts.filter((host) => trackedIds.has(host.id)).length;
          footText.textContent = count === 0 ? "No servers tracked yet" : `${count} ${count === 1 ? "server" : "servers"} tracked`;

          if (data.hosts.length === 0) {
            list.replaceChildren(h("div", { class: "mx-empty" }, icon("dns-outlined", 36), h("div", { class: "metrics-rail-empty-title", text: "No saved hosts yet" })));
            return;
          }
          if (hosts.length === 0) {
            list.replaceChildren(h("div", { class: "no-matches", text: `No servers match "${query}".` }));
            return;
          }
          list.replaceChildren(
            ...hosts.map((host) => {
              const color = colorFromInt(host.color) || "#3ddc97";
              const toggle = checkbox({ checked: trackedIds.has(host.id), label: host.name });
              const row = h(
                "label",
                { class: "track-row" },
                h("span", { class: "track-row-icon", style: { background: `color-mix(in srgb, ${color} 16%, transparent)`, color } }, icon(osIconName(host.os), 18)),
                h(
                  "span",
                  { class: "track-row-text" },
                  h("span", { class: "track-row-name", text: host.name }),
                  h("span", { class: "track-row-sub", text: `${host.username ? host.username + "@" : ""}${host.address}` }),
                ),
                toggle.el,
              );
              toggle.input.addEventListener("change", () => toggleWatch(host.id).then(renderList));
              return row;
            }),
          );
        };

        const search = textField({
          hint: "Search hosts, groups, addresses, tags...",
          prefixIcon: "search",
          onInput: (value) => {
            query = value;
            renderList();
          },
        });
        renderList();

        return h(
          "div",
          { class: "stack track-layout" },
          h(
            "div",
            { class: "track-head" },
            h("span", { class: "track-head-icon" }, icon("query-stats", 19)),
            h(
              "span",
              { class: "stack track-head-text" },
              h("span", { class: "track-head-title", text: "Add servers to monitor" }),
              h("span", { class: "track-head-sub", text: "Pick from your saved hosts. Metrics are collected over SSH." }),
            ),
            iconButton({ icon: "close", size: 18, tooltip: "Close", onClick: () => close() }),
          ),
          h("div", { class: "track-search" }, search.el),
          list,
          h("div", { class: "track-foot" }, footText, button({ label: "Done", onClick: () => close() })),
        );
      },
    });
  }

  controller.onChange(render);

  return {
    el,
    update: render,
    show() {
      controller.start();
      render();
    },
  };
}
