import { h, icon, isTouch } from "../dom.js";
import { cardGrid, textField } from "../ui.js";

export function searchBox(placeholder, onInput) {
  return textField({ hint: placeholder, prefixIcon: "search", clearable: true, className: "tf-search", onInput });
}

export function gap(size) {
  return h("div", { class: "sp-" + size });
}

export function tile(iconName, color) {
  const style = color ? { background: `color-mix(in srgb, ${color} 14%, transparent)`, color } : null;
  return h("div", { class: "card-tile", style }, icon(iconName, 15));
}

export function colorFromInt(value) {
  if (value == null) return null;
  return "#" + (Number(value) & 0xffffff).toString(16).padStart(6, "0");
}

export function card({ key, selected, thickBorder, className, tile: tileNode, title, titleClass, extras, sub, action, actionOnTouch, tooltip, onClick, onDoubleClick, onMenu }) {
  if (action && actionOnTouch && isTouch) {
    action.classList.add("is-always");
  }
  const el = h(
    "div",
    {
      class: ["card", selected && "is-selected", thickBorder && "has-thick-border", className],
      dataset: { key },
      "data-tip": tooltip,
      "data-tip-wait": tooltip ? "700" : null,
    },
    tileNode,
    h(
      "div",
      { class: "card-text" },
      h("div", { class: "card-title-row" }, h("span", { class: ["card-title", titleClass], text: title }), extras),
      typeof sub === "string" ? h("span", { class: "card-sub", text: sub }) : sub,
    ),
    h("div", { class: "card-trail" }, action),
  );
  if (onClick) el.addEventListener("click", onClick);
  if (onDoubleClick) el.addEventListener("dblclick", onDoubleClick);
  if (onMenu) {
    el.addEventListener("contextmenu", (event) => {
      event.preventDefault();
      onMenu(event.clientX, event.clientY);
    });
  }
  return el;
}

export function grid(cards, { rowHeight, padding } = {}) {
  const inner = cardGrid({ rowHeight });
  inner.append(...cards);
  return h("div", { class: ["grid-pad", padding && "is-" + padding] }, inner);
}

export function replaceKeepingScroll(scroller, nodes) {
  const top = scroller.scrollTop;
  scroller.replaceChildren(...nodes);
  scroller.scrollTop = top;
}

export function markSelected(root, isSelected) {
  for (const card of root.querySelectorAll("[data-key]")) {
    card.classList.toggle("is-selected", isSelected(card.dataset.key));
  }
}

export function modKey(event) {
  return event.ctrlKey || event.metaKey;
}

export function trackHover(scroller) {
  const hover = { key: null };
  scroller.addEventListener("pointerover", (event) => {
    hover.key = event.target.closest("[data-key]")?.dataset.key ?? null;
  });
  scroller.addEventListener("pointerleave", () => {
    hover.key = null;
  });
  return hover;
}

export function sectionCard(iconName, title, children) {
  return h(
    "div",
    { class: "section-card" },
    h("div", { class: "section-card-head" }, icon(iconName, 15), h("span", { class: "section-card-title", text: title })),
    h("div", { class: "section-card-body" }, children),
  );
}
