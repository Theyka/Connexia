import { h, icon } from "./dom.js";

const escapeHandlers = [];

export function onEscape(handler) {
  escapeHandlers.push(handler);
  return () => {
    const index = escapeHandlers.lastIndexOf(handler);
    if (index >= 0) escapeHandlers.splice(index, 1);
  };
}

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && escapeHandlers.length > 0 && !event.target.closest?.(".xterm")) {
    event.preventDefault();
    escapeHandlers[escapeHandlers.length - 1]();
  }
});

export function button({ variant = "filled", icon: iconName, iconSize = 16, label, onClick, danger, disabled, tooltip, size, block, className }) {
  return h(
    "button",
    {
      type: "button",
      class: ["btn", "btn-" + variant, danger && "is-danger", size && "btn-" + size, block && "btn-block", className],
      disabled,
      "data-tip": tooltip,
      onClick,
    },
    iconName && icon(iconName, iconSize),
    label != null && h("span", { class: "btn-label", text: label }),
  );
}

export function iconButton({ icon: iconName, size = 20, tooltip, onClick, disabled, className }) {
  return h(
    "button",
    { type: "button", class: ["icon-btn", className], disabled, "data-tip": tooltip, "aria-label": tooltip, onClick },
    icon(iconName, size),
  );
}

export function cardAction({ icon: iconName, size = 13.5, tooltip, onClick }) {
  const stop = (event) => event.stopPropagation();
  return h(
    "button",
    {
      type: "button",
      class: "card-action",
      "data-tip": tooltip,
      "aria-label": tooltip,
      onPointerdown: (event) => {
        if (event.button !== 0) return;
        stop(event);
        event.preventDefault();
        onClick(event);
      },
      onClick: (event) => {
        stop(event);
        if (event.detail === 0) onClick(event);
      },
      onDblclick: stop,
      onContextmenu: stop,
    },
    icon(iconName, size),
  );
}

let tooltipEl = null;
let tooltipTimer = 0;
let tooltipTarget = null;

function hideTooltip() {
  clearTimeout(tooltipTimer);
  tooltipTarget = null;
  tooltipEl?.classList.remove("is-visible");
}

function showTooltip(target) {
  const text = target.dataset.tip;
  if (!target.isConnected || !text) return;
  const below = Number(target.dataset.tipBelow);
  if (below && innerWidth >= below) return;
  tooltipEl.textContent = text;
  tooltipEl.classList.add("is-visible");
  const anchor = target.getBoundingClientRect();
  const box = tooltipEl.getBoundingClientRect();
  const centerY = anchor.top + anchor.height / 2;
  let top = centerY + 24;
  if (top + box.height > innerHeight - 8) top = centerY - 24 - box.height;
  const left = Math.min(Math.max(8, anchor.left + anchor.width / 2 - box.width / 2), innerWidth - box.width - 8);
  tooltipEl.style.left = left + "px";
  tooltipEl.style.top = top + "px";
}

export function installTooltips() {
  tooltipEl = h("div", { class: "tooltip", role: "tooltip" });
  document.body.append(tooltipEl);
  document.addEventListener("pointerover", (event) => {
    const target = event.target.closest?.("[data-tip]");
    if (target === tooltipTarget) return;
    hideTooltip();
    if (!target || event.pointerType === "touch") return;
    tooltipTarget = target;
    tooltipTimer = setTimeout(() => showTooltip(target), Number(target.dataset.tipWait) || 400);
  });
  document.addEventListener("pointerdown", hideTooltip, true);
  document.addEventListener("scroll", hideTooltip, true);
}

let snackbarEl = null;
let snackbarTimer = 0;

export function snackbar(message, duration = 4000) {
  if (!snackbarEl) {
    snackbarEl = h("div", { class: "snackbar", role: "status" });
    document.body.append(snackbarEl);
  }
  snackbarEl.textContent = message;
  snackbarEl.classList.remove("is-visible");
  void snackbarEl.offsetWidth;
  snackbarEl.classList.add("is-visible");
  clearTimeout(snackbarTimer);
  snackbarTimer = setTimeout(() => snackbarEl.classList.remove("is-visible"), duration);
}

export function openDialog({ title, content, actions = [], className, width }) {
  return new Promise((resolve) => {
    let closed = false;
    const barrier = h("div", { class: "dialog-barrier" });
    const close = (value) => {
      if (closed) return;
      closed = true;
      removeEscape();
      barrier.classList.add("is-closing");
      setTimeout(() => barrier.remove(), 120);
      resolve(value);
    };
    const removeEscape = onEscape(() => close(undefined));

    const actionNodes = actions.map((action) => {
      if (action instanceof Node) return action;
      const node = button({
        variant: action.variant || "text",
        label: action.label,
        icon: action.icon,
        danger: action.danger,
        disabled: action.disabled,
        className: action.className,
        onClick: () => (action.onClick ? action.onClick(close) : close(action.value)),
      });
      action.ref?.(node);
      return node;
    });

    const dialog = h(
      "div",
      { class: ["dialog", className], role: "dialog", "aria-modal": "true", style: { width } },
      title != null && h("div", { class: "dialog-title" }, title),
      content != null && h("div", { class: "dialog-content" }, typeof content === "function" ? content(close) : content),
      actionNodes.length > 0 && h("div", { class: "dialog-actions" }, actionNodes),
    );
    barrier.addEventListener("pointerdown", (event) => {
      if (event.target === barrier) close(undefined);
    });
    barrier.append(dialog);
    document.body.append(barrier);

    const autofocus = dialog.querySelector("[autofocus]");
    if (autofocus) autofocus.focus();
    else actionNodes[actionNodes.length - 1]?.focus?.();
  });
}

export async function confirmDialog({ title, message, confirmLabel = "Delete", danger = true, cancelVariant = "text" }) {
  const result = await openDialog({
    title,
    content: message,
    actions: [
      { label: "Cancel", variant: cancelVariant, value: false },
      { label: confirmLabel, variant: "filled", danger, value: true },
    ],
  });
  return result === true;
}

let closeOpenMenu = null;

export function showMenu({ x, y, anchor, items, onClose, className }) {
  closeOpenMenu?.();
  const layer = h("div", { class: "menu-layer" });
  const menu = h("div", { class: ["menu", className], role: "menu" });

  const close = () => {
    if (!layer.isConnected) return;
    layer.remove();
    removeEscape();
    window.removeEventListener("resize", close);
    closeOpenMenu = null;
    onClose?.();
  };
  const removeEscape = onEscape(close);
  closeOpenMenu = close;

  for (const item of items) {
    if (!item) continue;
    if (item === "divider") {
      menu.append(h("div", { class: "menu-divider" }));
      continue;
    }
    menu.append(
      h(
        "button",
        {
          type: "button",
          class: ["menu-item", item.danger && "is-danger", item.className],
          role: "menuitem",
          onClick: () => {
            close();
            item.onSelect?.();
          },
        },
        item.render ? item.render() : [item.icon && icon(item.icon, item.iconSize ?? 16, "menu-icon"), h("span", { class: "menu-label", text: item.label })],
      ),
    );
  }

  layer.addEventListener("pointerdown", (event) => {
    if (!menu.contains(event.target)) close();
  });
  layer.addEventListener("contextmenu", (event) => {
    if (!menu.contains(event.target)) {
      event.preventDefault();
      close();
    }
  });
  window.addEventListener("resize", close);
  layer.append(menu);
  document.body.append(layer);

  const box = menu.getBoundingClientRect();
  let left = x;
  let top = y - 16;
  if (anchor) {
    const rect = anchor.getBoundingClientRect();
    left = rect.left;
    top = rect.top;
  }
  left = Math.max(8, Math.min(left, innerWidth - box.width - 8));
  top = Math.max(8, Math.min(top, innerHeight - box.height - 8));
  menu.style.left = left + "px";
  menu.style.top = top + "px";
  return close;
}

let fieldCounter = 0;

export function textField({
  label, hint, value = "", type = "text", multiline = false, rows = 4, mono = false, helper,
  prefixIcon, reveal, clearable, maxLength, inputMode, autofocus, className, onInput, onEnter,
}) {
  const id = "field-" + ++fieldCounter;
  const input = multiline
    ? h("textarea", { id, class: "tf-input", rows: 1, placeholder: hint || "", spellcheck: false })
    : h("input", {
        id,
        class: "tf-input",
        type: reveal ? "password" : type,
        placeholder: hint || "",
        autocomplete: reveal ? "new-password" : "off",
        spellcheck: false,
        maxLength,
        inputmode: inputMode,
      });
  input.value = value ?? "";
  if (autofocus) input.setAttribute("autofocus", "");

  const box = h("div", {
    class: ["tf", label && "has-label", multiline && "is-multiline", mono && "is-mono", prefixIcon && "has-prefix", className],
  });
  if (prefixIcon) box.append(h("span", { class: "tf-prefix" }, icon(prefixIcon, 18)));
  box.append(input);
  if (label) box.append(h("label", { class: "tf-label", htmlFor: id, text: label }));
  box.append(h("fieldset", { class: "tf-outline", "aria-hidden": "true" }, h("legend", {}, label ? h("span", { text: label }) : null)));

  if (reveal) {
    const noun = reveal === true ? "password" : reveal;
    const size = noun === "passphrase" ? 19 : 16;
    const toggle = iconButton({ icon: "visibility-outlined", size, tooltip: "Show " + noun, className: "tf-suffix" });
    toggle.addEventListener("click", () => {
      const hidden = input.type === "password";
      input.type = hidden ? "text" : "password";
      toggle.replaceChildren(icon(hidden ? "visibility-off-outlined" : "visibility-outlined", size));
      toggle.dataset.tip = (hidden ? "Hide " : "Show ") + noun;
    });
    box.classList.add("has-suffix");
    box.append(toggle);
  }

  let clearButton = null;
  if (clearable) {
    clearButton = iconButton({ icon: "clear", size: 18, className: "tf-suffix" });
    clearButton.addEventListener("click", () => {
      input.value = "";
      sync();
      onInput?.("");
      input.focus();
    });
    box.append(clearButton);
  }

  const helperEl = h("div", { class: "tf-helper", text: helper || "" });
  helperEl.hidden = !helper;
  const el = h("div", { class: "field" }, box, helperEl);

  const autosize = () => {
    if (!multiline || !input.isConnected) return;
    const style = getComputedStyle(input);
    const padding = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom);
    input.style.height = "auto";
    input.style.height = Math.min(input.scrollHeight, parseFloat(style.lineHeight) * rows + padding) + "px";
  };
  if (multiline) {
    new ResizeObserver(() => autosize()).observe(box);
  }

  const sync = () => {
    autosize();
    box.classList.toggle("is-filled", input.value !== "");
    if (clearButton) {
      clearButton.hidden = input.value === "";
      box.classList.toggle("has-suffix", input.value !== "");
    }
  };
  input.addEventListener("input", () => {
    sync();
    onInput?.(input.value);
  });
  input.addEventListener("focus", () => box.classList.add("is-focused"));
  input.addEventListener("blur", () => box.classList.remove("is-focused"));
  if (onEnter && !multiline) {
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter") onEnter(input.value);
    });
  }
  box.addEventListener("pointerdown", (event) => {
    if (event.target === box) {
      event.preventDefault();
      input.focus();
    }
  });
  sync();

  return {
    el,
    input,
    get value() {
      return input.value;
    },
    set value(next) {
      input.value = next ?? "";
      sync();
    },
    setError(message) {
      box.classList.toggle("is-error", Boolean(message));
      helperEl.classList.toggle("is-error", Boolean(message));
      helperEl.textContent = message || helper || "";
      helperEl.hidden = !(message || helper);
    },
    focus() {
      input.focus();
    },
  };
}

function fieldTrigger({ label, iconName }) {
  const valueEl = h("div", { class: "sf-value" });
  const chevron = h("span", { class: "sf-chevron" }, icon("keyboard-arrow-down", 18));
  const trigger = h(
    "button",
    { type: "button", class: "sf" },
    iconName && icon(iconName, 16, "sf-icon"),
    h("span", { class: "sf-text" }, h("span", { class: "sf-label", text: label.toUpperCase() }), valueEl),
    chevron,
  );
  const setOpen = (open) => {
    trigger.classList.toggle("is-open", open);
    chevron.replaceChildren(icon(open ? "keyboard-arrow-up" : "keyboard-arrow-down", 18));
  };
  return { trigger, valueEl, setOpen };
}

function fieldWrapper(trigger, helper) {
  const helperEl = h("div", { class: "tf-helper sf-helper", text: helper || "" });
  helperEl.hidden = !helper;
  const el = h("div", { class: "field" }, trigger, helperEl);
  const setError = (message) => {
    helperEl.classList.toggle("is-error", Boolean(message));
    helperEl.textContent = message || helper || "";
    helperEl.hidden = !(message || helper);
  };
  return { el, setError };
}

export function selectField({ label, icon: iconName, value, options, helper, searchable, onChange }) {
  let current = value;
  let items = options;
  const { trigger, valueEl, setOpen } = fieldTrigger({ label, iconName });
  const { el, setError } = fieldWrapper(trigger, helper);

  const render = () => {
    const selected = items.find((o) => o.value === current);
    valueEl.textContent = selected ? selected.label : "Select...";
    valueEl.classList.toggle("is-placeholder", !selected);
  };

  trigger.addEventListener("click", () => {
    setOpen(true);
    const layer = h("div", { class: "menu-layer" });
    const popup = h("div", { class: "sf-popup" });
    const list = h("div", { class: "sf-list" });
    let query = "";

    const finish = (option) => {
      layer.remove();
      removeEscape();
      setOpen(false);
      if (option) {
        current = option.value;
        render();
        onChange?.(option.value);
      }
    };
    const removeEscape = onEscape(() => finish(null));

    const renderList = () => {
      const q = query.toLowerCase();
      const matches = items.filter((o) => !q || o.label.toLowerCase().includes(q) || (o.subtitle || "").toLowerCase().includes(q));
      list.replaceChildren(
        ...(matches.length === 0
          ? [h("div", { class: "sf-empty", text: "No matches" })]
          : matches.map((option) => {
              const selected = option.value === current;
              return h(
                "button",
                { type: "button", class: ["sf-option", selected && "is-selected"], onClick: () => finish(option) },
                option.icon && icon(option.icon, 16, "sf-option-icon"),
                h(
                  "span",
                  { class: "sf-option-text" },
                  h("span", { class: "sf-option-label", text: option.label }),
                  option.subtitle && h("span", { class: "sf-option-sub", text: option.subtitle }),
                ),
                selected && icon("check", 16, "sf-check"),
              );
            })),
      );
    };

    if (searchable ?? items.length >= 8) {
      const search = h("input", { class: "sf-search-input", placeholder: "Search...", spellcheck: false });
      search.addEventListener("input", () => {
        query = search.value;
        renderList();
      });
      popup.append(h("div", { class: "sf-search" }, icon("search", 16), search));
      queueMicrotask(() => search.focus());
    }
    renderList();
    popup.append(list);
    layer.append(popup);
    layer.addEventListener("pointerdown", (event) => {
      if (!popup.contains(event.target)) finish(null);
    });
    document.body.append(layer);

    const anchor = trigger.getBoundingClientRect();
    popup.style.minWidth = Math.min(Math.max(anchor.width, 200), innerWidth - 16) + "px";
    popup.style.maxHeight = innerHeight - 16 + "px";
    const box = popup.getBoundingClientRect();
    let top = anchor.bottom + 6;
    if (top + box.height > innerHeight - 8) {
      const above = anchor.top - box.height - 6;
      top = above >= 8 ? above : Math.max(8, innerHeight - box.height - 8);
    }
    popup.style.top = top + "px";
    popup.style.left = Math.max(8, Math.min(anchor.left, innerWidth - box.width - 8)) + "px";
  });

  render();
  return {
    el,
    setError,
    get value() {
      return current;
    },
    set value(next) {
      current = next;
      render();
    },
  };
}

export function keySelectField({ value, identities, onChange, label = "Private key" }) {
  let current = value;
  const { trigger, valueEl, setOpen } = fieldTrigger({ label, iconName: "vpn-key-outlined" });
  const { el, setError } = fieldWrapper(trigger, null);

  const render = () => {
    const selected = identities.find((i) => i.id === current);
    valueEl.textContent = selected ? selected.name : identities.length ? "Select a key..." : "No keys imported yet";
    valueEl.classList.toggle("is-placeholder", !selected);
  };

  trigger.addEventListener("click", () => {
    if (identities.length === 0) return;
    setOpen(true);
    showMenu({
      anchor: trigger,
      className: "menu-keys",
      onClose: () => setOpen(false),
      items: identities.map((identity) => ({
        className: "menu-item-tall",
        render: () => {
          const selected = identity.id === current;
          return [
            icon("vpn-key-outlined", 16, selected ? "menu-icon is-accent" : "menu-icon is-muted"),
            h(
              "span",
              { class: "menu-rich" },
              h("span", { class: "menu-rich-title", text: identity.name }),
              identity.comment && h("span", { class: "menu-rich-sub", text: identity.comment }),
            ),
            selected && icon("check", 16, "menu-icon is-accent"),
          ];
        },
        onSelect: () => {
          if (identity.id === current) return;
          current = identity.id;
          setError(null);
          render();
          onChange?.(current);
        },
      })),
    });
  });

  render();
  return {
    el,
    setError,
    get value() {
      return current;
    },
  };
}

export function segmented({ options, value, onChange, small }) {
  let current = value;
  const el = h("div", { class: ["seg", small && "seg-small"], role: "radiogroup" });
  const render = () => {
    el.replaceChildren(
      ...options.map((option) =>
        h(
          "button",
          {
            type: "button",
            class: ["seg-option", option.value === current && "is-selected"],
            role: "radio",
            "aria-checked": String(option.value === current),
            onClick: () => {
              current = option.value;
              render();
              onChange?.(option.value);
            },
          },
          option.icon && icon(option.icon, 13),
          h("span", { text: option.label }),
        ),
      ),
    );
  };
  render();
  return {
    el,
    get value() {
      return current;
    },
  };
}

export function switchControl({ checked, onChange, label }) {
  const input = h("input", { type: "checkbox", class: "switch-input", role: "switch", checked, "aria-label": label });
  input.addEventListener("change", () => onChange?.(input.checked));
  const el = h("label", { class: "switch" }, input, h("span", { class: "switch-track" }, h("span", { class: "switch-thumb" })));
  return { el, input };
}

export function switchTile({ title, subtitle, checked, onChange, className }) {
  const control = switchControl({ checked, onChange, label: title });
  const el = h(
    "label",
    { class: ["switch-tile", className] },
    h("span", { class: "switch-tile-text" }, h("span", { class: "switch-tile-title", text: title }), subtitle && h("span", { class: "switch-tile-sub", text: subtitle })),
    control.el,
  );
  return { el, input: control.input };
}

export function checkbox({ checked, onChange, label }) {
  const input = h("input", { type: "checkbox", class: "checkbox-input", checked, "aria-label": label });
  input.addEventListener("change", () => onChange?.(input.checked));
  const el = h("span", { class: "checkbox" }, input, h("span", { class: "checkbox-box" }, icon("check", 14)));
  return { el, input };
}

export function checkboxTile({ label, checked, onChange, trailingIcon }) {
  const control = checkbox({ checked, onChange, label });
  const el = h(
    "label",
    { class: "checkbox-tile" },
    control.el,
    h("span", { class: "checkbox-tile-label", text: label }),
    trailingIcon && icon(trailingIcon, 18, "checkbox-tile-icon"),
  );
  return { el, input: control.input };
}

export function openPanel(host, { width = 320, build, onClose }) {
  const backdrop = h("div", { class: "panel-backdrop" });
  const el = h("aside", { class: "panel", style: { width: `min(${width}px, 100%)` } });
  const panel = {
    el,
    closed: false,
    close() {
      if (panel.closed) return;
      panel.closed = true;
      removeEscape();
      backdrop.remove();
      el.remove();
      onClose?.();
    },
  };
  const removeEscape = onEscape(() => panel.close());
  backdrop.addEventListener("pointerdown", () => panel.close());
  el.append(build(panel));
  host.append(backdrop, el);
  el.querySelector("[autofocus]")?.focus();
  return panel;
}

export function panelHeader({ title, subtitle, onClose, actions = [], status }) {
  return h(
    "div",
    { class: "panel-header" },
    h(
      "div",
      { class: "panel-header-row" },
      h("div", { class: "panel-title", text: title }),
      status,
      actions,
      iconButton({ icon: "close", size: 20, tooltip: "Close", onClick: onClose }),
    ),
    subtitle && h("div", { class: "panel-subtitle", text: subtitle }),
  );
}

export function panelLayout({ children, footer }) {
  return h("div", { class: "panel-layout" }, h("div", { class: "panel-scroll" }, children), footer && h("div", { class: "panel-footer" }, footer));
}

export function emptyState({ icon: iconName, title, message, action, roomy }) {
  return h(
    "div",
    { class: ["empty", roomy && "is-roomy"] },
    h("div", { class: "empty-icon" }, icon(iconName, 30)),
    h("div", { class: "empty-title", text: title }),
    message && h("div", { class: "empty-message", text: message }),
    action,
  );
}

export function noResults(text) {
  return h("div", { class: "no-results" }, icon("search-off", 40), h("div", { class: "no-results-text", text }));
}

export function sectionHeader(text) {
  return h("div", { class: "section-header", text: text.toUpperCase() });
}

export function cardGrid({ rowHeight, maxExtent = 300, gap = 10 }) {
  const grid = h("div", { class: "card-grid", style: { "--row-height": rowHeight + "px", "--gap": gap + "px" } });
  new ResizeObserver(([entry]) => {
    const width = entry.contentRect.width;
    const columns = Math.max(1, Math.ceil(width / (maxExtent + gap)));
    grid.style.gridTemplateColumns = `repeat(${columns}, minmax(0, 1fr))`;
  }).observe(grid);
  return grid;
}

export async function copyToClipboard(text, message) {
  try {
    await navigator.clipboard.writeText(text);
    if (message) snackbar(message, 2000);
  } catch {
    snackbar("Could not access the clipboard");
  }
}

export function connexiaMark(size = 40) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "1.655 1.655 20.69 20.69");
  svg.setAttribute("aria-hidden", "true");
  svg.innerHTML =
    '<path d="M6.6 7.9 10.2 12 6.6 14.8" stroke-width="1.9"/>' +
    '<path d="M12.1 16.1h5.4" stroke-width="1.7"/>';
  return h("span", { class: "mark", style: { "--size": size + "px" } }, svg);
}

export function needsApp(what) {
  snackbar(`${what} needs an SSH connection, which the web dashboard can't open yet. Use the Connexia app.`);
}
