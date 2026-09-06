(function () {
  var showMsg = window.showAuthMsg;
  var form = document.getElementById("register-form");
  var verifyBox = document.getElementById("verify");
  var verifyBtn = document.getElementById("verify-btn");
  var codeInput = document.getElementById("code");
  var pendingEmail = null;
  var pendingPassword = null;

  if (sessionStorage.getItem("token")) { location.replace("/dashboard"); return; }


  function finish() {
    showMsg("Signed in — setting up your dashboard…", "ok");
    fetch("/api/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: pendingEmail, password: pendingPassword })
    })
      .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }).catch(function () { return { ok: r.ok, j: {} }; }); })
      .then(function (res) {
        if (res.ok && res.j.token) {
          sessionStorage.setItem("token", res.j.token);
          storeSyncKey(pendingPassword, res.j.userId).then(function () { location.href = "/dashboard"; });
        } else {
          location.href = "/login";
        }
      })
      .catch(function () { location.href = "/login"; });
  }

  form.addEventListener("submit", async function (e) {
    e.preventDefault();
    var email = document.getElementById("email").value.trim();
    var p1 = document.getElementById("password").value;
    var p2 = document.getElementById("password2").value;
    if (!email) { showMsg("Enter your email.", "err"); return; }
    if (p1.length < 8) { showMsg("Password must be at least 8 characters.", "err"); return; }
    if (p1 !== p2) { showMsg("Passwords do not match.", "err"); return; }
    showMsg("Creating account…", "ok");
    pendingEmail = email;
    pendingPassword = p1;
    var r = await fetch("/api/register", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: email, password: p1 })
    });
    var j = await r.json().catch(function () { return {}; });
    if (!r.ok) { showMsg(j.error || "Registration failed.", "err"); return; }
    if (j.emailVerified) {
      finish();
      return;
    }
    document.getElementById("vemail").textContent = email;
    form.style.display = "none";
    verifyBox.style.display = "block";
    codeInput.focus();
    showMsg("Check your inbox (or the server log) for the verification code.", "ok");
  });

  function verify() {
    var code = codeInput.value.trim();
    if (!code) { showMsg("Enter the 6-digit code.", "err"); return; }
    showMsg("Verifying…", "ok");
    fetch("/api/verify-email", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: pendingEmail, code: code })
    }).then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
      .then(function (res) {
        if (!res.ok) { showMsg(res.j.error || "Invalid or expired code.", "err"); return; }
        verifyBox.style.display = "none";
        finish();
      });
  }
  verifyBtn.addEventListener("click", verify);
  codeInput.addEventListener("keydown", function (e) { if (e.key === "Enter") verify(); });
})();
