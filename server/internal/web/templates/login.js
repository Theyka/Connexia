(function () {
  var showMsg = window.showAuthMsg;
  var form = document.getElementById("login-form");
  var totpBox = document.getElementById("totp");
  var totpInput = document.getElementById("totp-code");
  var totpBtn = document.getElementById("totp-btn");
  var challenge = null;
  var password = null;

  if (sessionStorage.getItem("token")) { location.replace("/dashboard"); return; }


  document.getElementById("forgot").addEventListener("click", function (e) {
    e.preventDefault();
    showMsg("Password reset isn't supported by the sync server yet. If you lost your password, contact your server administrator.", "err");
  });

  form.addEventListener("submit", async function (e) {
    e.preventDefault();
    password = document.getElementById("password").value;
    var email = document.getElementById("email").value.trim();
    showMsg("Signing in…", "ok");
    var r = await fetch("/api/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: email, password: password })
    });
    var j = await r.json().catch(function () { return {}; });
    if (!r.ok) {
      showMsg(j.error === "emailNotVerified"
        ? "Your email isn't verified yet. Check your inbox for the 6-digit code and verify it from the app, then sign in again."
        : (j.error || "Invalid email or password."), "err");
      return;
    }
    if (j.needsTotp) {
      challenge = j.challengeToken;
      form.style.display = "none";
      totpBox.style.display = "block";
      totpInput.focus();
      showMsg("Enter your two-factor code.", "ok");
      return;
    }
    sessionStorage.setItem("token", j.token);
    storeSyncKey(password, j.userId).then(function () { location.href = "/dashboard"; });
  });

  function verifyTotp() {
    var code = totpInput.value.trim();
    if (!code) { showMsg("Enter your 6-digit code.", "err"); return; }
    showMsg("Verifying…", "ok");
    fetch("/api/login/2fa", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ challengeToken: challenge, code: code })
    }).then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
      .then(function (res) {
        if (!res.ok) { showMsg(res.j.error || "Invalid code.", "err"); return; }
        sessionStorage.setItem("token", res.j.token);
        storeSyncKey(password, res.j.userId).then(function () { location.href = "/dashboard"; });
      });
  }
  totpBtn.addEventListener("click", verifyTotp);
  totpInput.addEventListener("keydown", function (e) { if (e.key === "Enter") verifyTotp(); });
})();
