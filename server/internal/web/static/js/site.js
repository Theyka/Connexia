// Derives the AES-256 sync key from the account password (PBKDF2-HMAC-SHA256,
// salt "connexia-sync-v1:<userId>") and caches the raw key bytes in this tab's
// session so the dashboard can decrypt your snapshot without asking again.
// Returns a Promise so callers can navigate only once the key is stored.
function storeSyncKey(password, userId) {
  if (!userId || !window.crypto || !crypto.subtle) return Promise.resolve();
  var enc = new TextEncoder();
  return crypto.subtle.importKey("raw", enc.encode(password), "PBKDF2", false, ["deriveBits"])
    .then(function (base) {
      return crypto.subtle.deriveBits(
        { name: "PBKDF2", salt: enc.encode("connexia-sync-v1:" + userId), iterations: 100000, hash: "SHA-256" },
        base, 256);
    })
    .then(function (bits) {
      var b = new Uint8Array(bits), bin = "";
      for (var i = 0; i < b.length; i++) bin += String.fromCharCode(b[i]);
      sessionStorage.setItem("cnx_sync_key", btoa(bin));
    })
    .catch(function () {});
}

(function () {
  "use strict";

  var nav = document.getElementById("nav");
  function onScroll() {
    if (!nav) return;
    if (window.scrollY > 8) nav.classList.add("scrolled");
    else nav.classList.remove("scrolled");
  }
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // Mobile menu: the marketing header uses .open on #mobilenav.
  var btn = document.getElementById("menubtn");
  var mobile = document.getElementById("mobilenav");
  if (btn && mobile) {
    var setOpen = function (open) {
      mobile.classList.toggle("open", open);
      btn.setAttribute("aria-expanded", open ? "true" : "false");
      btn.setAttribute("aria-label", open ? "Close menu" : "Open menu");
    };
    btn.addEventListener("click", function () {
      setOpen(!mobile.classList.contains("open"));
    });
    mobile.addEventListener("click", function (e) {
      if (e.target.closest("a")) setOpen(false);
    });
    window.addEventListener("resize", function () {
      if (window.innerWidth > 880) setOpen(false);
    });
  }

  var year = document.getElementById("year");
  if (year) year.textContent = String(new Date().getFullYear());

  var hasToken = !!sessionStorage.getItem("token");
  document.querySelectorAll(".auth-out").forEach(function (el) { el.style.display = hasToken ? "none" : ""; });
  document.querySelectorAll(".auth-in").forEach(function (el) { el.style.display = hasToken ? "" : "none"; });

  var showcase = document.querySelector(".showcase");
  if (showcase) {
    var tabs = showcase.querySelectorAll(".showcase-tabs button");
    tabs.forEach(function (tab) {
      tab.addEventListener("click", function () {
        tabs.forEach(function (t) { t.classList.remove("on"); });
        tab.classList.add("on");
        showcase.querySelectorAll(".showcase-panel").forEach(function (p) {
          p.classList.toggle("on", p.id === tab.dataset.panel);
        });
      });
    });
  }

  // ---------- Live server stats ----------
  var statsEls = {
    users: document.getElementById("s-users"),
    verified: document.getElementById("s-verified"),
    snapshots: document.getElementById("s-snapshots"),
    bytes: document.getElementById("s-bytes"),
    uptime: document.getElementById("s-uptime")
  };
  function fmtBytes(n) {
    n = Number(n) || 0;
    return n >= 1073741824 ? (n / 1073741824).toFixed(1) + " GB"
      : n >= 1048576 ? (n / 1048576).toFixed(1) + " MB"
      : n >= 1024 ? (n / 1024).toFixed(1) + " KB"
      : n + " B";
  }
  // The server renders raw byte counts; format them before the first fetch.
  if (statsEls.bytes && /^\d+$/.test(statsEls.bytes.textContent.trim())) {
    statsEls.bytes.textContent = fmtBytes(statsEls.bytes.textContent.trim());
  }
  function loadStats() {
    fetch("/api/public/stats", { headers: { Accept: "application/json" } })
      .then(function (r) { return r.ok ? r.json() : Promise.reject(); })
      .then(function (s) {
        if (statsEls.users && s.users != null) statsEls.users.textContent = s.users;
        if (statsEls.verified && s.verified != null) statsEls.verified.textContent = s.verified;
        if (statsEls.snapshots && s.snapshots != null) statsEls.snapshots.textContent = s.snapshots;
        if (statsEls.bytes && s.blobBytes != null) statsEls.bytes.textContent = fmtBytes(s.blobBytes);
        if (statsEls.uptime && s.uptime) statsEls.uptime.textContent = s.uptime;
      })
      .catch(function () {});
  }
  if (statsEls.users) { loadStats(); setInterval(loadStats, 30000); }

  // ---------- Latest release version ----------
  var GITHUB_REPO = "https://api.github.com/repos/Theyka/Connexia/releases/latest";
  var verEls = document.querySelectorAll("[data-version]");
  if (verEls.length) {
    fetch(GITHUB_REPO, { headers: { Accept: "application/json" } })
      .then(function (r) { return r.ok ? r.json() : Promise.reject(); })
      .then(function (rel) {
        verEls.forEach(function (el) {
          // tag_name is "v0.2.9"; the templates already print the leading "v".
          el.textContent = (rel.tag_name || el.textContent).replace(/^v/, "");
          if (el.dataset.version === "link") el.href = rel.html_url || el.href;
        });
      })
      .catch(function () {});
  }

  // ---------- Download for the visitor's platform ----------
  function detectOS() {
    var ua = navigator.userAgent || "";
    var platform = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "";
    if (/android/i.test(ua)) return "android";
    if (/iphone|ipad|ipod/i.test(ua)) return "ios";
    // iPadOS reports itself as a Mac; touch support gives it away.
    if (/mac/i.test(platform) || /mac os x/i.test(ua)) return navigator.maxTouchPoints > 1 ? "ios" : "macos";
    if (/win/i.test(platform) || /windows/i.test(ua)) return "windows";
    if (/linux|x11/i.test(platform) || /linux/i.test(ua)) return "linux";
    return "";
  }
  var OS_NAMES = { windows: "Windows", macos: "macOS", linux: "Linux", android: "Android", ios: "iOS" };
  var os = detectOS();
  var osCard = os && document.querySelector('.lp-dl-card[data-os="' + os + '"]');
  if (osCard) {
    osCard.classList.add("is-you");
    var direct = osCard.querySelector("a.btn[href]");
    var primary = document.getElementById("lp-dl-primary");
    var label = primary && primary.querySelector("[data-os-label]");
    if (primary && label && direct) {
      label.textContent = "Download for " + OS_NAMES[os];
      primary.href = direct.href;
    }
  }

  // ---------- Copy buttons on docs code blocks ----------
  document.querySelectorAll(".lp-pre").forEach(function (block) {
    var pre = block.querySelector("pre");
    if (!pre || !navigator.clipboard) return;
    var copy = document.createElement("button");
    copy.type = "button";
    copy.className = "lp-copy";
    copy.innerHTML = '<svg class="ico"><use href="/assets/img/icons.svg#i-copy"/></svg><span>Copy</span>';
    copy.addEventListener("click", function () {
      navigator.clipboard.writeText(pre.innerText.trim()).then(function () {
        copy.classList.add("done");
        copy.querySelector("span").textContent = "Copied";
        setTimeout(function () {
          copy.classList.remove("done");
          copy.querySelector("span").textContent = "Copy";
        }, 1600);
      });
    });
    block.appendChild(copy);
  });

  // ---------- Docs: highlight the section being read ----------
  var docLinks = document.querySelectorAll(".lp-docs-nav a[href^='#']");
  if (docLinks.length && "IntersectionObserver" in window) {
    var byId = {};
    docLinks.forEach(function (a) { byId[a.getAttribute("href").slice(1)] = a; });
    var visible = {};
    var spy = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) { visible[en.target.id] = en.isIntersecting; });
      var current = null;
      document.querySelectorAll(".lp-prose h2[id], .lp-prose h3[id]").forEach(function (h) {
        if (h.getBoundingClientRect().top < window.innerHeight * 0.35) current = h.id;
      });
      if (!current) return;
      docLinks.forEach(function (a) { a.classList.remove("on"); });
      if (byId[current]) byId[current].classList.add("on");
    }, { rootMargin: "0px 0px -60% 0px" });
    Object.keys(byId).forEach(function (id) {
      var el = document.getElementById(id);
      if (el) spy.observe(el);
    });
  }

  // ---------- Reveal sections as they scroll into view ----------
  var reveals = document.querySelectorAll(".lp-reveal");
  if (reveals.length) {
    if (!("IntersectionObserver" in window)) {
      reveals.forEach(function (el) { el.classList.add("in"); });
    } else {
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (en) {
          if (en.isIntersecting) {
            en.target.classList.add("in");
            io.unobserve(en.target);
          }
        });
      }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
      reveals.forEach(function (el) { io.observe(el); });
    }
  }

  var authForm = document.getElementById("auth-form");
  var msg = document.getElementById("auth-msg");
  function showMsg(m, kind) {
    msg.className = "auth-msg " + (kind || "err");
    msg.innerHTML = m;
  }
  window.showAuthMsg = showMsg;
})();
