const JOB_INDEX_KEY = "jobs:index";
const RUNNER_TOKEN_KEY = "runner:token";
// A KV value is capped at 25 MB and base64 inflates by a third, which a book
// package with chapter images passes easily. File bodies live in R2 instead,
// so these limits are about what a designer should reasonably upload, not
// about what the store can hold.
const MAX_FILE_BYTES = 25 * 1024 * 1024;
const MAX_TOTAL_UPLOAD_BYTES = 100 * 1024 * 1024;

// One place that decides where a file body lives, so uploads, downloads and
// artifacts cannot drift apart about it.
function fileObjectKey(jobId, kind, index) {
  return "job/" + jobId + "/" + kind + "/" + index;
}

async function putFileBody(env, key, contentBase64, contentType) {
  const bytes = base64ToBytes(contentBase64 || "");
  await env.BOOK_STUDIO_FILES.put(key, bytes, {
    httpMetadata: { contentType: contentType || "application/octet-stream" }
  });
  return bytes.length;
}

async function getFileBodyBase64(env, key) {
  const object = await env.BOOK_STUDIO_FILES.get(key);
  if (!object) return "";
  return bytesToBase64(new Uint8Array(await object.arrayBuffer()));
}

// The book is written on the designer's own PC, using the Codex they are
// already signed in to. Nothing here reaches into that machine: the agent
// dials out, so this page's job is to hand over a token and then show what
// the machine reports back about itself.
const CONNECT_HTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Connect your computer</title>
<style>
 :root { --ink:#0d3553; --line:#dbdbdb; --bg:#f9f9f9; --ok:#067647; --warn:#a15c00; --bad:#b42318; }
 @media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --ink:#eef4f8; --line:#2b3d4c; --bg:#0f1a22; } }
 :root[data-theme="dark"] { --ink:#eef4f8; --line:#2b3d4c; --bg:#0f1a22; }
 body { margin:0; background:var(--bg); color:var(--ink); font:16px/1.5 system-ui,Segoe UI,Arial,sans-serif; }
 main { max-width:760px; margin:0 auto; padding:32px 16px 64px; }
 h1 { font-size:26px; margin:0 0 4px; } p.sub { margin:0 0 28px; opacity:.75; }
 section { border:1px solid var(--line); border-radius:10px; padding:20px; margin-bottom:18px; background:color-mix(in srgb, var(--bg) 88%, white); }
 h2 { font-size:15px; text-transform:uppercase; letter-spacing:.06em; margin:0 0 12px; opacity:.7; }
 .row { display:flex; gap:10px; align-items:center; flex-wrap:wrap; }
 button { font:inherit; padding:9px 16px; border-radius:7px; border:1px solid var(--ink); background:var(--ink); color:var(--bg); cursor:pointer; }
 button.secondary { background:transparent; color:var(--ink); }
 code, pre { font-family:ui-monospace,Consolas,monospace; font-size:13px; }
 pre { background:color-mix(in srgb, var(--bg) 70%, black); color:#e6edf3; padding:14px; border-radius:8px; overflow:auto; }
 .pill { display:inline-block; padding:3px 10px; border-radius:999px; font-size:13px; font-weight:700; border:1px solid currentColor; }
 .ok{color:var(--ok)} .warn{color:var(--warn)} .bad{color:var(--bad)}
 dl { display:grid; grid-template-columns:auto 1fr; gap:6px 16px; margin:12px 0 0; font-size:14px; }
 dt { opacity:.65; } dd { margin:0; word-break:break-all; }
 table { width:100%; border-collapse:collapse; margin-top:12px; font-size:.92rem; }
 td { padding:6px 8px; border-top:1px solid var(--line); vertical-align:middle; }
 .muted { color:#66788a; font-size:.9rem; }
</style></head><body><main>
<h1>Connect your computer</h1>
<p class="sub">Book Studio writes your book on your own PC, using the Codex you are already signed in to. This page pairs that machine with your account.</p>

<section><h2>1. You</h2><div id="who">Checking…</div></section>

<section><h2>2. Your machine's token</h2>
  <p>Create one token per computer. It is shown once and is not stored anywhere it can be read back, so a lost token is replaced rather than recovered.</p>
  <div class="row"><input id="label" placeholder="Which computer is this? e.g. Gio desktop" style="flex:1;min-width:220px;padding:9px;border-radius:7px;border:1px solid var(--line);background:transparent;color:inherit">
  <button id="mint">Create token</button></div>
  <div id="token"></div>
</section>

<section><h2>3. Set up that computer</h2>
  <p><strong>On the computer you just named</strong>, press the Windows key, type <strong>PowerShell</strong>,
  open it, and paste this one line in. It does not matter which folder the window is in.</p>
  <pre id="cmd">Create a token above and the command will appear here.</pre>
  <div class="row"><button class="secondary" id="copy">Copy the command</button><span id="copied" class="muted"></span></div>
  <p>It installs or updates Book Studio on that computer, connects it to your account, and sets it to
  reconnect whenever you sign in to Windows. Running it again is safe. Leave the window it opens running:
  that is what writes your books.</p>
  <details><summary>What that computer needs first</summary>
  <ul>
    <li><strong>Git for Windows</strong> - <a href="https://git-scm.com/download/win">git-scm.com/download/win</a>.
        Accept every default. The command above tells you if it is missing.</li>
    <li><strong>Codex, signed in</strong> - your book is written on that computer by Codex.
        Install <a href="https://nodejs.org">Node.js</a>, then run <code>npm install -g @openai/codex</code>
        and <code>codex login</code>. You can connect first and do this after.</li>
  </ul>
  <p class="muted">Nothing here needs an administrator, and nothing is installed into Program Files.</p>
  </details>
  <p class="muted">Already have Book Studio on that computer? Open PowerShell in its folder and the same
  command uses the copy you have instead of fetching another.</p>
</section>

<section><h2>4. Your computers</h2>
  <div class="row"><button class="secondary" id="check">Test connection</button><span id="state" class="pill">Not checked</span></div>
  <dl id="detail"></dl>
</section>
<section id="people" hidden><h2>5. People</h2>
  <p class="muted">Only you can see this. A new password is shown once, here, and the person has to
  change it the first time they sign in. Nothing is emailed, so nothing can be opened on their behalf.</p>
  <div class="row"><input id="newEmail" placeholder="name@vocate.org" style="flex:1;min-width:220px;padding:9px;border-radius:7px;border:1px solid var(--line);background:transparent;color:inherit">
  <button id="add">Add or reset</button></div>
  <div id="issued"></div>
  <table id="roster"></table>
</section>

<section><h2>Your session</h2>
  <div class="row"><button class="secondary" id="signout">Sign out</button></div>
</section>
</main><script>
const el = (id) => document.getElementById(id);
async function api(path, options) {
  const response = await fetch(path, options);
  if (!response.ok) throw new Error(await response.text());
  return response.json();
}
api("/api/identity").then((identity) => {
  el("who").innerHTML = identity.email
    ? "Signed in as <strong>" + identity.email + "</strong>. Books and machines you create belong to this address."
    : "<span class='pill warn'>Not signed in</span> Sign-in is not switched on yet, so everything here is shared. Do not put a real course through it until it is.";
}).catch(() => { el("who").textContent = "Could not read your identity."; });

el("mint").addEventListener("click", async () => {
  el("mint").disabled = true;
  try {
    const created = await api("/api/runner-tokens", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ label: el("label").value }) });
    el("token").innerHTML = "<p>Copy this now — it is not shown again.</p><pre>" + created.token + "</pre>";
    // Escaped twice on purpose. This line lives inside a template literal,
      // which eats one level of escaping: written once, the browser received a
      // real newline inside a quoted string and the page's entire script stopped
      // parsing, so nothing on it worked at all.
      el("cmd").textContent = 'irm ' + location.origin + '/setup.ps1?token=' + created.token + ' | iex';
  } catch (error) { el("token").innerHTML = "<p class='bad'>" + error.message + "</p>"; }
  finally { el("mint").disabled = false; }
});

// Every computer of yours that is running Book Studio, each on its own line.
// One line per machine matters: a laptop and a desktop used to overwrite each
// other, so a laptop that had never connected could show its owner a "Ready"
// that belonged to a different computer in another building.
function describeAge(seenAt) {
  const seen = Date.parse(seenAt || "");
  if (!seen) return "";
  const seconds = Math.max(0, Math.round((Date.now() - seen) / 1000));
  if (seconds < 90) return "just now";
  if (seconds < 3600) return Math.round(seconds / 60) + " minutes ago";
  return new Date(seen).toLocaleString();
}

el("check").addEventListener("click", async () => {
  el("state").textContent = "Checking…"; el("state").className = "pill";
  el("detail").innerHTML = "";
  try {
    const status = await api("/api/runner/status");
    const machines = status.machines || (status.connected ? [status] : []);
    if (!machines.length) {
      el("state").textContent = "No machine"; el("state").className = "pill warn";
      el("detail").innerHTML = "<dt>Why</dt><dd>" + status.detail + "</dd>";
      return;
    }
    const working = machines.filter((machine) => (machine.codex || {}).status === "Connected");
    el("state").textContent = working.length ? (machines.length === 1 ? "Ready" : working.length + " of " + machines.length + " ready") : "Codex unavailable";
    el("state").className = "pill " + (working.length ? "ok" : "bad");
    el("detail").innerHTML = machines.map((machine) => {
      const codex = machine.codex || {};
      const name = machine.runnerName || machine.label || "unnamed computer";
      const good = codex.status === "Connected";
      return "<dt>" + name + "</dt><dd>" +
        (good ? "Ready" : "Codex " + (codex.status || "unknown").toLowerCase()) +
        (codex.version ? " - " + codex.version : "") +
        " - last heard from " + describeAge(machine.seenAt) +
        (good ? "" : "<br>" + (codex.detail || "")) + "</dd>";
    }).join("");
  } catch (error) {
    el("state").textContent = "Error"; el("state").className = "pill bad";
    el("detail").innerHTML = "<dt>Detail</dt><dd>" + error.message + "</dd>";
  }
});

// The list of people is an administrator's view. For everyone else the request
// is refused and the section simply never appears.
async function loadPeople() {
  try {
    const listing = await api("/api/users");
    el("people").hidden = false;
    el("roster").innerHTML = listing.users
      .sort((left, right) => left.email.localeCompare(right.email))
      .map((person) => {
        const state = person.disabled ? "disabled" : (person.mustChangePassword ? "password not yet changed" : "active");
        const last = person.lastSignInAt ? new Date(person.lastSignInAt).toLocaleString() : "never signed in";
        const remove = person.email === listing.you
          ? ""
          : '<button class="secondary remove" data-email="' + person.email + '">Remove</button>';
        return "<tr><td>" + person.email + (person.admin ? " <span class='pill'>admin</span>" : "") +
          "</td><td>" + state + "</td><td>" + last + "</td><td>" + remove + "</td></tr>";
      }).join("");
    [...el("roster").querySelectorAll("button.remove")].forEach((button) => {
      button.addEventListener("click", async () => {
        button.disabled = true;
        try {
          await api("/api/users/remove", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email: button.dataset.email }) });
          await loadPeople();
        } catch (error) { el("issued").innerHTML = "<p class='bad'>" + error.message + "</p>"; button.disabled = false; }
      });
    });
  } catch (error) { /* not an administrator, or not signed in */ }
}
loadPeople();

el("add").addEventListener("click", async () => {
  const email = el("newEmail").value.trim();
  if (!email) return;
  el("add").disabled = true;
  try {
    const created = await api("/api/users", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email }) });
    el("issued").innerHTML = "<p>Give this to <strong>" + created.user.email + "</strong> in person or over chat, not by email. " +
      "It is shown once and has to be changed at their first sign-in.</p><pre>" + created.password + "</pre>";
    el("newEmail").value = "";
    await loadPeople();
  } catch (error) { el("issued").innerHTML = "<p class='bad'>" + error.message + "</p>"; }
  finally { el("add").disabled = false; }
});


el("copy").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(el("cmd").textContent);
    el("copied").textContent = "Copied. Paste it into PowerShell on that computer.";
  } catch (error) {
    el("copied").textContent = "Select the line above and copy it.";
  }
});
el("signout").addEventListener("click", async () => {
  try { await api("/api/logout", { method: "POST" }); } catch (error) { /* the cookie goes either way */ }
  location.href = "/login";
});
</script></body></html>`;

// The sign-in screen. It deliberately does nothing by email: no magic link, no
// emailed code, nothing a mail scanner can open on the designer's behalf.
const LOGIN_HTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sign in</title>
<style>
 :root { --ink:#0d3553; --line:#dbdbdb; --bg:#f9f9f9; --panel:#ffffff; --bad:#b42318; --ok:#067647; }
 @media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --ink:#eef4f8; --line:#2b3d4c; --bg:#0f1a22; --panel:#16242f; } }
 :root[data-theme="dark"] { --ink:#eef4f8; --line:#2b3d4c; --bg:#0f1a22; --panel:#16242f; }
 * { box-sizing:border-box; }
 body { margin:0; min-height:100vh; display:grid; place-items:center; padding:24px 16px;
        font:16px/1.5 "Segoe UI",system-ui,sans-serif; color:var(--ink); background:var(--bg); }
 .card { width:100%; max-width:420px; background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:28px; }
 h1 { margin:0 0 4px; font-size:1.4rem; }
 p.lead { margin:0 0 20px; color:#66788a; font-size:.92rem; }
 label { display:block; margin:14px 0 6px; font-weight:600; font-size:.9rem; }
 input { width:100%; padding:10px 12px; font:inherit; color:inherit; background:transparent;
         border:1px solid var(--line); border-radius:8px; }
 button { margin-top:20px; width:100%; padding:11px; font:inherit; font-weight:600; color:#fff;
          background:#0d6efd; border:0; border-radius:8px; cursor:pointer; }
 button[disabled] { opacity:.6; cursor:default; }
 .note { margin-top:16px; font-size:.9rem; }
 .bad { color:var(--bad); }
 .ok { color:var(--ok); }
 .hint { margin-top:18px; padding-top:16px; border-top:1px solid var(--line); font-size:.85rem; color:#66788a; }
</style></head><body>
<div class="card">
  <h1 id="title">Sign in to Book Studio</h1>
  <p class="lead" id="lead">Use the address and password your administrator gave you.</p>
  <form id="signin">
    <label for="email">Email</label>
    <input id="email" type="email" autocomplete="username" required autofocus>
    <label for="password">Password</label>
    <input id="password" type="password" autocomplete="current-password" required>
    <button id="go" type="submit">Sign in</button>
  </form>
  <form id="change" hidden>
    <label for="newPassword">New password</label>
    <input id="newPassword" type="password" autocomplete="new-password" minlength="12" required>
    <label for="confirmPassword">Repeat it</label>
    <input id="confirmPassword" type="password" autocomplete="new-password" minlength="12" required>
    <button id="save" type="submit">Set password and continue</button>
  </form>
  <p class="note" id="note"></p>
  <p class="hint">Forgotten it? An administrator issues a new one; there is no reset email, because a
  mail scanner that opens the link first would spend it before you could.</p>
</div>
<script>
const el = (id) => document.getElementById(id);
const next = new URLSearchParams(location.search).get("next") || "/connect";
async function send(path, body) {
  const response = await fetch(path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  const text = await response.text();
  if (!response.ok) throw new Error(text || ("Request failed: " + response.status));
  return text ? JSON.parse(text) : {};
}
el("signin").addEventListener("submit", async (event) => {
  event.preventDefault();
  el("go").disabled = true;
  el("note").textContent = "";
  try {
    const result = await send("/api/login", { email: el("email").value, password: el("password").value });
    if (result.mustChangePassword) {
      el("title").textContent = "Choose your own password";
      el("lead").textContent = "The one you were given works once. Pick a password of at least 12 characters.";
      el("signin").hidden = true;
      el("change").hidden = false;
      el("newPassword").focus();
      return;
    }
    location.href = next;
  } catch (error) {
    el("note").className = "note bad";
    el("note").textContent = error.message;
  } finally { el("go").disabled = false; }
});
el("change").addEventListener("submit", async (event) => {
  event.preventDefault();
  if (el("newPassword").value !== el("confirmPassword").value) {
    el("note").className = "note bad";
    el("note").textContent = "The two passwords are different.";
    return;
  }
  el("save").disabled = true;
  try {
    await send("/api/password", { currentPassword: el("password").value, newPassword: el("newPassword").value });
    location.href = next;
  } catch (error) {
    el("note").className = "note bad";
    el("note").textContent = error.message;
  } finally { el("save").disabled = false; }
});
</script></body></html>`;

const APP_HTML = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Ebook Generator</title>
  <style>
    :root {
      --legend-blue: #0d3553;
      --hero-blue: #1d6ba6;
      --horizon-blue: #0095c8;
      --journey-green: #15eac4;
      --gracious-gray: #f9f9f9;
      --medium-gray: #dbdbdb;
      --integrity-gray: #444444;
      --white: #ffffff;
      --danger: #b42318;
      --warning: #a15c00;
      --success: #067647;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      color: var(--legend-blue);
      background: var(--gracious-gray);
      font-family: Arial, Helvetica, sans-serif;
      line-height: 1.45;
    }
    button, input, textarea { font: inherit; }
    .topbar {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 24px;
      padding: 20px 28px;
      background: var(--white);
      border-bottom: 1px solid var(--medium-gray);
    }
    .topbar h1 { margin: 0; font-size: 24px; line-height: 1.1; }
    .topbar p { margin: 4px 0 0; color: var(--integrity-gray); }
    .workspace {
      display: grid;
      grid-template-columns: minmax(320px, 430px) minmax(0, 1fr);
      gap: 22px;
      padding: 22px;
    }
    .panel {
      background: var(--white);
      border: 1px solid var(--medium-gray);
      border-radius: 8px;
      padding: 18px;
    }
    .notice {
      margin: 0 22px;
      padding: 12px 14px;
      border: 1px solid var(--horizon-blue);
      border-radius: 8px;
      background: #f4fbff;
      color: var(--integrity-gray);
    }
    h2 { margin: 0 0 16px; font-size: 18px; }
    label { display: block; }
    label span {
      display: block;
      margin-bottom: 6px;
      color: var(--integrity-gray);
      font-size: 13px;
      font-weight: 700;
    }
    input[type="text"], input[type="number"], input:not([type]), textarea {
      width: 100%;
      border: 1px solid var(--medium-gray);
      border-radius: 6px;
      padding: 10px 11px;
      color: var(--legend-blue);
      background: var(--white);
    }
    input[type="file"] {
      width: 100%;
      border: 1px dashed var(--horizon-blue);
      border-radius: 6px;
      padding: 12px;
      background: #f4fbff;
    }
    textarea { min-height: 108px; resize: vertical; }
    form { display: grid; gap: 14px; }
    .field-grid { display: grid; grid-template-columns: 1fr; gap: 12px; }
    .controls-row {
      display: grid;
      grid-template-columns: minmax(130px, 1fr) 1fr 1fr;
      gap: 12px;
      align-items: end;
    }
    .check-field {
      display: flex;
      align-items: center;
      min-height: 42px;
      gap: 8px;
      border: 1px solid var(--medium-gray);
      border-radius: 6px;
      padding: 8px 10px;
    }
    .check-field input { width: 18px; height: 18px; }
    .check-field span { margin: 0; }
    .actions { display: flex; align-items: center; gap: 12px; }
    button {
      border: 1px solid var(--hero-blue);
      border-radius: 6px;
      padding: 10px 14px;
      color: var(--white);
      background: var(--hero-blue);
      cursor: pointer;
    }
    button.secondary { color: var(--legend-blue); background: var(--white); }
    button:disabled { cursor: wait; opacity: 0.65; }
    #formStatus, #jobCount { color: var(--integrity-gray); font-size: 13px; }
    .section-heading { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
    .jobs-list { display: grid; gap: 10px; }
    .job-row {
      display: grid;
      grid-template-columns: minmax(0, 1fr) 120px;
      gap: 14px;
      align-items: start;
      border: 1px solid var(--medium-gray);
      border-radius: 8px;
      padding: 14px;
    }
    .job-title { font-weight: 700; }
    .job-meta, .job-log { color: var(--integrity-gray); font-size: 13px; }
    .job-status {
      justify-self: start;
      min-width: 92px;
      border-radius: 999px;
      padding: 5px 9px;
      text-align: center;
      font-size: 12px;
      font-weight: 700;
      background: var(--gracious-gray);
      border: 1px solid var(--medium-gray);
    }
    .job-status.completed { color: var(--success); border-color: var(--success); background: #ecfdf3; }
    .job-status.failed { color: var(--danger); border-color: var(--danger); background: #fef3f2; }
    .job-status.queued, .job-status.running { color: var(--warning); border-color: var(--warning); background: #fff7e8; }
    .job-log, .file-list, .artifact-list { grid-column: 1 / -1; }
    .file-list { display: flex; flex-wrap: wrap; gap: 8px; }
    .artifact-list { display: flex; flex-wrap: wrap; gap: 8px; }
    .file-chip {
      display: inline-flex;
      align-items: center;
      min-height: 30px;
      border: 1px solid var(--horizon-blue);
      border-radius: 6px;
      padding: 5px 8px;
      color: var(--legend-blue);
      background: #f4fbff;
      font-size: 13px;
    }
    .artifact-list a {
      display: inline-flex;
      align-items: center;
      min-height: 34px;
      border: 1px solid var(--horizon-blue);
      border-radius: 6px;
      padding: 7px 10px;
      color: var(--legend-blue);
      text-decoration: none;
      background: #f4fbff;
    }
    .empty-state {
      border: 1px dashed var(--medium-gray);
      border-radius: 8px;
      padding: 24px;
      color: var(--integrity-gray);
    }
    @media (max-width: 900px) {
      .workspace { grid-template-columns: 1fr; }
      .job-row { grid-template-columns: 1fr; }
    }
    @media (max-width: 620px) {
      .topbar { align-items: flex-start; flex-direction: column; }
      .workspace { padding: 14px; }
      .notice { margin: 0 14px; }
      .controls-row { grid-template-columns: 1fr; }
    }
    .topbar-actions { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
    .who { color: var(--muted, #667085); font-size: 0.9rem; }
    .secondary-link { color: inherit; font-size: 0.9rem; }
    .scope-switch { display: flex; gap: 8px; margin: 4px 0 14px; }
    .scope { background: transparent; border: 1px solid var(--border, #d0d5dd); color: inherit;
             padding: 6px 12px; border-radius: 999px; font: inherit; font-size: 0.9rem; cursor: pointer; }
    .scope.active { border-color: #0d6efd; color: #0d6efd; font-weight: 600; }
  </style>
</head>
<body>
  <header class="topbar">
    <div>
      <h1>Ebook Generator</h1>
      <p>Cloud intake queue for Book Studio</p>
    </div>
    <div class="topbar-actions">
      <span id="who" class="who"></span>
      <a class="secondary-link" href="/connect">Your computer</a>
      <button id="refreshJobs" class="secondary" type="button">Refresh</button>
      <button id="signout" class="secondary" type="button">Sign out</button>
    </div>
  </header>
  <main class="workspace">
    <section class="panel">
      <h2>Create Book</h2>
      <form id="bookForm">
        <div class="field-grid">
          <label>
            <span>Course code</span>
            <input name="courseCode" autocomplete="off" placeholder="HU2000">
          </label>
          <label>
            <span>Book title</span>
            <input name="title" autocomplete="off" placeholder="Critical Thinking and Problem Solving">
          </label>
        </div>
        <label>
          <span>Source files</span>
          <input name="files" type="file" multiple required>
        </label>
        <label>
          <span>Production notes</span>
          <textarea name="specialInstructions" placeholder="Audience, tone, special requirements, chapter emphasis, or exclusions"></textarea>
        </label>
        <div class="controls-row">
          <label>
            <span>Research per chapter</span>
            <input name="maxResearchPerChapter" type="number" min="1" max="8" value="3">
          </label>
          <label class="check-field">
            <input name="skipResearch" type="checkbox">
            <span>Skip research</span>
          </label>
          <label class="check-field">
            <input name="skipOpenStaxFetch" type="checkbox">
            <span>Offline OpenStax</span>
          </label>
        </div>
        <div class="actions">
          <button id="generateButton" type="submit">Create Job</button>
          <span id="formStatus" role="status" aria-live="polite"></span>
        </div>
      </form>
    </section>
    <section class="panel">
      <div class="section-heading">
        <h2>Books</h2>
        <span id="jobCount"></span>
      </div>
      <div class="scope-switch">
        <button id="scopeMine" class="scope active" type="button">My books</button>
        <button id="scopeEveryone" class="scope" type="button">Everyone's books</button>
      </div>
      <div id="jobsList" class="jobs-list"></div>
    </section>
  </main>
  <template id="jobTemplate">
    <article class="job-row">
      <div>
        <div class="job-title"></div>
        <div class="job-meta"></div>
      </div>
      <div class="job-status"></div>
      <div class="job-log"></div>
      <div class="file-list"></div>
      <div class="artifact-list"></div>
    </article>
  </template>
  <script>
    var form = document.querySelector("#bookForm");
    var formStatus = document.querySelector("#formStatus");
    var generateButton = document.querySelector("#generateButton");
    var refreshJobsButton = document.querySelector("#refreshJobs");
    var jobsList = document.querySelector("#jobsList");
    var jobCount = document.querySelector("#jobCount");
    var jobTemplate = document.querySelector("#jobTemplate");

    function setStatus(message) { formStatus.textContent = message || ""; }
    function readFileAsBase64(file) {
      return new Promise(function(resolve, reject) {
        var reader = new FileReader();
        reader.onload = function() {
          var result = String(reader.result || "");
          var commaIndex = result.indexOf(",");
          resolve(commaIndex >= 0 ? result.slice(commaIndex + 1) : result);
        };
        reader.onerror = function() { reject(reader.error); };
        reader.readAsDataURL(file);
      });
    }
    async function api(path, options) {
      var response = await fetch(path, Object.assign({ headers: { "content-type": "application/json" } }, options || {}));
      if (!response.ok) {
        var message = await response.text();
        throw new Error(message || "Request failed: " + response.status);
      }
      var text = await response.text();
      return text ? JSON.parse(text) : null;
    }
    function formatDate(value) {
      if (!value) return "";
      var date = new Date(value);
      if (Number.isNaN(date.getTime())) return value;
      return date.toLocaleString();
    }
    function formatBytes(value) {
      var bytes = Number(value || 0);
      if (bytes < 1024) return bytes + " B";
      if (bytes < 1024 * 1024) return Math.round(bytes / 1024) + " KB";
      return (bytes / 1024 / 1024).toFixed(1) + " MB";
    }
    function lastLogLine(job) {
      var entries = Array.isArray(job.log) ? job.log : [];
      if (!entries.length) return "";
      var last = entries[entries.length - 1];
      return formatDate(last.at) + " - " + last.message;
    }
    function renderJobs(jobs) {
      jobsList.textContent = "";
      jobCount.textContent = jobs.length + " job" + (jobs.length === 1 ? "" : "s");
      if (!jobs.length) {
        var empty = document.createElement("div");
        empty.className = "empty-state";
        empty.textContent = scope === "everyone" ? "Nobody has started a book yet." : "You have not started a book yet.";
        jobsList.append(empty);
        return;
      }
      jobs.forEach(function(job) {
        var node = jobTemplate.content.firstElementChild.cloneNode(true);
        var title = node.querySelector(".job-title");
        var meta = node.querySelector(".job-meta");
        var status = node.querySelector(".job-status");
        var log = node.querySelector(".job-log");
        var fileList = node.querySelector(".file-list");
        var artifactList = node.querySelector(".artifact-list");
        title.textContent = (job.courseCode ? job.courseCode + ": " : "") + (job.title || "Untitled Book");
        var owner = job.owner || "unclaimed";
        var who = scope === "everyone" ? owner + " | " : "";
        meta.textContent = who + "Created " + formatDate(job.createdAt) + " | " + ((job.uploadedFiles || []).length) + " source file(s)";
        status.textContent = job.status || "Unknown";
        status.classList.add(String(job.status || "").toLowerCase());
        log.textContent = job.error ? job.error : lastLogLine(job);
        (job.uploadedFiles || []).forEach(function(file) {
          var chip = document.createElement("span");
          chip.className = "file-chip";
          chip.textContent = file.name + " (" + formatBytes(file.size) + ")";
          fileList.append(chip);
        });
        (job.artifacts || []).forEach(function(artifact) {
          var link = document.createElement("a");
          link.href = artifact.url;
          link.textContent = artifact.name + " (" + formatBytes(artifact.size) + ")";
          artifactList.append(link);
        });
        jobsList.append(node);
      });
    }
    var scope = "mine";
    async function loadJobs() {
      var data = await api("/api/jobs?scope=" + scope);
      document.querySelector("#who").textContent = data.you ? "Signed in as " + data.you : "";
      renderJobs(data.jobs || []);
    }
    function setScope(next) {
      scope = next;
      document.querySelector("#scopeMine").classList.toggle("active", scope === "mine");
      document.querySelector("#scopeEveryone").classList.toggle("active", scope === "everyone");
      loadJobs();
    }
    document.querySelector("#scopeMine").addEventListener("click", function() { setScope("mine"); });
    document.querySelector("#scopeEveryone").addEventListener("click", function() { setScope("everyone"); });
    document.querySelector("#signout").addEventListener("click", async function() {
      try { await api("/api/logout", { method: "POST" }); } catch (error) { /* the cookie goes either way */ }
      location.href = "/login";
    });
    form.addEventListener("submit", async function(event) {
      event.preventDefault();
      generateButton.disabled = true;
      try {
        var formData = new FormData(form);
        var selectedFiles = Array.from(form.elements.files.files || []);
        if (!selectedFiles.length) throw new Error("Choose at least one source file.");
        var files = [];
        for (var i = 0; i < selectedFiles.length; i++) {
          var file = selectedFiles[i];
          setStatus("Reading " + file.name + "...");
          files.push({ name: file.name, size: file.size, type: file.type, contentBase64: await readFileAsBase64(file) });
        }
        var payload = {
          courseCode: formData.get("courseCode"),
          title: formData.get("title"),
          specialInstructions: formData.get("specialInstructions"),
          maxResearchPerChapter: Number(formData.get("maxResearchPerChapter") || 3),
          skipResearch: formData.get("skipResearch") === "on",
          skipOpenStaxFetch: formData.get("skipOpenStaxFetch") === "on",
          files: files
        };
        setStatus("Creating Cloudflare job...");
        await api("/api/jobs", { method: "POST", body: JSON.stringify(payload) });
        form.reset();
        form.elements.maxResearchPerChapter.value = 3;
        setStatus("Job queued.");
        await loadJobs();
      } catch (error) {
        setStatus(error.message);
      } finally {
        generateButton.disabled = false;
      }
    });
    refreshJobsButton.addEventListener("click", function() { loadJobs().catch(function(error) { setStatus(error.message); }); });
    loadJobs().catch(function(error) { setStatus(error.message); });
    setInterval(function() { loadJobs().catch(function() {}); }, 5000);
  </script>
</body>
</html>`;

function jsonResponse(value, init = {}) {
  return new Response(JSON.stringify(value, null, 2), {
    ...init,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      ...(init.headers || {})
    }
  });
}

function textResponse(value, init = {}) {
  return new Response(value, {
    ...init,
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "no-store",
      ...(init.headers || {})
    }
  });
}

function nowIso() {
  return new Date().toISOString();
}

function makeJobId() {
  return crypto.randomUUID().replace(/-/g, "").slice(0, 12);
}

function estimateBase64Bytes(value) {
  const text = String(value || "");
  const padding = text.endsWith("==") ? 2 : text.endsWith("=") ? 1 : 0;
  return Math.max(0, Math.floor((text.length * 3) / 4) - padding);
}

async function readIndex(env) {
  return (await env.BOOK_STUDIO_KV.get(JOB_INDEX_KEY, "json")) || [];
}

async function writeIndex(env, ids) {
  await env.BOOK_STUDIO_KV.put(JOB_INDEX_KEY, JSON.stringify(ids.slice(0, 100)));
}

async function readJob(env, id) {
  return await env.BOOK_STUDIO_KV.get("job:" + id, "json");
}

async function writeJob(env, job) {
  job.updatedAt = nowIso();
  await env.BOOK_STUDIO_KV.put("job:" + job.id, JSON.stringify(job));
}

async function listJobs(env) {
  const ids = await readIndex(env);
  const jobs = [];
  for (const id of ids) {
    const job = await readJob(env, id);
    if (job) jobs.push(job);
  }
  return jobs;
}

function getRouteId(pathname, suffix = "") {
  const escapedSuffix = suffix.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = pathname.match(new RegExp("^/api/jobs/([^/]+)" + escapedSuffix + "$"));
  return match ? match[1] : "";
}

function getRunnerRouteId(pathname, suffix = "") {
  const escapedSuffix = suffix.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = pathname.match(new RegExp("^/api/runner/jobs/([^/]+)" + escapedSuffix + "$"));
  return match ? match[1] : "";
}

// Cloudflare Access authenticates the person in the browser and puts their
// identity on the request. It cannot authenticate the agent on their PC, which
// runs unattended with no browser, so the agent carries a token the signed-in
// person minted for it. One token per machine, owned by an email address, so
// a job can say who asked for it and whose PC produced it.
// Cloudflare Access puts cf-access-authenticated-user-email on a request it
// has authenticated, but that header is only trustworthy if the request could
// not have arrived any other way. A worker keeps its workers.dev hostname,
// which Access does not sit in front of, so anyone could send that header and
// claim to be anyone. The signed assertion is what actually proves identity.
let accessKeyCache = { jwks: null, fetchedAt: 0 };

function decodeBase64Url(value) {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((value.length + 3) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

async function getAccessKeys(env) {
  const teamDomain = env.ACCESS_TEAM_DOMAIN || "";
  if (!teamDomain) return null;
  // Cached for an hour: Access rotates keys, and refetching per request would
  // add a round trip to every call.
  if (accessKeyCache.jwks && Date.now() - accessKeyCache.fetchedAt < 3600000) return accessKeyCache.jwks;
  const response = await fetch("https://" + teamDomain + "/cdn-cgi/access/certs");
  if (!response.ok) return accessKeyCache.jwks;
  const jwks = await response.json();
  accessKeyCache = { jwks, fetchedAt: Date.now() };
  return jwks;
}

async function verifyAccessAssertion(request, env) {
  const token = request.headers.get("cf-access-jwt-assertion") || "";
  if (!token) return "";
  const parts = token.split(".");
  if (parts.length !== 3) return "";
  const jwks = await getAccessKeys(env);
  if (!jwks || !Array.isArray(jwks.keys)) return "";
  let header;
  let payload;
  try {
    header = JSON.parse(new TextDecoder().decode(decodeBase64Url(parts[0])));
    payload = JSON.parse(new TextDecoder().decode(decodeBase64Url(parts[1])));
  } catch (error) {
    return "";
  }
  const jwk = jwks.keys.find((key) => key.kid === header.kid);
  if (!jwk) return "";
  const key = await crypto.subtle.importKey(
    "jwk",
    { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: "RS256", ext: true },
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"]
  );
  const signed = new TextEncoder().encode(parts[0] + "." + parts[1]);
  const valid = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, decodeBase64Url(parts[2]), signed);
  if (!valid) return "";
  // A signature alone is not enough: the token must be for this application
  // and still current, or a valid token minted for a different app would pass.
  const audience = env.ACCESS_AUD || "";
  const audiences = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
  if (audience && !audiences.includes(audience)) return "";
  const now = Math.floor(Date.now() / 1000);
  if (payload.exp && now >= payload.exp) return "";
  if (payload.nbf && now < payload.nbf) return "";
  return String(payload.email || "");
}

// Cloudflare Access can sign a person in, but its one-time PIN arrives by
// email, and Microsoft Defender Safe Links opens the link in that email before
// the designer can, which spends the code and greets them with "already used".
// vocate.org is on a Microsoft tenant that is not ours to reconfigure, so Book
// Studio also keeps its own accounts: a password an administrator issues, no
// email in the loop, nothing for a scanner to click. Access is still checked
// first where it is in front, so this is an addition, not a replacement.
const SESSION_COOKIE = "bs_session";
const SESSION_SECONDS = 7 * 24 * 60 * 60;
// The Workers runtime refuses a PBKDF2 request above 100,000 iterations, and
// says so only when a password is actually checked: 210,000 passed every local
// test and failed the first real sign-in. This is the ceiling, not a choice,
// and raising it breaks every login rather than strengthening anything.
const PASSWORD_ITERATIONS = 100000;
const MIN_PASSWORD_LENGTH = 12;
// Guessing is answered by a lockout rather than by a slower reply, because a
// worker has no memory between requests to slow anything down with.
const MAX_LOGIN_FAILURES = 8;
const LOGIN_LOCK_SECONDS = 900;

function randomHex(byteLength) {
  const bytes = new Uint8Array(byteLength);
  crypto.getRandomValues(bytes);
  return [...bytes].map((value) => value.toString(16).padStart(2, "0")).join("");
}

// A password a person has to read off a screen and type once. Ambiguous
// characters are left out so 0/O and 1/l cannot cost someone their first login.
function generatePassword() {
  const alphabet = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789";
  const bytes = new Uint8Array(20);
  crypto.getRandomValues(bytes);
  return [...bytes].map((value) => alphabet[value % alphabet.length]).join("");
}

function normalizeEmail(value) {
  return String(value || "").trim().toLowerCase();
}

async function derivePasswordHash(password, saltHex, iterations) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(password), { name: "PBKDF2" }, false, ["deriveBits"]);
  const salt = new Uint8Array((saltHex.match(/../g) || []).map((pair) => parseInt(pair, 16)));
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", salt, iterations, hash: "SHA-256" }, key, 256);
  return [...new Uint8Array(bits)].map((value) => value.toString(16).padStart(2, "0")).join("");
}

// Comparing two hashes with === returns sooner the earlier they differ, which
// tells a patient attacker how much of a guess was right.
function equalsConstantTime(left, right) {
  if (typeof left !== "string" || typeof right !== "string" || left.length !== right.length) return false;
  let difference = 0;
  for (let i = 0; i < left.length; i++) difference |= left.charCodeAt(i) ^ right.charCodeAt(i);
  return difference === 0;
}

function userKey(email) {
  return "user:" + normalizeEmail(email);
}

async function readUser(env, email) {
  if (!normalizeEmail(email)) return null;
  return await env.BOOK_STUDIO_KV.get(userKey(email), "json");
}

async function writeUser(env, user) {
  await env.BOOK_STUDIO_KV.put(userKey(user.email), JSON.stringify(user));
}

// The stored record never contains the password itself, only the salt, the
// iteration count and the derived hash, so a copy of the store is not a list
// of passwords.
async function setUserPassword(env, user, password) {
  const salt = randomHex(16);
  user.salt = salt;
  user.iterations = PASSWORD_ITERATIONS;
  user.passwordHash = await derivePasswordHash(password, salt, PASSWORD_ITERATIONS);
  user.passwordSetAt = nowIso();
  await writeUser(env, user);
  return user;
}

async function passwordMatches(user, password) {
  if (!user || !user.passwordHash || !user.salt) return false;
  const candidate = await derivePasswordHash(password, user.salt, user.iterations || PASSWORD_ITERATIONS);
  return equalsConstantTime(candidate, user.passwordHash);
}

// Who may add and remove people. Kept in configuration rather than in the
// store, so losing the database cannot promote anyone.
function isAdmin(env, email) {
  const admins = String(env.ADMIN_EMAILS || "").split(",").map(normalizeEmail).filter(Boolean);
  return admins.includes(normalizeEmail(email));
}

function publicUser(env, user) {
  if (!user) return null;
  return {
    email: user.email,
    name: user.name || "",
    admin: isAdmin(env, user.email),
    mustChangePassword: Boolean(user.mustChangePassword),
    disabled: Boolean(user.disabled),
    createdAt: user.createdAt || "",
    createdBy: user.createdBy || "",
    lastSignInAt: user.lastSignInAt || ""
  };
}

async function startSession(env, email) {
  const id = randomHex(32);
  const record = {
    email: normalizeEmail(email),
    createdAt: nowIso(),
    expiresAt: new Date(Date.now() + SESSION_SECONDS * 1000).toISOString()
  };
  // KV expires the record on its own, so a forgotten session cannot outlive
  // the cookie that carries it.
  await env.BOOK_STUDIO_KV.put("session:" + id, JSON.stringify(record), { expirationTtl: SESSION_SECONDS });
  return id;
}

function sessionCookie(id, seconds) {
  return SESSION_COOKIE + "=" + id + "; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=" + seconds;
}

function readCookie(request, name) {
  const header = request.headers.get("cookie") || "";
  for (const part of header.split(";")) {
    const trimmed = part.trim();
    const equals = trimmed.indexOf("=");
    if (equals > 0 && trimmed.slice(0, equals) === name) return trimmed.slice(equals + 1);
  }
  return "";
}

// A session is re-read from the store on every request, and the account with
// it, so disabling someone takes effect at once rather than in seven days.
async function accountIdentity(request, env) {
  const id = readCookie(request, SESSION_COOKIE);
  if (!id) return "";
  const session = await env.BOOK_STUDIO_KV.get("session:" + id, "json");
  if (!session) return "";
  if (session.expiresAt && Date.parse(session.expiresAt) <= Date.now()) return "";
  const user = await readUser(env, session.email);
  if (!user || user.disabled) return "";
  return normalizeEmail(session.email);
}

function loginFailureKey(email) {
  return "login:fail:" + normalizeEmail(email);
}

async function loginFailures(env, email) {
  return Number((await env.BOOK_STUDIO_KV.get(loginFailureKey(email))) || 0);
}

async function recordLoginFailure(env, email) {
  const count = (await loginFailures(env, email)) + 1;
  await env.BOOK_STUDIO_KV.put(loginFailureKey(email), String(count), { expirationTtl: LOGIN_LOCK_SECONDS });
  return count;
}

// Every route that reads or changes a book goes through this, so there is one
// answer to "who is this" rather than a check per route that can be forgotten.
async function requireUser(request, env) {
  const email = await accessIdentity(request, env);
  if (email) return { email };
  if (env.REQUIRE_ACCESS === "true") {
    return { response: textResponse("Sign in to use Book Studio.", { status: 401 }) };
  }
  return { email: "local-development" };
}

async function accessIdentity(request, env) {
  const verified = await verifyAccessAssertion(request, env);
  if (verified) return verified;
  const account = await accountIdentity(request, env);
  if (account) return account;
  // Without Access configured there is no assertion to verify. The header is
  // accepted only then, so local development works and production does not
  // silently fall back to an unverified claim.
  if (env.REQUIRE_ACCESS === "true") return "";
  return request.headers.get("cf-access-authenticated-user-email") || "";
}

async function resolveRunner(request, env) {
  const presented = request.headers.get("x-book-runner-token") || "";
  if (!presented) return null;
  const record = await env.BOOK_STUDIO_KV.get("runner:token:" + presented, "json");
  // The key is carried along so a token minted before machines had ids can be
  // given one the first time it reports, rather than needing every designer to
  // create a new token by hand.
  if (record) return { ...record, tokenKey: "runner:token:" + presented };
  // The original single shared token, kept so an existing agent keeps working
  // until its owner mints a personal one.
  const legacy = await env.BOOK_STUDIO_KV.get(RUNNER_TOKEN_KEY);
  if (legacy && presented === legacy) return { owner: "", label: "shared token", legacy: true };
  return null;
}

async function isRunnerAuthorized(request, env) {
  return (await resolveRunner(request, env)) !== null;
}

async function requireRunner(request, env) {
  const runner = await resolveRunner(request, env);
  if (!runner) return { response: textResponse("Unauthorized", { status: 401 }) };
  return { runner };
}

// A machine may only touch books belonging to the person who minted its token.
// Without this any agent could claim, read and overwrite anyone's book, which
// is worse than the shared token it replaced.
function runnerMayTouch(runner, job) {
  if (!job) return false;
  if (runner.legacy) return true;
  if (!job.owner) return true;
  return job.owner === runner.owner;
}

function publicJob(job) {
  if (!job) return null;
  return {
    ...job,
    uploadedFiles: (job.uploadedFiles || []).map((file) => ({
      name: file.name,
      type: file.type || "",
      size: file.size || 0,
      role: file.role || "context"
    }))
  };
}

async function listPublicJobs(env) {
  const jobs = await listJobs(env);
  return jobs.map(publicJob);
}

function appendJobLog(job, message) {
  const entries = Array.isArray(job.log) ? job.log : [];
  entries.push({ at: nowIso(), message: String(message || "") });
  job.log = entries.slice(-80);
}

async function getJobFiles(env, job) {
  const files = [];
  for (const file of job.uploadedFiles || []) {
    const contentBase64 = await getFileBodyBase64(env, file.key);
    if (!contentBase64) continue;
    files.push({
      name: file.name || "uploaded-source",
      type: file.type || "",
      size: file.size || 0,
      role: file.role || "context",
      contentBase64
    });
  }
  return files;
}

async function getArtifact(env, job, name) {
  const artifact = (job.artifacts || []).find((item) => item.fileName === name || item.name === name);
  if (!artifact) return null;
  const object = await env.BOOK_STUDIO_FILES.get(artifact.key);
  if (!object) return null;
  return { artifact, object };
}

function bytesToBase64(bytes) {
  // Chunked: spreading a whole book into String.fromCharCode overflows the
  // call stack on anything larger than a few hundred kilobytes.
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

function base64ToBytes(base64) {
  const binary = atob(base64 || "");
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

async function createJob(request, env, owner) {
  const payload = await request.json();
  const files = Array.isArray(payload.files) ? payload.files : [];
  if (files.length === 0) {
    return textResponse("Upload at least one source file.", { status: 400 });
  }

  let totalBytes = 0;
  for (const file of files) {
    const size = Number(file.size || estimateBase64Bytes(file.contentBase64));
    if (size > MAX_FILE_BYTES) {
      return textResponse("File is too large for this tester: " + file.name, { status: 413 });
    }
    totalBytes += size;
  }
  if (totalBytes > MAX_TOTAL_UPLOAD_BYTES) {
    return textResponse("Total upload is too large for this tester.", { status: 413 });
  }

  const id = makeJobId();
  const createdAt = nowIso();
  const uploadedFiles = [];
  for (let i = 0; i < files.length; i++) {
    const file = files[i];
    const fileKey = fileObjectKey(id, "source", i);
    await putFileBody(env, fileKey, file.contentBase64, file.type);
    uploadedFiles.push({
      name: file.name || "uploaded-source",
      type: file.type || "",
      size: Number(file.size || estimateBase64Bytes(file.contentBase64)),
      key: fileKey,
      role: i === 0 ? "spec" : "context"
    });
  }

  const job = {
    id,
    owner: owner || "",
    status: "Queued",
    createdAt,
    updatedAt: createdAt,
    title: payload.title || "Untitled Book",
    courseCode: payload.courseCode || "",
    specialInstructions: payload.specialInstructions || "",
    sourceContextPath: "cloudflare-kv",
    outputFolder: "",
    uploadedFiles,
    options: {
      maxResearchPerChapter: Number(payload.maxResearchPerChapter || 3),
      skipResearch: Boolean(payload.skipResearch),
      skipOpenStaxFetch: Boolean(payload.skipOpenStaxFetch)
    },
    artifacts: [],
    log: [
      { at: createdAt, message: "Cloudflare intake job created." },
      { at: createdAt, message: "Waiting for a local Book Runner connection." }
    ],
    error: ""
  };

  await writeJob(env, job);
  const index = await readIndex(env);
  await writeIndex(env, [id, ...index.filter((existing) => existing !== id)]);
  return jsonResponse(job, { status: 201 });
}

// The oldest Book Studio the cloud can drive. These are released separately:
// the worker deploys in seconds, a designer PC updates when a release is
// published and pulled. A worker that needs something newer than the copy on
// that PC produced, in the one case that reached a designer, a PowerShell
// binding error about an empty string. Raise this when the cloud starts
// depending on something new, and the setup script says so in words.
const MINIMUM_AGENT_VERSION = "2026.09.22.3";
// One paste, into any PowerShell window. A designer should not have to know
// what a clone is, which folder to stand in, or that a token goes in a
// parameter. This script is what the connect page hands them: it checks Git,
// fetches or updates Book Studio, and starts the agent with their token.
//
// It carries no backticks and no ${ } on purpose. PowerShell uses both, and
// this lives inside a template literal that would eat them.
function setupScript(token, origin) {
  const safeToken = String(token || "").replace(/[^A-Za-z0-9]/g, "");
  return [
    "# Book Studio - connect this computer.",
    "# Paste this whole thing into PowerShell. It is safe to run again.",
    "",
    "$ErrorActionPreference = 'Stop'",
    "$token = '" + safeToken + "'",
    "$repository = 'https://github.com/gduartevocate/book-studio.git'",
    "",
    "Write-Host ''",
    "Write-Host 'Book Studio - connecting this computer' -ForegroundColor Cyan",
    "Write-Host ''",
    "",
    "# 1. Git. Without it there is nothing to fetch Book Studio with.",
    "if (-not (Get-Command git -ErrorAction SilentlyContinue)) {",
    "    Write-Host 'Git for Windows is not installed on this computer.' -ForegroundColor Yellow",
    "    Write-Host 'Install it from https://git-scm.com/download/win, accept every default, then run this again.'",
    "    return",
    "}",
    "",
    "# 2. Book Studio itself. If this window is already standing in a copy, that",
    "#    copy is used; otherwise one is kept in the local app data folder, which",
    "#    needs no administrator and is never synced to OneDrive.",
    "if (Test-Path -LiteralPath (Join-Path (Get-Location) 'cloud-book-runner.ps1')) {",
    "    $folder = (Get-Location).Path",
    "    Write-Host ('Using the Book Studio folder you are in: ' + $folder)",
    "}",
    "else {",
    "    $folder = Join-Path $env:LOCALAPPDATA 'Book Studio'",
    "    if (Test-Path -LiteralPath (Join-Path $folder '.git')) {",
    "        Write-Host ('Updating Book Studio in ' + $folder)",
    "        git -C $folder pull --ff-only | Out-Host",
    "    }",
    "    else {",
    "        Write-Host ('Installing Book Studio into ' + $folder)",
    "        git clone --depth 1 $repository $folder | Out-Host",
    "    }",
    "}",
    "",
    "if (-not (Test-Path -LiteralPath (Join-Path $folder 'cloud-book-runner.ps1'))) {",
    "    Write-Host 'Book Studio was fetched but the agent is missing from it.' -ForegroundColor Red",
    "    Write-Host 'Update Book Studio and try again, or tell whoever administers it.'",
    "    return",
    "}",
    "",
    "# The copy on this computer has to be new enough for what follows. It is",
    "# released separately from the cloud, so it can legitimately be behind,",
    "# and saying so is far better than the binding error an old one throws.",
    "$needed = '" + MINIMUM_AGENT_VERSION + "'",
    "$installed = ''",
    "$versionFile = Join-Path $folder 'book-studio/version.json'",
    "if (Test-Path -LiteralPath $versionFile) {",
    "    try { $installed = (Get-Content -LiteralPath $versionFile -Raw | ConvertFrom-Json).version } catch { $installed = '' }",
    "}",
    "function ConvertTo-Comparable([string]$value) {",
    "    $parts = @($value -split '[.]' | ForEach-Object { [int]($_ -replace '[^0-9]', '0') })",
    "    while ($parts.Count -lt 4) { $parts += 0 }",
    "    return ($parts[0] * 1000000L) + ($parts[1] * 10000L) + ($parts[2] * 100L) + $parts[3]",
    "}",
    "if (-not $installed -or (ConvertTo-Comparable $installed) -lt (ConvertTo-Comparable $needed)) {",
    "    Write-Host ''",
    "    Write-Host ('The Book Studio on this computer is older than the cloud expects.') -ForegroundColor Yellow",
    "    Write-Host ('  on this computer: ' + $(if ($installed) { $installed } else { 'unknown' }))",
    "    Write-Host ('  needed:           ' + $needed)",
    "    Write-Host 'This command already tried to update it, so a new release has to be published.'",
    "    Write-Host 'Tell whoever administers Book Studio, and run this again afterwards.'",
    "    return",
    "}",
    "",
    "# 3. Codex. The book is written here, by the Codex this person is signed in",
    "#    to, so a missing or signed-out Codex is the one thing this script",
    "#    cannot fix for them.",
    "if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {",
    "    Write-Host ''",
    "    Write-Host 'Codex is not installed on this computer.' -ForegroundColor Yellow",
    "    Write-Host 'Book Studio writes your book here, using Codex, so it is needed before a book can be made.'",
    "    Write-Host 'Install Node.js from https://nodejs.org, then run:  npm install -g @openai/codex'",
    "    Write-Host 'Then run:  codex login'",
    "    Write-Host 'You can finish connecting now and install Codex afterwards.'",
    "    Write-Host ''",
    "}",
    "",
    "# 4. Connect, remember the token, and come back on its own after a restart.",
    "#",
    "#    A managed computer refuses to run a .ps1 file at all, and that is not",
    "#    something a designer can change: -ExecutionPolicy Bypass is itself",
    "#    overridden when the policy comes from their organisation. So the agent",
    "#    is read and run as a command, exactly as this script is being run now.",
    "#    Setting the per-user policy is attempted first as a courtesy, because it",
    "#    makes everything else on that computer easier, and ignored when refused.",
    "try { Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop }",
    "catch { Write-Host 'This computer does not allow changing the script policy. Continuing without it.' }",
    "",
    "Set-Location $folder",
    "$agent = Join-Path $folder 'cloud-book-runner.ps1'",
    "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath $agent))) -Token $token -StartWithWindows -ProjectRoot $folder",
    ""
  ].join("\n");
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const pathname = url.pathname.replace(/\/+$/, "") || "/";

    try {
      // A page asked for while signed out goes to the sign-in screen. Only the
      // API answers 401, because only the API has a caller that can read one.
      if (request.method === "GET" && (pathname === "/connect" || pathname === "/" || pathname === "/index.html")) {
        if (env.REQUIRE_ACCESS === "true" && !(await accessIdentity(request, env))) {
          return new Response(null, { status: 302, headers: { location: "/login?next=" + encodeURIComponent(pathname) } });
        }
      }

      if (request.method === "GET" && pathname === "/connect") {
        return new Response(CONNECT_HTML, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
      }

      if (request.method === "GET" && (pathname === "/" || pathname === "/index.html")) {
        return new Response(APP_HTML, {
          headers: {
            "content-type": "text/html; charset=utf-8",
            "cache-control": "no-store"
          }
        });
      }

      // Served to PowerShell, not to a browser: no session, because the token
      // in it is the credential, and a designer pasting this has no cookies.
      if (request.method === "GET" && pathname === "/setup.ps1") {
        return new Response(setupScript(url.searchParams.get("token"), url.origin), {
          headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" }
        });
      }

      if (request.method === "GET" && pathname === "/login") {
        return new Response(LOGIN_HTML, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
      }

      // Signing in is the one route that cannot require being signed in.
      if (request.method === "POST" && pathname === "/api/login") {
        const payload = await request.json().catch(() => ({}));
        const email = normalizeEmail(payload.email);
        const password = String(payload.password || "");
        if (!email || !password) return textResponse("Enter your email and password.", { status: 400 });
        if ((await loginFailures(env, email)) >= MAX_LOGIN_FAILURES) {
          return textResponse("Too many attempts. Wait fifteen minutes, or ask an administrator for a new password.", { status: 429 });
        }
        const user = await readUser(env, email);
        // One message for an unknown address and for a wrong password, so this
        // page cannot be used to find out who has an account.
        if (!user || user.disabled || !(await passwordMatches(user, password))) {
          await recordLoginFailure(env, email);
          return textResponse("That email and password do not match an account.", { status: 401 });
        }
        await env.BOOK_STUDIO_KV.delete(loginFailureKey(email));
        user.lastSignInAt = nowIso();
        await writeUser(env, user);
        const session = await startSession(env, email);
        return jsonResponse(
          { email, mustChangePassword: Boolean(user.mustChangePassword), admin: isAdmin(env, email) },
          { headers: { "set-cookie": sessionCookie(session, SESSION_SECONDS) } }
        );
      }

      if (request.method === "POST" && pathname === "/api/logout") {
        const id = readCookie(request, SESSION_COOKIE);
        if (id) await env.BOOK_STUDIO_KV.delete("session:" + id);
        return jsonResponse({ signedOut: true }, { headers: { "set-cookie": sessionCookie("", 0) } });
      }

      if (request.method === "POST" && pathname === "/api/password") {
        const user = await requireUser(request, env);
        if (user.response) return user.response;
        const payload = await request.json().catch(() => ({}));
        const record = await readUser(env, user.email);
        if (!record) return textResponse("This account signs in through Cloudflare Access and has no password here.", { status: 400 });
        if (!(await passwordMatches(record, String(payload.currentPassword || "")))) {
          return textResponse("The current password is wrong.", { status: 401 });
        }
        const chosen = String(payload.newPassword || "");
        if (chosen.length < MIN_PASSWORD_LENGTH) {
          return textResponse("Use at least " + MIN_PASSWORD_LENGTH + " characters.", { status: 400 });
        }
        record.mustChangePassword = false;
        await setUserPassword(env, record, chosen);
        return jsonResponse({ changed: true });
      }

      if (request.method === "GET" && pathname === "/api/users") {
        const user = await requireUser(request, env);
        if (user.response) return user.response;
        if (!isAdmin(env, user.email)) return textResponse("Only an administrator can see the list of people.", { status: 403 });
        const listed = await env.BOOK_STUDIO_KV.list({ prefix: "user:" });
        const people = [];
        for (const key of listed.keys) {
          people.push(publicUser(env, await env.BOOK_STUDIO_KV.get(key.name, "json")));
        }
        return jsonResponse({ users: people.filter(Boolean), you: user.email });
      }

      // Adding someone, and issuing a replacement password, are the same act:
      // the password is generated here, shown once, and must be changed at the
      // first sign-in.
      if (request.method === "POST" && pathname === "/api/users") {
        const user = await requireUser(request, env);
        if (user.response) return user.response;
        if (!isAdmin(env, user.email)) return textResponse("Only an administrator can add people.", { status: 403 });
        const payload = await request.json().catch(() => ({}));
        const email = normalizeEmail(payload.email);
        if (!email || !email.includes("@")) return textResponse("Enter the email address of the person.", { status: 400 });
        const existing = await readUser(env, email);
        const record = existing || { email, createdAt: nowIso(), createdBy: user.email };
        if (payload.name !== undefined) record.name = String(payload.name || "").slice(0, 120);
        record.disabled = Boolean(payload.disabled);
        record.mustChangePassword = true;
        const password = generatePassword();
        await setUserPassword(env, record, password);
        await env.BOOK_STUDIO_KV.delete(loginFailureKey(email));
        return jsonResponse({ user: publicUser(env, record), password, replaced: Boolean(existing) });
      }

      if (request.method === "POST" && pathname === "/api/users/remove") {
        const user = await requireUser(request, env);
        if (user.response) return user.response;
        if (!isAdmin(env, user.email)) return textResponse("Only an administrator can remove people.", { status: 403 });
        const payload = await request.json().catch(() => ({}));
        const email = normalizeEmail(payload.email);
        if (!email) return textResponse("Say whose account to remove.", { status: 400 });
        if (email === normalizeEmail(user.email)) return textResponse("You cannot remove your own account.", { status: 400 });
        await env.BOOK_STUDIO_KV.delete(userKey(email));
        return jsonResponse({ removed: email });
      }

      if (request.method === "GET" && pathname === "/api/health") {
        return jsonResponse({ ok: true, app: "ebook-generator", storage: "kv" });
      }

      if (request.method === "GET" && pathname === "/api/jobs") {
        const user = await requireUser(request, env);
        if (user.response) return user.response;
        const all = await listPublicJobs(env);
        // A designer sees their own books first. Everyone's books are one
        // click away, because a team writing courses together has to be able
        // to see what is in flight and who has it. Jobs made before ownership
        // existed have no owner and stay visible rather than disappearing
        // from the person who made them.
        const scope = url.searchParams.get("scope") === "everyone" ? "everyone" : "mine";
        const jobs = scope === "everyone"
          ? all
          : all.filter((job) => !job.owner || job.owner === user.email);
        return jsonResponse({ jobs, you: user.email, scope });
      }

      if (request.method === "POST" && pathname === "/api/jobs") {
        const user = await requireUser(request, env);
        if (user.response) return user.response;
        return await createJob(request, env, user.email);
      }

      if (request.method === "POST" && pathname === "/api/runner-tokens") {
        const user = await requireUser(request, env);
        if (user.response) return user.response;
        const owner = user.email;
        const payload = await request.json().catch(() => ({}));
        const label = String(payload.label || "").slice(0, 80) || "Unnamed machine";
        const token = crypto.randomUUID().replace(/-/g, "") + crypto.randomUUID().replace(/-/g, "");
        // The id is what keeps two computers apart. Without it every machine
        // a person owns wrote to the same place, so a laptop and a desktop
        // overwrote each other and the page could only ever show one.
        const record = { id: randomHex(8), owner: owner || "local-development", label, createdAt: nowIso() };
        await env.BOOK_STUDIO_KV.put("runner:token:" + token, JSON.stringify(record));
        // Returned once. It is not stored anywhere it can be read back, so a
        // lost token is replaced rather than recovered.
        return jsonResponse({ token, owner: record.owner, label, createdAt: record.createdAt });
      }

      if (request.method === "GET" && pathname === "/api/identity") {
        return jsonResponse({ email: await accessIdentity(request, env), accessRequired: env.REQUIRE_ACCESS === "true" });
      }

      // The agent reports which machine it is and whether Codex answers there.
      // The cloud cannot discover either on its own.
      if (request.method === "POST" && pathname === "/api/runner/status") {
        const auth = await requireRunner(request, env);
        if (auth.response) return auth.response;
        const payload = await request.json().catch(() => ({}));
        // A token from before machines were told apart earns an id here, once,
        // and the single record it used to share is cleared so its machine does
        // not appear twice.
        if (!auth.runner.id && auth.runner.tokenKey) {
          auth.runner.id = randomHex(8);
          const { tokenKey, ...stored } = auth.runner;
          await env.BOOK_STUDIO_KV.put(tokenKey, JSON.stringify(stored));
          await env.BOOK_STUDIO_KV.delete("runner:status:" + (auth.runner.owner || "shared"));
        }
        const record = {
          id: auth.runner.id || "legacy",
          owner: auth.runner.owner || "",
          label: auth.runner.label || "",
          runnerName: String(payload.runnerName || "").slice(0, 120),
          codex: payload.codex || null,
          seenAt: nowIso()
        };
        // One key per machine, under its owner. A token minted before ids
        // existed keeps the old single key so it does not stop reporting.
        const statusKey = auth.runner.id
          ? "runner:status:" + (auth.runner.owner || "shared") + ":" + auth.runner.id
          : "runner:status:" + (auth.runner.owner || "shared");
        await env.BOOK_STUDIO_KV.put(statusKey, JSON.stringify(record), {
          // A machine that stops reporting stops being shown as connected,
          // rather than appearing online forever after it is switched off.
          expirationTtl: 900
        });
        return jsonResponse(record);
      }

      // What the connect screen reads: is my machine there, and is Codex
      // working on it?
      if (request.method === "GET" && pathname === "/api/runner/status") {
        const user = await requireUser(request, env);
        if (user.response) return user.response;
        // Every machine this person has, newest sighting first. A machine
        // stops being listed fifteen minutes after its agent stops talking,
        // so the list is what is actually running rather than what once ran.
        const machines = [];
        const listed = await env.BOOK_STUDIO_KV.list({ prefix: "runner:status:" + user.email + ":" });
        for (const key of listed.keys) {
          const record = await env.BOOK_STUDIO_KV.get(key.name, "json");
          if (record) machines.push(record);
        }
        // Tokens minted before machines had ids, and the shared token from
        // before sign-in existed, still report to the old single keys.
        const single = await env.BOOK_STUDIO_KV.get("runner:status:" + user.email, "json");
        if (single) machines.push(single);
        if (!machines.length && env.REQUIRE_ACCESS !== "true") {
          const shared = await env.BOOK_STUDIO_KV.get("runner:status:shared", "json");
          if (shared) machines.push(shared);
        }
        machines.sort((left, right) => String(right.seenAt || "").localeCompare(String(left.seenAt || "")));
        if (!machines.length) {
          return jsonResponse({
            connected: false,
            machines: [],
            detail: "No computer of yours is running Book Studio right now. Open the window you started it in and check it is still going, or run the command above again on that computer."
          });
        }
        // connected and the first machine stay in the reply so an older page
        // still shows something sensible.
        return jsonResponse({ connected: true, machines, ...machines[0] });
      }

      if (request.method === "GET" && pathname === "/api/runner/jobs") {
        const auth = await requireRunner(request, env);
        if (auth.response) return auth.response;
        const jobs = await listJobs(env);
        return jsonResponse({ jobs: jobs.filter((job) => job.status === "Queued" && runnerMayTouch(auth.runner, job)) });
      }

      let runnerJobId = getRunnerRouteId(pathname, "/claim");
      if (request.method === "POST" && runnerJobId) {
        const auth = await requireRunner(request, env);
        if (auth.response) return auth.response;
        const job = await readJob(env, runnerJobId);
        if (!job) return textResponse("Job not found", { status: 404 });
        if (!runnerMayTouch(auth.runner, job)) return textResponse("This book belongs to another designer.", { status: 403 });
        if (job.status !== "Queued") return jsonResponse(job);
        const payload = await request.json().catch(() => ({}));
        job.status = "Running";
        job.error = "";
        job.runner = {
          name: payload.runnerName || "Local Book Runner",
          claimedAt: nowIso()
        };
        appendJobLog(job, "Claimed by " + job.runner.name + ".");
        await writeJob(env, job);
        return jsonResponse(job);
      }

      runnerJobId = getRunnerRouteId(pathname, "/files");
      if (request.method === "GET" && runnerJobId) {
        const auth = await requireRunner(request, env);
        if (auth.response) return auth.response;
        const job = await readJob(env, runnerJobId);
        if (!job) return textResponse("Job not found", { status: 404 });
        if (!runnerMayTouch(auth.runner, job)) return textResponse("This book belongs to another designer.", { status: 403 });
        return jsonResponse({ job, files: await getJobFiles(env, job) });
      }

      runnerJobId = getRunnerRouteId(pathname, "/log");
      if (request.method === "POST" && runnerJobId) {
        const auth = await requireRunner(request, env);
        if (auth.response) return auth.response;
        const job = await readJob(env, runnerJobId);
        if (!job) return textResponse("Job not found", { status: 404 });
        if (!runnerMayTouch(auth.runner, job)) return textResponse("This book belongs to another designer.", { status: 403 });
        const payload = await request.json().catch(() => ({}));
        appendJobLog(job, payload.message || "");
        await writeJob(env, job);
        return jsonResponse(job);
      }

      runnerJobId = getRunnerRouteId(pathname, "/artifacts");
      if (request.method === "POST" && runnerJobId) {
        const auth = await requireRunner(request, env);
        if (auth.response) return auth.response;
        const job = await readJob(env, runnerJobId);
        if (!job) return textResponse("Job not found", { status: 404 });
        if (!runnerMayTouch(auth.runner, job)) return textResponse("This book belongs to another designer.", { status: 403 });
        const payload = await request.json();
        const artifacts = Array.isArray(job.artifacts) ? job.artifacts : [];
        const fileName = payload.fileName || payload.name || "artifact.bin";
        const artifactKey = fileObjectKey(runnerJobId, "artifact", crypto.randomUUID().replace(/-/g, ""));
        const size = await putFileBody(env, artifactKey, payload.contentBase64, payload.contentType);
        artifacts.push({
          name: payload.name || fileName,
          fileName,
          contentType: payload.contentType || "application/octet-stream",
          size,
          key: artifactKey,
          url: "/api/jobs/" + runnerJobId + "/artifact?name=" + encodeURIComponent(fileName)
        });
        job.artifacts = artifacts;
        appendJobLog(job, "Uploaded artifact: " + fileName + ".");
        await writeJob(env, job);
        return jsonResponse(job);
      }

      runnerJobId = getRunnerRouteId(pathname, "/complete");
      if (request.method === "POST" && runnerJobId) {
        const auth = await requireRunner(request, env);
        if (auth.response) return auth.response;
        const job = await readJob(env, runnerJobId);
        if (!job) return textResponse("Job not found", { status: 404 });
        if (!runnerMayTouch(auth.runner, job)) return textResponse("This book belongs to another designer.", { status: 403 });
        const payload = await request.json().catch(() => ({}));
        job.status = "Completed";
        job.outputSummary = payload.outputSummary || "";
        appendJobLog(job, "Completed by local Book Runner.");
        await writeJob(env, job);
        return jsonResponse(job);
      }

      runnerJobId = getRunnerRouteId(pathname, "/fail");
      if (request.method === "POST" && runnerJobId) {
        const auth = await requireRunner(request, env);
        if (auth.response) return auth.response;
        const job = await readJob(env, runnerJobId);
        if (!job) return textResponse("Job not found", { status: 404 });
        if (!runnerMayTouch(auth.runner, job)) return textResponse("This book belongs to another designer.", { status: 403 });
        const payload = await request.json().catch(() => ({}));
        job.status = "Failed";
        job.error = payload.error || "Runner failed.";
        appendJobLog(job, "Failed: " + job.error);
        await writeJob(env, job);
        return jsonResponse(job);
      }

      runnerJobId = getRunnerRouteId(pathname, "/cancel");
      if (request.method === "POST" && runnerJobId) {
        const auth = await requireRunner(request, env);
        if (auth.response) return auth.response;
        const job = await readJob(env, runnerJobId);
        if (!job) return textResponse("Job not found", { status: 404 });
        if (!runnerMayTouch(auth.runner, job)) return textResponse("This book belongs to another designer.", { status: 403 });
        const payload = await request.json().catch(() => ({}));
        job.status = "Canceled";
        job.error = "";
        appendJobLog(job, payload.reason || "Canceled by local Book Runner.");
        await writeJob(env, job);
        return jsonResponse(job);
      }

      runnerJobId = getRunnerRouteId(pathname, "/requeue");
      if (request.method === "POST" && runnerJobId) {
        const auth = await requireRunner(request, env);
        if (auth.response) return auth.response;
        const job = await readJob(env, runnerJobId);
        if (!job) return textResponse("Job not found", { status: 404 });
        if (!runnerMayTouch(auth.runner, job)) return textResponse("This book belongs to another designer.", { status: 403 });
        const payload = await request.json().catch(() => ({}));
        job.status = "Queued";
        job.error = "";
        job.runner = null;
        appendJobLog(job, payload.reason || "Requeued for local Book Runner.");
        await writeJob(env, job);
        return jsonResponse(job);
      }

      const artifactJobId = getRouteId(pathname, "/artifact");
      if (request.method === "GET" && artifactJobId) {
        const job = await readJob(env, artifactJobId);
        if (!job) return textResponse("Job not found", { status: 404 });
        const name = url.searchParams.get("name") || "";
        const found = await getArtifact(env, job, name);
        if (!found) return textResponse("Artifact not found", { status: 404 });
        return new Response(found.object.body, {
          headers: {
            "content-type": found.artifact.contentType || "application/octet-stream",
            "content-disposition": "attachment; filename=\"" + (found.artifact.fileName || "artifact.bin") + "\"",
            "cache-control": "no-store"
          }
        });
      }

      const jobId = getRouteId(pathname);
      if (request.method === "GET" && jobId) {
        const job = await readJob(env, jobId);
        if (!job) return textResponse("Job not found", { status: 404 });
        return jsonResponse(publicJob(job));
      }

      return textResponse("Not found", { status: 404 });
    } catch (error) {
      return textResponse(error && error.message ? error.message : "Unexpected error", { status: 500 });
    }
  }
};
