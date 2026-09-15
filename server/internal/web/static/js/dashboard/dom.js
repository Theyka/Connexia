const SVG_NS = "http://www.w3.org/2000/svg";
const SPRITE = "/assets/img/app-icons.svg";

const DOM_PROPERTIES = new Set([
  "value", "checked", "disabled", "readOnly", "type", "placeholder", "rows",
  "maxLength", "tabIndex", "htmlFor", "spellcheck", "autofocus", "draggable",
]);

export function h(tag, props, ...children) {
  const el = document.createElement(tag);
  if (props) {
    applyProps(el, props);
  }
  append(el, children);
  return el;
}

function applyProps(el, props) {
  for (const [key, value] of Object.entries(props)) {
    if (value == null || value === false) {
      continue;
    }
    if (key === "class") {
      el.className = Array.isArray(value) ? value.filter(Boolean).join(" ") : value;
    } else if (key === "text") {
      el.textContent = value;
    } else if (key === "style") {
      for (const [name, v] of Object.entries(value)) {
        if (v == null) continue;
        if (name.startsWith("--")) el.style.setProperty(name, v);
        else el.style[name] = v;
      }
    } else if (key === "dataset") {
      Object.assign(el.dataset, value);
    } else if (key.startsWith("on") && typeof value === "function") {
      el.addEventListener(key.slice(2).toLowerCase(), value);
    } else if (DOM_PROPERTIES.has(key)) {
      el[key] = value;
    } else {
      el.setAttribute(key, value === true ? "" : value);
    }
  }
}

export function append(el, children) {
  for (const child of children.flat(Infinity)) {
    if (child == null || child === false || child === true) {
      continue;
    }
    el.append(child instanceof Node ? child : String(child));
  }
  return el;
}

export function icon(name, size = 18, className) {
  const id = name.startsWith("fa-") ? name : "md-" + name;
  const svg = document.createElementNS(SVG_NS, "svg");
  svg.setAttribute("class", className ? "ic " + className : "ic");
  svg.setAttribute("aria-hidden", "true");
  svg.style.width = size + "px";
  svg.style.height = size + "px";
  const use = document.createElementNS(SVG_NS, "use");
  use.setAttribute("href", `${SPRITE}#${id}`);
  svg.append(use);
  return svg;
}

export function osIconName(os) {
  if (!os) return "dns-outlined";
  const lower = String(os).toLowerCase();
  const has = (...words) => words.some((w) => lower.includes(w));
  if (has("windows", "mingw", "cygwin", "msys")) return "fa-windows";
  if (has("mac", "darwin")) return "fa-apple";
  if (has("ubuntu")) return "fa-ubuntu";
  if (has("debian")) return "fa-debian";
  if (has("fedora")) return "fa-fedora";
  if (has("arch")) return "fa-linux";
  if (has("centos")) return "fa-centos";
  if (has("red hat")) return "fa-redhat";
  if (has("freebsd")) return "fa-freebsd";
  if (has("alpine")) return "fa-mountain-sun";
  if (has("android")) return "fa-android";
  if (has("linux")) return "fa-linux";
  return "dns-outlined";
}

export function uuid() {
  if (crypto.randomUUID) {
    return crypto.randomUUID();
  }
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const hex = [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function toDate(value) {
  if (value == null || value === "") return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

const two = (n) => String(n).padStart(2, "0");

export const fmt = {
  day(value) {
    const d = toDate(value);
    return d ? `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())}` : "";
  },

  minute(value) {
    const d = toDate(value);
    return d ? `${fmt.day(d)} ${two(d.getHours())}:${two(d.getMinutes())}` : "";
  },

  second(value) {
    const d = toDate(value);
    return d ? `${fmt.minute(d)}:${two(d.getSeconds())}` : "";
  },

  duration(ms) {
    const total = Math.max(0, Math.floor(ms / 1000));
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor(total / 60) % 60;
    const seconds = total % 60;
    if (hours > 0) return `${hours}:${two(minutes)}:${two(seconds)} h`;
    if (minutes > 0) return `${minutes}:${two(seconds)} min`;
    return `${seconds} s`;
  },

  bytes(n) {
    if (n < 1024) return `${n} B`;
    if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
    return `${(n / (1024 * 1024)).toFixed(1)} MB`;
  },

  relative(value) {
    const d = toDate(value);
    if (!d) return "";
    const seconds = Math.floor((Date.now() - d.getTime()) / 1000);
    if (seconds < 60) return "just now";
    if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
    if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
    return `${Math.floor(seconds / 86400)}d ago`;
  },
};

export const isTouch = matchMedia("(hover: none) and (pointer: coarse)").matches;
