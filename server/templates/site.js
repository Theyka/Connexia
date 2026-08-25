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

  var btn = document.getElementById("menubtn");
  var links = document.getElementById("navlinks");
  if (btn && links) {
    btn.addEventListener("click", function () {
      var open = links.classList.toggle("open");
      btn.setAttribute("aria-expanded", open ? "true" : "false");
    });
    links.addEventListener("click", function (e) {
      if (e.target.tagName === "A") {
        links.classList.remove("open");
        btn.setAttribute("aria-expanded", "false");
      }
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

  var statsEls = {
    users: document.getElementById("s-users"),
    verified: document.getElementById("s-verified"),
    snapshots: document.getElementById("s-snapshots"),
    bytes: document.getElementById("s-bytes"),
    uptime: document.getElementById("s-uptime")
  };
  function fmtBytes(n) {
    n = Number(n) || 0;
    return n >= 1048576 ? (n / 1048576).toFixed(1) + " MB"
      : n >= 1024 ? (n / 1024).toFixed(1) + " KB"
      : n + " B";
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

  var GITHUB_REPO = "https://api.github.com/repos/Theyka/Connexia/releases/latest";
  var verEls = document.querySelectorAll("[data-version]");
  if (verEls.length) {
    fetch(GITHUB_REPO, { headers: { Accept: "application/json" } })
      .then(function (r) { return r.ok ? r.json() : Promise.reject(); })
      .then(function (rel) {
        verEls.forEach(function (el) {
          el.textContent = rel.tag_name || el.textContent;
          if (el.dataset.version === "link") el.href = rel.html_url || el.href;
        });
      })
      .catch(function () {});
  }

  var authForm = document.getElementById("auth-form");
  var msg = document.getElementById("auth-msg");
  function showMsg(m, kind) {
    msg.className = "auth-msg " + (kind || "err");
    msg.innerHTML = m;
  }
  window.showAuthMsg = showMsg;
})();
