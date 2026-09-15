let terminalLoading = null;
let sshLoading = null;

function loadScript(src) {
  return new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = src;
    script.onload = resolve;
    script.onerror = () => reject(new Error(`Could not load ${src}`));
    document.head.append(script);
  });
}

function loadStyle(href) {
  return new Promise((resolve, reject) => {
    const link = document.createElement("link");
    link.rel = "stylesheet";
    link.href = href;
    link.onload = resolve;
    link.onerror = () => reject(new Error(`Could not load ${href}`));
    document.head.append(link);
  });
}

export function loadTerminal() {
  terminalLoading ??= Promise.all([
    loadStyle("/assets/vendor/xterm/xterm.css"),
    loadScript("/assets/vendor/xterm/xterm.js").then(() => loadScript("/assets/vendor/xterm/addon-fit.js")),
    document.fonts.load('14px "JetBrains Mono"'),
  ]).then(() => ({ Terminal: window.Terminal, FitAddon: window.FitAddon.FitAddon }));
  return terminalLoading;
}

export function loadSSH() {
  sshLoading ??= (async () => {
    await loadScript("/assets/wasm/wasm_exec.js");
    const go = new window.Go();
    const ready = new Promise((resolve) => {
      window.connexiaSSHReady = resolve;
    });
    const { instance } = await WebAssembly.instantiateStreaming(fetch("/assets/wasm/ssh.wasm"), go.importObject);
    go.run(instance);
    await ready;
    return window.connexiaSSH;
  })().catch((err) => {
    sshLoading = null;
    throw err;
  });
  return sshLoading;
}
