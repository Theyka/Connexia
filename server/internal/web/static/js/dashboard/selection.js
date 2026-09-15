import { h, icon, isTouch } from "./dom.js";
import { button } from "./ui.js";

export function createSelectionBar(host) {
  let bar = null;
  return {
    show({ count, actions, onClose }) {
      const next = h(
        "div",
        { class: "selection-bar" },
        h("span", { class: "selection-count", text: `${count} selected` }),
        actions.map((action) =>
          button({
            variant: "text",
            icon: action.icon,
            iconSize: 15,
            label: action.label,
            danger: action.danger,
            disabled: !action.onClick,
            onClick: action.onClick,
          }),
        ),
        h("button", { type: "button", class: "selection-close", "aria-label": "Clear selection", onClick: onClose }, icon("close", 16)),
      );
      if (bar) bar.replaceWith(next);
      else host.append(next);
      bar = next;
    },

    hide() {
      bar?.remove();
      bar = null;
    },
  };
}

const EDGE = 48;
const MAX_SPEED = 14;

export function enableBandSelection(scroller, { layer, getSelected, onChange, onEmptyClick }) {
  if (isTouch) return;

  let start = null;
  let point = null;
  let startScroll = 0;
  let moved = false;
  let scrolled = false;
  let additive = false;
  let band = null;
  let speed = 0;
  let frame = 0;

  scroller.addEventListener("pointerdown", (event) => {
    if (event.button !== 0 || event.target.closest("[data-key], button, input, textarea, a, .no-band")) {
      return;
    }
    start = { x: event.clientX, y: event.clientY };
    point = start;
    startScroll = scroller.scrollTop;
    moved = false;
    scrolled = false;
    additive = event.ctrlKey || event.metaKey;
    scroller.setPointerCapture(event.pointerId);
    event.preventDefault();
  });

  scroller.addEventListener("pointermove", (event) => {
    if (!start) return;
    point = { x: event.clientX, y: event.clientY };
    if (!moved && Math.hypot(point.x - start.x, point.y - start.y) <= 4) return;
    moved = true;
    updateSpeed();
    apply();
  });

  const finish = () => {
    if (!start) return;
    cancelAnimationFrame(frame);
    frame = 0;
    speed = 0;
    band?.remove();
    band = null;
    if (!moved) onEmptyClick?.();
    start = null;
  };
  scroller.addEventListener("pointerup", finish);
  scroller.addEventListener("pointercancel", finish);

  function updateSpeed() {
    const rect = scroller.getBoundingClientRect();
    if (point.y < rect.top + EDGE) speed = -((rect.top + EDGE - point.y) / EDGE) * MAX_SPEED;
    else if (point.y > rect.bottom - EDGE) speed = ((point.y - (rect.bottom - EDGE)) / EDGE) * MAX_SPEED;
    else speed = 0;
    if (speed !== 0 && !frame) frame = requestAnimationFrame(tick);
  }

  function tick() {
    frame = 0;
    if (!start || speed === 0) return;
    const before = scroller.scrollTop;
    scroller.scrollTop += speed;
    if (scroller.scrollTop !== before) apply();
    frame = requestAnimationFrame(tick);
  }

  function apply() {
    const shift = scroller.scrollTop - startScroll;
    if (shift !== 0) scrolled = true;
    const x1 = Math.min(start.x, point.x);
    const x2 = Math.max(start.x, point.x);
    const y1 = Math.min(start.y - shift, point.y);
    const y2 = Math.max(start.y - shift, point.y);

    const bounds = layer.getBoundingClientRect();
    if (!band) {
      band = h("div", { class: "band" });
      layer.append(band);
    }
    const top = Math.max(y1, bounds.top);
    const bottom = Math.min(y2, bounds.bottom);
    band.style.left = x1 - bounds.left + "px";
    band.style.width = x2 - x1 + "px";
    band.style.top = top - bounds.top + "px";
    band.style.height = Math.max(0, bottom - top) + "px";

    const hits = new Set();
    for (const card of scroller.querySelectorAll("[data-key]")) {
      const r = card.getBoundingClientRect();
      if (r.right >= x1 && r.left <= x2 && r.bottom >= y1 && r.top <= y2) {
        hits.add(card.dataset.key);
      }
    }
    onChange(additive || scrolled ? new Set([...getSelected(), ...hits]) : hits);
  }
}
