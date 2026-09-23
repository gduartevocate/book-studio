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
 .nav { display:flex; gap:14px; align-items:center; margin-bottom:8px; font-size:.92rem; }
 .nav a, .linkish { color:#0d6efd; text-decoration:none; background:none; border:0; padding:0;
                    font:inherit; cursor:pointer; }
 .nav-here { font-weight:600; }
 a:focus-visible, button:focus-visible, input:focus-visible, select:focus-visible { outline:3px solid #0b62d6; outline-offset:2px; }
</style></head><body><main>
<nav class="nav"><a href="/">Book Studio</a><a href="__CLOUD__/">Your books</a><span class="nav-here">Your computer</span><a href="__CLOUD__/guide">Guide</a>
  <button class="linkish" id="signout">Sign out</button></nav>
<h1>Connect your computer</h1>
<p class="sub">Book Studio writes your book on your own PC, using the Codex you are already signed in to. This page pairs that machine with your account.</p>

<section><h2>1. You</h2><div id="who" aria-live="polite">Checking…</div></section>

<section><h2>2. Your machine's token</h2>
  <p>Create one token per computer. It is shown once and is not stored anywhere it can be read back, so a lost token is replaced rather than recovered.</p>
  <div class="row"><input id="label" placeholder="Which computer is this? e.g. Gio desktop" style="flex:1;min-width:220px;padding:9px;border-radius:7px;border:1px solid var(--line);background:transparent;color:inherit">
  <button id="mint">Create token</button></div>
  <div id="token" role="status" aria-live="polite"></div>
</section>

<section><h2>3. Set up that computer</h2>
  <p><strong>On the computer you just named</strong>, press the Windows key, type <strong>PowerShell</strong>,
  open it, and paste this one line in. It does not matter which folder the window is in.</p>
  <pre id="cmd">Create a token above and the command will appear here.</pre>
  <div class="row"><button class="secondary" id="copy">Copy the command</button><span id="copied" class="muted" role="status" aria-live="polite"></span></div>
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
  <div class="row"><button class="secondary" id="check">Test connection</button><span id="state" class="pill" role="status" aria-live="polite">Not checked</span></div>
  <dl id="detail"></dl>
</section>
<section id="people" hidden><h2>5. People</h2>
  <p class="muted">Only you can see this. A new password is shown once, here, and the person has to
  change it the first time they sign in. Nothing is emailed, so nothing can be opened on their behalf.</p>
  <div class="row"><input id="newEmail" placeholder="name@vocate.org" style="flex:1;min-width:220px;padding:9px;border-radius:7px;border:1px solid var(--line);background:transparent;color:inherit">
  <button id="add">Add or reset</button></div>
  <div id="issued" role="status" aria-live="polite"></div>
  <h3 id="requestsHeading" hidden>Waiting for approval</h3>
  <table id="requests" aria-labelledby="requestsHeading"></table>
  <h3>Everyone with an account</h3>
  <table id="roster"></table>
</section>


</main><script>
// Everything written into the page as markup passes through here. The
// values come from other machines, other people and other programs --
// a computer names itself, an administrator types an address -- and any
// one of them could otherwise carry a script into this page.
function esc(value) {
  return String(value == null ? "" : value).replace(/[&<>"']/g, function (character) {
    // Written without a backslash: this page lives inside a template literal,
    // which would eat it and leave three quotes in a row in the browser.
    return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[character];
  });
}
const el = (id) => document.getElementById(id);
async function api(path, options) {
  const response = await fetch(path, options);
  if (!response.ok) throw new Error(await response.text());
  return response.json();
}
api("__CLOUD__/api/identity").then((identity) => {
  el("who").innerHTML = identity.email
    ? "Signed in as <strong>" + esc(identity.email) + "</strong>. Books and machines you create belong to this address."
    : "<span class='pill warn'>Not signed in</span> Sign-in is not switched on yet, so everything here is shared. Do not put a real course through it until it is.";
}).catch(() => { el("who").textContent = "Could not read your identity."; });

el("mint").addEventListener("click", async () => {
  el("mint").disabled = true;
  try {
    const created = await api("__CLOUD__/api/runner-tokens", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ label: el("label").value }) });
    el("token").innerHTML = "<p>Copy this now — it is not shown again.</p><pre>" + esc(created.token) + "</pre>";
    // Escaped twice on purpose. This line lives inside a template literal,
      // which eats one level of escaping: written once, the browser received a
      // real newline inside a quoted string and the page's entire script stopped
      // parsing, so nothing on it worked at all.
      el("cmd").textContent = 'irm ' + location.origin + '/setup.ps1?token=' + created.token + ' | iex';
  } catch (error) { el("token").innerHTML = "<p class='bad'>" + esc(error.message) + "</p>"; }
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
    const status = await api("__CLOUD__/api/runner/status");
    const machines = status.machines || (status.connected ? [status] : []);
    if (!machines.length) {
      el("state").textContent = "No machine"; el("state").className = "pill warn";
      el("detail").innerHTML = "<dt>Why</dt><dd>" + esc(status.detail) + "</dd>";
      return;
    }
    const working = machines.filter((machine) => (machine.codex || {}).status === "Connected");
    const unchecked = machines.filter((machine) => (machine.codex || {}).status === "Unknown");
    el("state").textContent = working.length ? (machines.length === 1 ? "Ready" : working.length + " of " + machines.length + " ready") : "Codex unavailable";
    el("state").className = "pill " + (working.length ? "ok" : (unchecked.length ? "warn" : "bad"));
    el("detail").innerHTML = machines.map((machine) => {
      const codex = machine.codex || {};
      const name = machine.runnerName || machine.label || "unnamed computer";
      const good = codex.status === "Connected";
      // A check that timed out is not a broken Codex, and must not be dressed
      // as one: it sends a designer hunting for a problem that is not there.
      const unknown = (codex.status || "") === "Unknown";
      const state = good ? "Ready" : (unknown ? "Codex not checked yet" : "Codex " + (codex.status || "unknown").toLowerCase());
      const updates = machine.updates || {};
      // Said plainly, because a computer that has stopped updating itself is
      // the reason a fix that shipped weeks ago has not reached this designer.
      const updateNote = machine.version
        ? "<br>Book Studio " + esc(machine.version) + (updates.automatic === false ? " - not updating itself: " + esc(updates.reason || "unknown reason") : " - keeps itself up to date")
        : "";
      return "<dt>" + esc(name) + "</dt><dd>" + esc(state) +
        (codex.version ? " - " + esc(codex.version) : "") +
        " - last heard from " + describeAge(machine.seenAt) +
        (good ? "" : "<br>" + esc(codex.detail || "")) + updateNote + "</dd>";
    }).join("");
  } catch (error) {
    el("state").textContent = "Error"; el("state").className = "pill bad";
    el("detail").innerHTML = "<dt>Detail</dt><dd>" + esc(error.message) + "</dd>";
  }
});

// The list of people is an administrator's view. For everyone else the request
// is refused and the section simply never appears.
async function loadPeople() {
  try {
    const listing = await api("__CLOUD__/api/users");
    el("people").hidden = false;
    el("roster").innerHTML = listing.users
      .sort((left, right) => left.email.localeCompare(right.email))
      .map((person) => {
        const state = person.disabled ? "disabled" : (person.mustChangePassword ? "password not yet changed" : "active");
        const last = person.lastSignInAt ? new Date(person.lastSignInAt).toLocaleString() : "never signed in";
        const remove = person.email === listing.you
          ? ""
          : '<button class="secondary remove" data-email="' + esc(person.email) + '">Remove</button>';
        return "<tr><td>" + esc(person.email) + (person.admin ? " <span class='pill'>admin</span>" : "") +
          "</td><td>" + esc(state) + "</td><td>" + esc(last) + "</td><td>" + remove + "</td></tr>";
      }).join("");
    [...el("roster").querySelectorAll("button.remove")].forEach((button) => {
      button.addEventListener("click", async () => {
        button.disabled = true;
        try {
          await api("__CLOUD__/api/users/remove", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email: button.dataset.email }) });
          await loadPeople();
        } catch (error) { el("issued").innerHTML = "<p class='bad'>" + esc(error.message) + "</p>"; button.disabled = false; }
      });
    });
  } catch (error) { /* not an administrator, or not signed in */ }
}
loadPeople();

// People who asked for an account. Nothing happens for them until an
// administrator who knows them approves: an address on the right domain
// proves only that someone typed it.
async function loadRequests() {
  try {
    const listing = await api("__CLOUD__/api/signups");
    el("requestsHeading").hidden = !listing.requests.length;
    el("requests").innerHTML = listing.requests.map((pending) =>
      "<tr><td>" + esc(pending.name) + "<br><small>" + esc(pending.email) + "</small>" +
      (pending.note ? "<br><small>" + esc(pending.note) + "</small>" : "") + "</td>" +
      "<td><button class='decide' data-action='approve' data-email='" + esc(pending.email) + "'>Approve</button> " +
      "<button class='secondary decide' data-action='decline' data-email='" + esc(pending.email) + "'>Decline</button></td></tr>"
    ).join("");
    [...el("requests").querySelectorAll("button.decide")].forEach((button) => {
      button.addEventListener("click", async () => {
        button.disabled = true;
        try {
          // Each route named in full rather than built from the button, so every
          // address this page calls can be checked against the ones served.
          const decisionPath = button.dataset.action === "approve" ? api("__CLOUD__/api/signups/approve", {
            method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email: button.dataset.email }) })
            : api("__CLOUD__/api/signups/decline", {
            method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email: button.dataset.email }) });
          const decided = await decisionPath;
          el("issued").innerHTML = decided.password
            ? "<p>Approved. Give this password to <strong>" + esc(decided.user.email) + "</strong> in person or over chat, not by email. It is shown once and has to be changed at their first sign-in.</p><pre>" + esc(decided.password) + "</pre>"
            : "<p>Request from " + esc(button.dataset.email) + " declined.</p>";
          await loadRequests();
          await loadPeople();
        } catch (error) { el("issued").innerHTML = "<p class='bad'>" + esc(error.message) + "</p>"; button.disabled = false; }
      });
    });
  } catch (error) { /* not an administrator */ }
}
loadRequests();

el("add").addEventListener("click", async () => {
  const email = el("newEmail").value.trim();
  if (!email) return;
  el("add").disabled = true;
  try {
    const created = await api("__CLOUD__/api/users", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email }) });
    el("issued").innerHTML = "<p>Give this to <strong>" + esc(created.user.email) + "</strong> in person or over chat, not by email. " +
      "It is shown once and has to be changed at their first sign-in.</p><pre>" + esc(created.password) + "</pre>";
    el("newEmail").value = "";
    await loadPeople();
  } catch (error) { el("issued").innerHTML = "<p class='bad'>" + esc(error.message) + "</p>"; }
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
  try { await api("__CLOUD__/api/logout", { method: "POST" }); } catch (error) { /* the cookie goes either way */ }
  location.href = "__CLOUD__/login";
});
</script></body></html>`;

// How Book Studio works, for an instructional designer who is new to it.
// Open to anyone: the people who most need it do not have an account yet.
const GUIDE_HTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>How Book Studio works</title>
<style>
 :root { --ink:#0d3553; --soft:#4a5d6e; --line:#dbe2e8; --bg:#f6f8fa; --panel:#ffffff; --accent:#0b62d6; --note:#fff8e6; --note-line:#e8c35a; }
 @media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --ink:#eef4f8; --soft:#a9bccb; --line:#2b3d4c; --bg:#0f1a22; --panel:#16242f; --accent:#6fb0ff; --note:#2a2412; --note-line:#8a7430; } }
 :root[data-theme="dark"] { --ink:#eef4f8; --soft:#a9bccb; --line:#2b3d4c; --bg:#0f1a22; --panel:#16242f; --accent:#6fb0ff; --note:#2a2412; --note-line:#8a7430; }
 * { box-sizing:border-box; }
 body { margin:0; background:var(--bg); color:var(--ink); font:17px/1.65 "Segoe UI",system-ui,sans-serif; }
 a { color:var(--accent); }
 a:focus-visible, button:focus-visible { outline:3px solid var(--accent); outline-offset:2px; }
 .skip { position:absolute; left:-9999px; top:0; background:var(--panel); padding:8px 12px; }
 .skip:focus { left:16px; top:12px; z-index:10; }
 header.top { border-bottom:1px solid var(--line); background:var(--panel); }
 header.top nav { max-width:880px; margin:0 auto; padding:14px 16px; display:flex; gap:18px; flex-wrap:wrap; align-items:center; font-size:.95rem; }
 header.top nav strong { margin-right:auto; }
 main { max-width:880px; margin:0 auto; padding:28px 16px 64px; }
 h1 { font-size:2rem; line-height:1.2; margin:0 0 8px; }
 .lead { color:var(--soft); font-size:1.1rem; margin:0 0 28px; }
 h2 { font-size:1.4rem; margin:44px 0 10px; padding-top:8px; border-top:1px solid var(--line); }
 h3 { font-size:1.1rem; margin:26px 0 6px; }
 .start { display:grid; gap:12px; grid-template-columns:repeat(auto-fit, minmax(190px, 1fr)); margin:18px 0 8px; padding:0; list-style:none; counter-reset:step; }
 .start li { background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:16px; counter-increment:step; }
 .start li::before { content:counter(step); display:inline-grid; place-items:center; width:28px; height:28px; border-radius:50%; background:var(--accent); color:#fff; font-weight:700; font-size:.9rem; margin-bottom:8px; }
 .start li strong { display:block; margin-bottom:4px; }
 .toc { background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:14px 18px; }
 .toc ol { margin:6px 0 0; padding-left:20px; }
 .stage { background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:4px 20px 16px; margin:14px 0; }
 .stage h3 { margin-top:16px; }
 .decide { margin:10px 0 0; padding:10px 14px; border-left:4px solid var(--accent); background:var(--bg); border-radius:0 8px 8px 0; }
 .note { background:var(--note); border:1px solid var(--note-line); border-radius:10px; padding:12px 16px; margin:16px 0; }
 dl.fix dt { font-weight:700; margin-top:18px; }
 dl.fix dt code { font-weight:600; }
 dl.fix dd { margin:4px 0 0; }
 code { background:rgba(127,127,127,.14); padding:1px 6px; border-radius:5px; font-size:.92em; }
 table { width:100%; border-collapse:collapse; margin:12px 0; font-size:.96rem; }
 th, td { text-align:left; padding:8px 10px; border-bottom:1px solid var(--line); vertical-align:top; }
 th { font-weight:700; }
 footer { max-width:880px; margin:0 auto; padding:0 16px 48px; color:var(--soft); font-size:.9rem; }
</style></head><body>
<a class="skip" href="#content">Skip to the guide</a>
<header class="top"><nav aria-label="Book Studio">
  <strong>Book Studio guide</strong>
  <a href="/">Open Book Studio</a>
  <a href="__CLOUD__/">Your books</a>
  <a href="__CLOUD__/login">Sign in</a>
</nav></header>
<main id="content">
<h1>How Book Studio works</h1>
<p class="lead">Book Studio turns a course document into a finished student e-book. The writing is done by Codex on your
own computer; you make the decisions at each step, and nothing moves forward until you approve it.</p>

<nav class="toc" aria-labelledby="toc-heading">
  <strong id="toc-heading">On this page</strong>
  <ol>
    <li><a href="#new">New here? Start here</a></li>
    <li><a href="#steps">Making a book, step by step</a></li>
    <li><a href="#sources">Sources and readings</a></li>
    <li><a href="#change">Changing your mind</a></li>
    <li><a href="#team">Working with the team</a></li>
    <li><a href="#fix">When something goes wrong</a></li>
    <li><a href="#safe">Keeping your account safe</a></li>
  </ol>
</nav>

<h2 id="new">New here? Start here</h2>
<p>Four things, once. After that you only ever open Book Studio and make books.</p>
<ol class="start">
  <li><strong>Ask for an account</strong>Use <a href="__CLOUD__/signup">the request form</a> with your @vocate.org address. An administrator approves it and gives you a password in person or over chat.</li>
  <li><strong>Sign in and choose a password</strong>The password you are given works once. Book Studio asks you to pick your own, at least 12 characters.</li>
  <li><strong>Connect your computer</strong>Go to <a href="__CLOUD__/connect">Your computer</a> and follow the three steps there. It takes about ten minutes the first time.</li>
  <li><strong>Start your first book</strong>Open Book Studio, upload your course document, and follow the steps below.</li>
</ol>

<h3>What your computer needs</h3>
<p>Your books are written on your own computer, so it has to have two things installed. Nothing here needs an administrator.</p>
<ul>
  <li><strong>Git for Windows</strong> - from <a href="https://git-scm.com/download/win">git-scm.com/download/win</a>. Accept every default.</li>
  <li><strong>Codex, signed in</strong> - install <a href="https://nodejs.org">Node.js</a>, then in PowerShell run <code>npm install -g @openai/codex</code> and then <code>codex login</code>.</li>
</ul>
<p>Then, on <a href="__CLOUD__/connect">Your computer</a>, create a token, copy the one line it shows you, and paste it into
PowerShell (press the Windows key, type <em>PowerShell</em>, open it, paste). It installs Book Studio, connects it to your account,
and tells you when it is done. After that your computer connects by itself whenever you sign in to Windows.</p>
<div class="note"><strong>Your computer has to be on.</strong> Book Studio in your browser is only as available as the computer
that writes your books. If it is switched off, the page tells you so.</div>

<h2 id="steps">Making a book, step by step</h2>

<div class="stage">
<h3>1. Set up the book</h3>
<p>Upload the course document and give the book a name. You also choose:</p>
<table>
  <thead><tr><th scope="col">Choice</th><th scope="col">What it means</th></tr></thead>
  <tbody>
    <tr><td>Kind of document</td><td><strong>Curriculum draft</strong> if it came from the academic team and its learning objectives still need work. <strong>Ebook-ready course file</strong> if the outcomes are final.</td></tr>
    <tr><td>Reading level</td><td>Grade 8 unless you have a reason to change it. The book is written to it and checked against it.</td></tr>
    <tr><td>Sources</td><td>Where the book may draw from. See <a href="#sources">Sources and readings</a>.</td></tr>
    <tr><td>Image setting</td><td>Generic, Healthcare, Business, or your own description.</td></tr>
  </tbody>
</table>
</div>

<div class="stage">
<h3>2. Review the objectives <span style="font-weight:400">(curriculum drafts only)</span></h3>
<p>Book Studio analyses the draft. Course objectives are kept <strong>word for word</strong>. Learning objectives are reworked
to follow good practice, each with the reason for the change and the chapter it belongs to.</p>
<p class="decide">You decide: edit anything you disagree with, then approve. Nothing is planned until you do.</p>
</div>

<div class="stage">
<h3>3. Check the format preview</h3>
<p>A preview of every planned chapter in the finished layout, with placeholder text. It shows the structure, not the writing.</p>
<p class="decide">You decide: change what is wrong and press <strong>Save changes &amp; update preview</strong>, or press <strong>Approve format &amp; generate book</strong>. Check the number of chapters here - it should match the weeks in your document.</p>
</div>

<div class="stage">
<h3>4. Generate the book</h3>
<p>Pressing <strong>Approve format &amp; generate book</strong> starts it. Codex writes every chapter on your computer. This usually takes about twenty minutes. You can close the browser; keep the computer on.</p>
</div>

<div class="stage">
<h3>5. Review and fix</h3>
<p>Book Studio checks the book and lists what needs attention: reading level, citations, objectives that are not taught, readings
that could not be opened. <strong>Fix QA with Codex</strong> repairs what it can; you can also edit chapters yourself.</p>
<p class="decide">You decide: when the book is ready for students.</p>
</div>

<div class="stage">
<h3>6. Export</h3>
<p>Download the Word and web versions from the book's page.</p>
</div>

<h2 id="sources">Sources and readings</h2>
<table>
  <thead><tr><th scope="col">Setting</th><th scope="col">What the book uses</th></tr></thead>
  <tbody>
    <tr><td>Uploaded teaching documents only</td><td>Your documents, nothing else.</td></tr>
    <tr><td>Required readings from blueprint and links below</td><td>The weekly readings listed in your course document. Each one needs a working link, because it is opened, read and cited.</td></tr>
    <tr><td>Required readings, plus research</td><td>The assigned readings, and additional sources the agent finds. Choose the setting above and tick <em>Also research additional sources beyond the required readings</em>.</td></tr>
    <tr><td>Discover additional sources (advanced)</td><td>Sources the agent finds on its own.</td></tr>
  </tbody>
</table>
<p>Every assigned reading must have a link. A reading that is only a title - a PDF file name, a book chapter without a web address -
cannot be opened, so the book cannot teach from it or cite it.</p>

<h2 id="change">Changing your mind</h2>
<dl class="fix">
  <dt>Wrong document, wrong name, or wrong kind of document</dt>
  <dd>Open the book and use <strong>Change setup</strong>. You keep the same book and its history; there is no need to delete it.
  Replacing the document takes the book back to the format preview.</dd>
  <dt>The reading list looks wrong or out of date</dt>
  <dd>Under <strong>Sources and image setting</strong>, press <strong>Read readings from the document again</strong>.</dd>
  <dt>Starting over</dt>
  <dd>Press <strong>Delete book</strong> on its page. This cannot be undone.</dd>
</dl>

<h2 id="team">Working with the team</h2>
<p><a href="__CLOUD__/">Your books</a> shows your own books first. <strong>Everyone's books</strong> shows what every Vocate
designer is working on, who owns it, and how far along it is. Everyone signed in can see every book.</p>

<h2 id="fix">When something goes wrong</h2>
<dl class="fix">
  <dt>"No machine" or "Book Studio is not answering on your computer"</dt>
  <dd>Your computer is off, or Book Studio is not running on it. Switch it on and sign in to Windows; it reconnects by itself.
  If it still does not, run the command from <a href="__CLOUD__/connect">Your computer</a> once more.</dd>
  <dt>"Codex not checked yet" or "Codex unavailable"</dt>
  <dd>"Not checked yet" usually means Codex was slow to answer; it is checked again every ten minutes. "Unavailable" means Codex
  is not installed or not signed in: run <code>codex login</code> in PowerShell.</dd>
  <dt>"Required readings have no URLs"</dt>
  <dd>Some readings have no link. Press <strong>Read readings from the document again</strong>, then add links for any that remain,
  or remove them with <strong>Remove entries with no URL</strong>.</dd>
  <dt>"The course document produced more than one chapter with the same number"</dt>
  <dd>The document repeats its week headings, usually in a reading list at the end. Keep that list under one heading, or remove the
  repeated week labels, then use <strong>Change setup</strong> to upload it again.</dd>
  <dt>"This book is still generating"</dt>
  <dd>Wait for it to finish. If it has clearly stopped, refresh the page; a book that is no longer running clears itself.</dd>
  <dt>"Too many attempts"</dt>
  <dd>Wait fifteen minutes, or ask an administrator for a new password.</dd>
  <dt>I forgot my password</dt>
  <dd>Ask an administrator. There is no reset email: mail scanners open links in emails before you can, which spends them.</dd>
</dl>

<h2 id="safe">Keeping your account safe</h2>
<ul>
  <li>Passwords are never sent by email. Anyone who emails you one is not Book Studio.</li>
  <li>Do not share your password, and do not share the token for your computer.</li>
  <li>Sign out on a computer that other people use.</li>
  <li>Upload only course material. Do not upload student records or personal information.</li>
</ul>
</main>
<footer>Questions? Ask your Book Studio administrator.</footer>
</body></html>`;

// Asking for an account. It creates nothing by itself; see /api/signup.
const SIGNUP_HTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Request an account</title>
<style>
 :root { --ink:#0d3553; --soft:#4a5d6e; --line:#dbdbdb; --bg:#f9f9f9; --panel:#ffffff; --bad:#b42318; --ok:#067647; --accent:#0b62d6; }
 @media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --ink:#eef4f8; --soft:#a9bccb; --line:#2b3d4c; --bg:#0f1a22; --panel:#16242f; --bad:#ff8a80; --ok:#6fd49a; --accent:#6fb0ff; } }
 :root[data-theme="dark"] { --ink:#eef4f8; --soft:#a9bccb; --line:#2b3d4c; --bg:#0f1a22; --panel:#16242f; --bad:#ff8a80; --ok:#6fd49a; --accent:#6fb0ff; }
 * { box-sizing:border-box; }
 body { margin:0; min-height:100vh; display:grid; place-items:center; padding:24px 16px;
        font:16px/1.5 "Segoe UI",system-ui,sans-serif; color:var(--ink); background:var(--bg); }
 main { width:100%; max-width:460px; background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:28px; }
 h1 { margin:0 0 6px; font-size:1.4rem; }
 p.lead { margin:0 0 18px; color:var(--soft); font-size:.95rem; }
 label { display:block; margin:14px 0 6px; font-weight:600; font-size:.92rem; }
 .optional { font-weight:400; color:var(--soft); }
 input, textarea { width:100%; padding:10px 12px; font:inherit; color:inherit; background:transparent;
         border:1px solid var(--line); border-radius:8px; }
 textarea { min-height:72px; resize:vertical; }
 input:focus-visible, textarea:focus-visible, button:focus-visible, a:focus-visible { outline:3px solid var(--accent); outline-offset:2px; }
 button { margin-top:20px; width:100%; padding:11px; font:inherit; font-weight:600; color:#fff;
          background:var(--accent); border:0; border-radius:8px; cursor:pointer; }
 button[disabled] { opacity:.6; cursor:default; }
 .note { margin-top:16px; font-size:.95rem; min-height:1.5em; }
 .bad { color:var(--bad); } .ok { color:var(--ok); }
 .links { margin-top:18px; padding-top:14px; border-top:1px solid var(--line); font-size:.9rem; display:flex; gap:16px; flex-wrap:wrap; }
 a { color:var(--accent); }
</style></head><body>
<main>
  <h1>Request a Book Studio account</h1>
  <p class="lead">For Vocate staff. Use your @vocate.org address. An administrator reviews every request and gives you a
  password in person or over chat; nothing is sent by email.</p>
  <form id="request" novalidate>
    <label for="name">Your name</label>
    <input id="name" name="name" autocomplete="name" required>
    <label for="email">Work email</label>
    <input id="email" name="email" type="email" autocomplete="email" inputmode="email" required aria-describedby="email-hint">
    <p id="email-hint" class="lead" style="margin:6px 0 0">Must end in @vocate.org.</p>
    <label for="note">What will you use it for? <span class="optional">(optional)</span></label>
    <textarea id="note" name="note" maxlength="500"></textarea>
    <button id="send" type="submit">Request account</button>
  </form>
  <p id="status" class="note" role="status" aria-live="polite"></p>
  <nav class="links" aria-label="Other pages">
    <a href="__CLOUD__/login">I already have an account</a>
    <a href="__CLOUD__/guide">How Book Studio works</a>
  </nav>
</main>
<script>
var form = document.getElementById("request");
// Not "status": at the top level of a page that is window.status, a string,
// and an element assigned to it becomes the text "[object HTMLParagraphElement]".
var statusLine = document.getElementById("status");
var send = document.getElementById("send");
form.addEventListener("submit", function (event) {
  event.preventDefault();
  var email = document.getElementById("email").value.trim().toLowerCase();
  var name = document.getElementById("name").value.trim();
  if (!name) { statusLine.className = "note bad"; statusLine.textContent = "Tell us your name."; document.getElementById("name").focus(); return; }
  // No regular expression: this page is served from inside a template
  // literal, which would eat its backslash.
  if (!email.endsWith("@vocate.org")) { statusLine.className = "note bad"; statusLine.textContent = "Use your @vocate.org address."; document.getElementById("email").focus(); return; }
  send.disabled = true;
  statusLine.className = "note";
  statusLine.textContent = "Sending...";
  fetch("__CLOUD__/api/signup", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ name: name, email: email, note: document.getElementById("note").value })
  }).then(function (response) {
    return response.text().then(function (text) {
      if (!response.ok) throw new Error(text || ("Request failed: " + response.status));
      return JSON.parse(text);
    });
  }).then(function (result) {
    form.hidden = true;
    statusLine.className = "note ok";
    statusLine.textContent = result.message;
  }).catch(function (error) {
    statusLine.className = "note bad";
    statusLine.textContent = error.message;
  }).finally(function () { send.disabled = false; });
});
</script>
</body></html>`;

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
 .hint a { color:inherit; font-weight:600; }
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
  <p class="note" id="note" role="status" aria-live="polite"></p>
  <p class="hint"><strong>New here?</strong> <a href="__CLOUD__/signup">Request an account</a> with your @vocate.org address,
  or read <a href="__CLOUD__/guide">how Book Studio works</a>.</p>
  <p class="hint">Forgotten it? An administrator issues a new one; there is no reset email, because a
  mail scanner that opens the link first would spend it before you could.</p>
</div>
<script>
const el = (id) => document.getElementById(id);
const next = new URLSearchParams(location.search).get("next") || "__CLOUD__/connect";
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
    const result = await send("__CLOUD__/api/login", { email: el("email").value, password: el("password").value });
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
    await send("__CLOUD__/api/password", { currentPassword: el("password").value, newPassword: el("newPassword").value });
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
  <title>Your books</title>
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
      <h1>Your books</h1>
      <p>Who is writing what, across everyone</p>
    </div>
    <div class="topbar-actions">
      <span id="who" class="who"></span>
      <a class="secondary-link" href="/">Open Book Studio</a>
      <a class="secondary-link" href="__CLOUD__/connect">Your computer</a>
      <a class="secondary-link" href="__CLOUD__/guide">Guide</a>
      <span id="machineState" class="who"></span>
      <button id="refreshJobs" class="secondary" type="button">Refresh</button>
      <button id="signout" class="secondary" type="button">Sign out</button>
    </div>
  </header>
  <main class="workspace">
    <section class="panel">
      <h2>Start a book in Book Studio</h2>
      <p>This page is where books are listed, not where they are made. A book made here would be
      written at the defaults, with none of the steps a designer needs: the analysis of a curriculum
      draft, the review of the course objectives and learning outcomes, the production settings, the
      format review, the quality findings. All of that is in Book Studio, which runs on your own
      computer and is where a book that failed here would have been caught.</p>
      <p><a class="primary-link" href="/">Open Book Studio</a></p>
    </section>
    <section class="panel">
      <div class="section-heading">
        <h2>Books</h2>
        <span id="jobCount"></span>
      </div>
      <div class="scope-switch">
        <button id="scopeMine" class="scope active" type="button" aria-pressed="true">My books</button>
        <button id="scopeEveryone" class="scope" type="button" aria-pressed="false">Everyone's books</button>
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
    var refreshJobsButton = document.querySelector("#refreshJobs");
    var jobsList = document.querySelector("#jobsList");
    var jobCount = document.querySelector("#jobCount");
    var jobTemplate = document.querySelector("#jobTemplate");

    function setStatus(message) { if (message) console.warn(message); }
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
        // A shared book is a read-only copy from someone's Book Studio: when
        // it was shared says more than a source count it does not have.
        var when = job.status === "Shared"
          ? "Shared " + formatDate(job.sharedAt || job.updatedAt) + " from Book Studio"
          : "Created " + formatDate(job.createdAt) + " | " + ((job.uploadedFiles || []).length) + " source file(s)";
        meta.textContent = who + when;
        status.textContent = job.status || "Unknown";
        status.classList.add(String(job.status || "").toLowerCase());
        // For a shared book, where it is in its workflow; its log only
        // records the files arriving.
        log.textContent = job.error ? job.error
          : (job.status === "Shared" && job.shared && job.shared.stage ? "Stage: " + job.shared.stage : lastLogLine(job));
        (job.uploadedFiles || []).forEach(function(file) {
          var chip = document.createElement("span");
          chip.className = "file-chip";
          chip.textContent = file.name + " (" + formatBytes(file.size) + ")";
          fileList.append(chip);
        });
        (job.artifacts || []).forEach(function(artifact) {
          var link = document.createElement("a");
          // Stored as /api/..., which on the one site belongs to the viewer's
          // own computer: without the prefix every download went there.
          link.href = (String(artifact.url || "").indexOf("/api/") === 0 ? "__CLOUD__" : "") + artifact.url;
          link.textContent = artifact.name + " (" + formatBytes(artifact.size) + ")";
          artifactList.append(link);
        });
        jobsList.append(node);
      });
    }
    var scope = "mine";
    async function loadJobs() {
      var data = await api("__CLOUD__/api/jobs?scope=" + scope);
      document.querySelector("#who").textContent = data.you ? "Signed in as " + data.you : "";
      renderJobs(data.jobs || []);
    }
    function setScope(next) {
      scope = next;
      document.querySelector("#scopeMine").classList.toggle("active", scope === "mine");
      document.querySelector("#scopeEveryone").classList.toggle("active", scope === "everyone");
      document.querySelector("#scopeMine").setAttribute("aria-pressed", String(scope === "mine"));
      document.querySelector("#scopeEveryone").setAttribute("aria-pressed", String(scope === "everyone"));
      loadJobs();
    }
    document.querySelector("#scopeMine").addEventListener("click", function() { setScope("mine"); });
    document.querySelector("#scopeEveryone").addEventListener("click", function() { setScope("everyone"); });
    document.querySelector("#signout").addEventListener("click", async function() {
      try { await api("__CLOUD__/api/logout", { method: "POST" }); } catch (error) { /* the cookie goes either way */ }
      location.href = "__CLOUD__/login";
    });
    refreshJobsButton.addEventListener("click", function() { loadJobs().catch(function(error) { setStatus(error.message); }); });
    loadJobs().catch(function(error) { setStatus(error.message); });
    setInterval(function() { loadJobs().catch(function() {}); }, 5000);
  </script>
</body>
</html>`;

// The cloud pages are served under /cloud on the one site, and at the root
// for anything that still asks for them there. They write __CLOUD__ in front
// of their own links and calls, and it becomes whichever is right.
function withCloudPrefix(html, prefix) {
  return html.split("__CLOUD__").join(prefix);
}

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
// __Host- makes the browser refuse to send it anywhere but the site that set
// it. It used to be set for the whole vocate.app domain, which handed every
// designer's session to every other app on that domain.
const SESSION_COOKIE = "__Host-bs_session";
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
  // Host-only, now that Book Studio and its cloud settings are one site.
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


// An address a person could have, and nothing else: it is shown back on pages,
// so anything looser is a way to store markup.
function isPlainEmail(value) {
  return /^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$/.test(String(value || ""));
}

// Security headers on every response, including pages passed through from a
// designer's machine. Nothing here is framed, sniffed or referred elsewhere.
function withSecurityHeaders(response) {
  const secured = new Response(response.body, response);
  secured.headers.set("X-Content-Type-Options", "nosniff");
  secured.headers.set("Referrer-Policy", "same-origin");
  secured.headers.set("X-Frame-Options", "DENY");
  if (!secured.headers.has("Content-Security-Policy")) {
    secured.headers.set("Content-Security-Policy", "frame-ancestors 'none'; object-src 'none'; base-uri 'self'");
  }
  secured.headers.set("Strict-Transport-Security", "max-age=31536000");
  return secured;
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
  // The single shared token from the first spike is no longer honoured. It
  // could claim any book whoever owned it, and every machine now has a token
  // of its own, tied to the person who connected it.
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
// A machine works only on its own person's books. A book with no owner dates
// from before accounts existed; letting any machine claim those was a way to
// read someone's upload without being them.
// One shared copy per book per owner, found again by the same pair so sharing
// again updates it. Hashed so the id says nothing about either.
async function sharedBookId(owner, localId) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(owner + "|" + localId));
  return "share-" + [...new Uint8Array(digest)].slice(0, 10).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function runnerMayTouch(runner, job) {
  if (!job || !job.owner) return false;
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
    // Everything the agent reads when it runs the generator. Anything dropped
    // here is silently replaced by a default on the designer's PC, twenty
    // minutes later, in a book they then have to read to notice.
    options: {
      maxResearchPerChapter: Number(payload.maxResearchPerChapter || 3),
      skipResearch: Boolean(payload.skipResearch),
      skipOpenStaxFetch: Boolean(payload.skipOpenStaxFetch),
      readingLevel: Number(payload.readingLevel || 8),
      sourceMode: ["UploadedOnly", "Assigned", "Discovery"].includes(payload.sourceMode) ? payload.sourceMode : "UploadedOnly",
      allowAdditionalResearch: Boolean(payload.allowAdditionalResearch),
      imageSettings: payload.imageSettings || { context: "Generic", instructions: "" },
      requiredReadings: Array.isArray(payload.requiredReadings) ? payload.requiredReadings : []
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
const MINIMUM_AGENT_VERSION = "2026.09.22.7";
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
    "$cloud = '" + origin + "'",
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
    "        if ($LASTEXITCODE -ne 0) {",
    "            Write-Host 'Book Studio could not be updated on this computer.' -ForegroundColor Yellow",
    "            Write-Host 'The version check below will say whether the copy you have is new enough.'",
    "        }",
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
    "Write-Host ('Book Studio on this computer: ' + $(if ($installed) { $installed } else { 'unknown' }))",
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
    "",
    "# Started in its own window, minimised, rather than in this one. Pasting",
    "# this command into a window where Book Studio was already running did",
    "# nothing at all -- the text went to the running program as input -- and",
    "# closing that window later took the connection down with it.",
    "# Built as an argument list rather than as one string: Start-Process",
    "# quotes each item itself, and a Book Studio folder can have a space in it.",
    "$inner = '& ([scriptblock]::Create((Get-Content -Raw -LiteralPath ''' + $agent + '''))) ' +",
    "    '-Token ' + $token + ' -StartWithWindows -ProjectRoot ''' + $folder + ''''",
    "$arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Minimized', '-Command', $inner)",
    "Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Minimized | Out-Null",
    "",
    "# And then wait for the computer to appear in the cloud, so the answer to",
    "# 'did that work?' is on this screen rather than on a web page somewhere.",
    "Write-Host 'Connecting...' -NoNewline",
    "$seen = $null",
    "foreach ($attempt in 1..30) {",
    "    Start-Sleep -Seconds 4",
    "    Write-Host '.' -NoNewline",
    "    try {",
    "        $reply = Invoke-RestMethod -Uri ($cloud + '/api/runner/self') -Headers @{ 'x-book-runner-token' = $token }",
    "        if ($reply.reported) { $seen = $reply; break }",
    "    }",
    "    catch { }",
    "}",
    "Write-Host ''",
    "",
    "if (-not $seen) {",
    "    Write-Host 'This computer has not reached Book Studio.' -ForegroundColor Red",
    "    Write-Host 'Book Studio is still trying in a minimised PowerShell window; open it from the taskbar to see why.'",
    "    return",
    "}",
    "",
    "$codexState = if ($seen.codex) { $seen.codex.status } else { 'unknown' }",
    "Write-Host ('Connected as ' + $seen.runnerName) -ForegroundColor Green",
    "if ($codexState -eq 'Connected') {",
    "    Write-Host ('Codex is working here: ' + $seen.codex.version)",
    "    Write-Host 'You can close this window. Book Studio keeps running, and starts again when you sign in to Windows.'",
    "}",
    "elseif ($codexState -eq 'Unknown') {",
    "    Write-Host 'Codex did not answer in time; Book Studio checks again every ten minutes.' -ForegroundColor Yellow",
    "    Write-Host 'You can close this window.'",
    "}",
    "else {",
    "    Write-Host 'Codex is not working on this computer, so books cannot be written here yet.' -ForegroundColor Yellow",
    "    Write-Host ('  ' + $seen.codex.detail)",
    "    Write-Host 'Install Node.js from https://nodejs.org, run:  npm install -g @openai/codex  then:  codex login'",
    "    Write-Host 'The connection itself is fine; nothing here has to be done again afterwards.'",
    "}",
    ""
  ].join("\n");
}

// A rendezvous point for one machine.
//
// The Book Studio a designer knows -- the outcome analysis, the production
// panel, the QA review, the Codex chat -- is thousands of lines of PowerShell
// that only runs on their own PC. Rewriting it in the cloud would make two
// copies of the same rules that drift apart, which is the failure this project
// has been bitten by before. So the browser talks to the cloud, the cloud hands
// each request to the agent on that PC, and the agent answers from the local
// Book Studio. One implementation, reachable from a browser.
//
// This has to be a Durable Object rather than KV: the two sides must see each
// other's writes at once, and KV is eventually consistent.
export class MachineBridge {
  constructor(state) {
    this.state = state;
    // Requests the agent has not collected yet.
    this.pending = [];
    // Browser calls waiting for an answer, by request id.
    this.waiting = new Map();
    // An agent sitting on a long poll with nothing to do yet.
    this.collectors = [];
    this.nextId = 1;
  }

  // The agent is only ever one long poll away, so a request usually leaves
  // immediately; this only queues when the agent is between polls.
  handOut() {
    while (this.collectors.length && this.pending.length) {
      const collector = this.collectors.shift();
      const job = this.pending.shift();
      clearTimeout(collector.timer);
      collector.resolve(job);
    }
  }

  async fetch(request) {
    const url = new URL(request.url);

    // From the browser, through the worker: one request to run over there.
    if (url.pathname === "/request") {
      const job = await request.json();
      // Nothing is listening on the other side. Waiting fifty-five seconds to
      // discover that is not patience, it is a browser tab that hangs and
      // then says something a designer cannot act on.
      const quiet = Date.now() - (this.lastCollectorAt || 0);
      if (!this.collectors.length && quiet > 90000) {
        return jsonResponse({
          bridgeError: "Book Studio is not listening on that computer. It may be running a version from before this worked, which it will replace by itself within the hour, or it may not be running at all.",
          notListening: true
        }, { status: 503 });
      }
      job.id = String(this.nextId++);
      const answer = new Promise((resolve) => {
        const timer = setTimeout(() => {
          this.waiting.delete(job.id);
          // A timeout here means the agent took the request and never came
          // back, which is a different fault from never having collected it.
          resolve(new Response(JSON.stringify({
            bridgeError: "Book Studio on your computer did not answer in time."
          }), { status: 504, headers: { "content-type": "application/json" } }));
        }, 55000);
        this.waiting.set(job.id, { resolve, timer });
      });
      this.pending.push(job);
      this.handOut();
      return await answer;
    }

    // The agent, asking for something to do. It waits rather than polling in a
    // loop, so a designer's click is not held up by a polling interval.
    if (url.pathname === "/next") {
      // When an agent last asked for work, which is how the other half of
      // this object knows whether anyone is there at all.
      this.lastCollectorAt = Date.now();
      if (this.pending.length) {
        return jsonResponse(this.pending.shift());
      }
      const job = await new Promise((resolve) => {
        const collector = { resolve };
        collector.timer = setTimeout(() => {
          this.collectors = this.collectors.filter((waiting) => waiting !== collector);
          resolve(null);
        }, 25000);
        this.collectors.push(collector);
      });
      return job ? jsonResponse(job) : jsonResponse({ idle: true });
    }

    // The agent, with the answer.
    if (url.pathname === "/reply") {
      const reply = await request.json();
      const waiting = this.waiting.get(reply.id);
      if (!waiting) {
        // The browser gave up first. Saying so keeps the agent from thinking it
        // failed.
        return jsonResponse({ delivered: false, reason: "nobody was still waiting" });
      }
      this.waiting.delete(reply.id);
      clearTimeout(waiting.timer);
      const headers = new Headers(reply.headers || {});
      // The cloud decides caching and framing for its own origin; whatever the
      // local server said about them does not apply here.
      headers.delete("transfer-encoding");
      headers.delete("content-encoding");
      headers.delete("content-length");
      waiting.resolve(new Response(reply.bodyBase64 ? base64ToBytes(reply.bodyBase64) : null, {
        status: reply.status || 200,
        headers
      }));
      return jsonResponse({ delivered: true });
    }

    return textResponse("Not found", { status: 404 });
  }
}

// Which machine a person's browser is talking to: the one that reported most
// recently. Designers have one; an id is carried so a second is a small change
// rather than a redesign.
// The oldest Book Studio that can answer a request from a browser at all.
// Anything before this collects nothing, so routing a designer to it means a
// wait and then a failure.
const MINIMUM_BRIDGE_VERSION = "2026.09.22.7";

function versionNumber(version) {
  const parts = String(version || "").split(".").map((part) => parseInt(part.replace(/[^0-9]/g, ""), 10) || 0);
  while (parts.length < 4) parts.push(0);
  return (parts[0] * 1000000) + (parts[1] * 10000) + (parts[2] * 100) + parts[3];
}

// The machine a browser is sent to. Most recent first, but only among the
// ones that can actually answer: a laptop that reported thirty seconds ago
// and cannot serve a page is worse than a desktop that reported a minute ago
// and can. A machine that is too old is still returned, separately, so the
// designer can be told which computer is holding them up and why.
// One entry per computer, the most recent. Running the setup command again
// gives a computer a new id, and the record under its old one lingers until it
// expires: the Vocate laptop was listed twice, counted as two computers ("1 of
// 3 ready" with two machines), and the stale copy still said "Ready" when the
// running agent had not yet checked Codex. Only one agent runs per computer,
// so the newest record for a computer is the one that is true.
function latestPerComputer(machines) {
  const sorted = [...machines].sort((left, right) => String(right.seenAt || "").localeCompare(String(left.seenAt || "")));
  const kept = new Set();
  return sorted.filter((machine) => {
    const computer = String(machine.runnerName || "").trim().toLowerCase() || "id:" + machine.id;
    if (kept.has(computer)) return false;
    kept.add(computer);
    return true;
  });
}

async function resolveMachineForUser(env, email) {
  const listed = await env.BOOK_STUDIO_KV.list({ prefix: "runner:status:" + email + ":" });
  const found = [];
  for (const key of listed.keys) {
    const record = await env.BOOK_STUDIO_KV.get(key.name, "json");
    if (record) found.push(record);
  }
  const machines = latestPerComputer(found);
  const capable = machines.filter((machine) => versionNumber(machine.version) >= versionNumber(MINIMUM_BRIDGE_VERSION));
  return { machine: capable[0] || null, tooOld: capable.length ? null : machines[0] || null };
}

function bridgeStub(env, owner, machineId) {
  return env.MACHINE_BRIDGE.get(env.MACHINE_BRIDGE.idFromName("machine:" + owner + ":" + machineId));
}

// The page a designer sees when no computer of theirs is running. It is served
// in place of Book Studio itself, because the alternative is a browser tab that
// hangs for a minute and then says nothing useful.
function noMachineHtml(email, message) {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Your computer is not running</title>
<style>
 body { margin:0; min-height:100vh; display:grid; place-items:center; padding:24px;
        font:16px/1.6 "Segoe UI",system-ui,sans-serif; color:#0d3553; background:#f9f9f9; }
 @media (prefers-color-scheme: dark) { body { color:#eef4f8; background:#0f1a22; } .card { background:#16242f !important; border-color:#2b3d4c !important; } }
 .card { max-width:520px; background:#fff; border:1px solid #dbdbdb; border-radius:12px; padding:28px; }
 h1 { margin:0 0 10px; font-size:1.3rem; }
 a { color:#0d6efd; }
 code { background:rgba(127,127,127,.15); padding:2px 5px; border-radius:4px; }
</style></head><body>
<div class="card">
  <h1>Book Studio is not answering on your computer</h1>
  <p>Signed in as <strong>${email}</strong>. Your books are written on your own PC, so that computer has to
  be switched on with Book Studio running before this page has anything to show.</p>
  <p>${message || ""}</p>
  <p>Open the minimised <code>Book Studio</code> PowerShell window on that computer, or set it up again from
  <a href="/cloud/connect">Your computer</a>.</p>
  <p><a href="/cloud/">Your books</a></p>
</div>
</body></html>`;
}

// Everything on the studio hostname belongs to the designer's own machine, so
// the paths the local Book Studio uses -- /api/jobs, /app.js, /version.json --
// arrive here exactly as that app expects them. Keeping it on its own hostname
// is what makes that possible without rewriting the app's own URLs.
async function forwardToMachine(request, env, url) {
  const user = await requireUser(request, env);
  if (user.response) {
    // A page gets the sign-in screen; anything else gets the refusal, because
    // only a script can read one.
    return request.method === "GET" && (request.headers.get("accept") || "").includes("text/html")
      ? new Response(null, { status: 302, headers: { location: "/cloud/login?next=" + encodeURIComponent(url.pathname) } })
      : user.response;
  }
  const { machine, tooOld } = await resolveMachineForUser(env, user.email);
  if (!machine && tooOld) {
    // The computer is there; it is running a Book Studio from before this
    // worked. Saying which one, and that it mends itself, is the difference
    // between a minute of nothing and a sentence a designer can act on.
    const message = "The Book Studio on " + (tooOld.runnerName || "your computer") + " is older than this page needs" +
      (tooOld.version ? " (" + tooOld.version + ")" : "") + ". It updates itself within the hour. To have it now, run the setup command on that computer once more.";
    return (request.headers.get("accept") || "").includes("text/html")
      ? new Response(noMachineHtml(user.email, message), { status: 503, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } })
      : jsonResponse({ error: message }, { status: 503 });
  }
  if (!machine) {
    return (request.headers.get("accept") || "").includes("text/html")
      ? new Response(noMachineHtml(user.email), { status: 503, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } })
      : jsonResponse({ error: "No computer of yours is running Book Studio." }, { status: 503 });
  }

  const body = request.method === "GET" || request.method === "HEAD"
    ? ""
    : bytesToBase64(new Uint8Array(await request.arrayBuffer()));
  const headers = {};
  for (const [name, value] of request.headers) {
    // Cookies are this site's, not the local server's, and hop-by-hop headers
    // mean nothing on the other side of the bridge.
    if (["cookie", "host", "connection", "content-length", "accept-encoding"].includes(name.toLowerCase())) continue;
    headers[name] = value;
  }

  const stub = bridgeStub(env, machine.owner || user.email, machine.id || "legacy");
  const response = await stub.fetch("https://bridge/request", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      method: request.method,
      path: url.pathname + url.search,
      headers,
      bodyBase64: body
    })
  });
  return response;
}

export default {
  async fetch(request, env) {
    return withSecurityHeaders(await handleRequest(request, env));
  }
};

async function handleRequest(request, env) {
  {
    const url = new URL(request.url);
    let pathname = url.pathname.replace(/\/+$/, "") || "/";

    // A change asked for from another site is refused. SameSite cookies stop a
    // stranger's site, but every other app on vocate.app counts as the same
    // site, so the Origin is checked as well. Agents send no Origin.
    if (!["GET", "HEAD", "OPTIONS"].includes(request.method)) {
      const origin = request.headers.get("origin");
      if (origin && new URL(origin).host !== url.host) {
        return textResponse("Changes must come from this site.", { status: 403 });
      }
    }
    // What a cloud page must put in front of its own links and API calls, so
    // the same page works under /cloud and, for an agent, at the root.
    let cloudPrefix = "";

    try {
      // One hostname for the cloud, one for the designer's own machine. The
      // local Book Studio asks for /api/jobs, /app.js and /version.json by
      // those exact names, and so does the cloud, so they cannot share a
      // hostname without one of them being rewritten. They do share the
      // sign-in cookie, which is set for the whole domain.
      // One site, two halves. Book Studio is at the root; everything the
      // cloud owns is under /cloud, which the local app never asks for. The
      // agent routes are shared by both, because an agent talks to whichever
      // address it was given.
      const studioHostnames = String(env.STUDIO_HOSTNAMES || "ebookstudio.vocate.app").split(",").map((name) => name.trim());
      const onStudio = studioHostnames.includes(url.hostname);
      const agentRoute = pathname.startsWith("/api/runner") || pathname.startsWith("/api/bridge") || pathname === "/setup.ps1" || pathname === "/api/health";
      if (onStudio && !agentRoute) {
        if (pathname === "/cloud" || pathname.startsWith("/cloud/")) {
          // Handled below as an ordinary cloud route, with the prefix off.
          pathname = pathname.slice("/cloud".length) || "/";
          cloudPrefix = "/cloud";
        } else {
          return await forwardToMachine(request, env, url);
        }
      }

      // The old address keeps working for agents and for anyone with a link,
      // but a person is moved to the one site rather than left on a second
      // copy of it.
      if (!onStudio && !agentRoute && request.method === "GET") {
        const studioName = studioHostnames[0];
        // A path already under /cloud keeps it; adding another produced
        // /cloud/cloud/login, which is nothing.
        const moved = pathname === "/" || pathname === "/index.html"
          ? "/cloud/"
          : (pathname.startsWith("/cloud") ? pathname : "/cloud" + pathname);
        return new Response(null, { status: 302, headers: { location: "https://" + studioName + moved + url.search } });
      }

      // A page asked for while signed out goes to the sign-in screen. Only the
      // API answers 401, because only the API has a caller that can read one.
      if (request.method === "GET" && (pathname === "/connect" || pathname === "/" || pathname === "/index.html")) {
        if (env.REQUIRE_ACCESS === "true" && !(await accessIdentity(request, env))) {
          return new Response(null, { status: 302, headers: { location: cloudPrefix + "/login?next=" + encodeURIComponent(cloudPrefix + pathname) } });
        }
      }

      if (request.method === "GET" && pathname === "/connect") {
        return new Response(withCloudPrefix(CONNECT_HTML, cloudPrefix), { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
      }

      if (request.method === "GET" && (pathname === "/" || pathname === "/index.html")) {
        return new Response(withCloudPrefix(APP_HTML, cloudPrefix), {
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

      if (request.method === "GET" && (pathname === "/guide" || pathname === "/signup")) {
        const pageHtml = pathname === "/guide" ? GUIDE_HTML : SIGNUP_HTML;
        return new Response(withCloudPrefix(pageHtml, cloudPrefix), { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
      }

      if (request.method === "GET" && pathname === "/login") {
        return new Response(withCloudPrefix(LOGIN_HTML, cloudPrefix), { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
      }

      // Signing in is the one route that cannot require being signed in.
      if (request.method === "POST" && pathname === "/api/login") {
        const payload = await request.json().catch(() => ({}));
        const email = normalizeEmail(payload.email);
        const password = String(payload.password || "");
        if (!email || !password) return textResponse("Enter your email and password.", { status: 400 });
        // Per address and per network, because a lockout on addresses alone
        // does nothing against one guess tried across a hundred of them.
        const network = request.headers.get("cf-connecting-ip") || "unknown";
        if ((await loginFailures(env, "ip:" + network)) >= MAX_LOGIN_FAILURES * 4) {
          return textResponse("Too many sign-in attempts from this network. Wait fifteen minutes.", { status: 429 });
        }
        if ((await loginFailures(env, email)) >= MAX_LOGIN_FAILURES) {
          return textResponse("Too many attempts. Wait fifteen minutes, or ask an administrator for a new password.", { status: 429 });
        }
        const user = await readUser(env, email);
        // One message for an unknown address and for a wrong password, so this
        // page cannot be used to find out who has an account.
        if (!user || user.disabled || !(await passwordMatches(user, password))) {
          await recordLoginFailure(env, email);
          await recordLoginFailure(env, "ip:" + network);
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

      // Asking for an account. Open to anyone, because a person who has no
      // account has nothing to sign in with -- but it creates nothing. An
      // address on the allowed domain proves only that someone typed it, not
      // that it is theirs, so a request waits for an administrator who knows
      // their people. The reply is the same whatever happened, so this form
      // cannot be used to find out who already has an account.
      if (request.method === "POST" && pathname === "/api/signup") {
        const payload = await request.json().catch(() => ({}));
        const email = normalizeEmail(payload.email);
        const name = String(payload.name || "").trim().slice(0, 120);
        const network = request.headers.get("cf-connecting-ip") || "unknown";
        const allowedDomain = String(env.SIGNUP_DOMAIN || "vocate.org").toLowerCase();
        if (!isPlainEmail(email) || !email.endsWith("@" + allowedDomain)) {
          return textResponse("Book Studio accounts are for @" + allowedDomain + " addresses. Use your work address.", { status: 400 });
        }
        if (!name) return textResponse("Tell us your name, so the administrator knows who is asking.", { status: 400 });
        if ((await loginFailures(env, "signup:" + network)) >= 10) {
          return textResponse("Too many requests from this network. Try again later.", { status: 429 });
        }
        await recordLoginFailure(env, "signup:" + network);
        const existing = await readUser(env, email);
        if (!existing) {
          await env.BOOK_STUDIO_KV.put("signup:" + email, JSON.stringify({
            email, name, requestedAt: nowIso(), note: String(payload.note || "").slice(0, 500)
          }), { expirationTtl: 60 * 60 * 24 * 30 });
        }
        return jsonResponse({
          received: true,
          message: "Thanks. An administrator will review your request and give you a password in person or over chat. Nothing is emailed."
        });
      }

      if (request.method === "GET" && pathname === "/api/signups") {
        const user = await requireUser(request, env);
        if (user.response) return user.response;
        if (!isAdmin(env, user.email)) return textResponse("Only an administrator can see account requests.", { status: 403 });
        const listed = await env.BOOK_STUDIO_KV.list({ prefix: "signup:" });
        const requests = [];
        for (const key of listed.keys) {
          const record = await env.BOOK_STUDIO_KV.get(key.name, "json");
          if (record && record.email) requests.push(record);
        }
        requests.sort((left, right) => String(left.requestedAt).localeCompare(String(right.requestedAt)));
        return jsonResponse({ requests });
      }

      // Approving issues a password exactly as adding someone by hand does:
      // generated here, shown once, changed at the first sign-in.
      if (request.method === "POST" && (pathname === "/api/signups/approve" || pathname === "/api/signups/decline")) {
        const user = await requireUser(request, env);
        if (user.response) return user.response;
        if (!isAdmin(env, user.email)) return textResponse("Only an administrator can decide account requests.", { status: 403 });
        const payload = await request.json().catch(() => ({}));
        const email = normalizeEmail(payload.email);
        const pending = await env.BOOK_STUDIO_KV.get("signup:" + email, "json");
        if (!pending) return textResponse("There is no request from that address.", { status: 404 });
        await env.BOOK_STUDIO_KV.delete("signup:" + email);
        if (pathname === "/api/signups/decline") return jsonResponse({ declined: email });
        const record = (await readUser(env, email)) || { email, createdAt: nowIso(), createdBy: user.email };
        record.name = pending.name || record.name || "";
        record.disabled = false;
        record.mustChangePassword = true;
        const password = generatePassword();
        await setUserPassword(env, record, password);
        return jsonResponse({ user: publicUser(env, record), password });
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
        if (!isPlainEmail(email)) return textResponse("Enter the person's email address, such as name@vocate.org.", { status: 400 });
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
          // Which Book Studio is on that computer, and whether it can fetch the
          // next one by itself. A machine that has stopped updating is a
          // machine that will fail in a way nobody can explain later.
          version: String(payload.version || "").slice(0, 40),
          updates: payload.updates || null,
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
        const computers = latestPerComputer(machines);
        machines.length = 0;
        machines.push(...computers);
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

      // What a computer can ask about itself, using the token it already has.
      // The setup command uses this to tell a designer their machine arrived,
      // instead of leaving them to refresh a web page and hope.
      // The agent, waiting for a designer to click something. It waits inside
      // the request rather than polling in a loop, so a click is not held up
      // by a polling interval.
      if (request.method === "GET" && pathname === "/api/bridge/next") {
        const auth = await requireRunner(request, env);
        if (auth.response) return auth.response;
        const stub = bridgeStub(env, auth.runner.owner || "shared", auth.runner.id || "legacy");
        return await stub.fetch("https://bridge/next");
      }

      if (request.method === "POST" && pathname === "/api/bridge/reply") {
        const auth = await requireRunner(request, env);
        if (auth.response) return auth.response;
        const stub = bridgeStub(env, auth.runner.owner || "shared", auth.runner.id || "legacy");
        return await stub.fetch("https://bridge/reply", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: await request.text()
        });
      }

      if (request.method === "GET" && pathname === "/api/runner/self") {
        const auth = await requireRunner(request, env);
        if (auth.response) return auth.response;
        const key = auth.runner.id
          ? "runner:status:" + (auth.runner.owner || "shared") + ":" + auth.runner.id
          : "runner:status:" + (auth.runner.owner || "shared");
        const record = await env.BOOK_STUDIO_KV.get(key, "json");
        return jsonResponse(record ? { reported: true, ...record } : { reported: false });
      }

      if (request.method === "GET" && pathname === "/api/runner/jobs") {
        const auth = await requireRunner(request, env);
        if (auth.response) return auth.response;
        const jobs = await listJobs(env);
        return jsonResponse({ jobs: jobs.filter((job) => job.status === "Queued" && runnerMayTouch(auth.runner, job)) });
      }

      // Sharing a book made in Book Studio with everyone at Vocate. The book
      // lives on the designer's computer; what is shared is a read-only copy
      // of its finished files, listed in Everyone's books under their name and
      // downloadable by anyone signed in. Only that computer's owner can share,
      // update or withdraw it, using the credential the computer already has.
      if (pathname === "/api/runner/shares" && request.method === "POST") {
        const auth = await requireRunner(request, env);
        if (auth.response) return auth.response;
        if (!auth.runner.owner) return textResponse("Connect this computer to your own account before sharing books.", { status: 403 });
        const payload = await request.json().catch(() => ({}));
        const localId = String(payload.localId || "").trim();
        if (!/^[A-Za-z0-9_-]{1,64}$/.test(localId)) return textResponse("A book id is required.", { status: 400 });
        const id = await sharedBookId(auth.runner.owner, localId);
        const existing = await readJob(env, id);
        if (existing && existing.owner !== auth.runner.owner) return textResponse("This book belongs to another designer.", { status: 403 });
        // Sharing again replaces the copy: the old files go, so nobody
        // downloads last week's version beside this week's.
        for (const artifact of (existing && existing.artifacts) || []) {
          if (artifact.key) await env.BOOK_STUDIO_FILES.delete(artifact.key);
        }
        const job = {
          id,
          owner: auth.runner.owner,
          title: String(payload.title || "Untitled Book").slice(0, 200),
          courseCode: String(payload.courseCode || "").slice(0, 40),
          status: "Shared",
          createdAt: (existing && existing.createdAt) || nowIso(),
          sharedAt: nowIso(),
          shared: {
            localId,
            stage: String(payload.workflowStatus || payload.stage || "").slice(0, 120),
            from: String(payload.runnerName || "").slice(0, 120)
          },
          uploadedFiles: [],
          artifacts: [],
          log: []
        };
        appendJobLog(job, "Shared from Book Studio" + (job.shared.stage ? ": " + job.shared.stage : "") + ".");
        await writeJob(env, job);
        if (!existing) {
          const ids = await readIndex(env);
          await writeIndex(env, [id, ...ids.filter((entry) => entry !== id)]);
        }
        return jsonResponse(publicJob(job));
      }

      const unshareLocalId = pathname.startsWith("/api/runner/shares/") && request.method === "DELETE"
        ? decodeURIComponent(pathname.slice("/api/runner/shares/".length)) : "";
      if (unshareLocalId) {
        const auth = await requireRunner(request, env);
        if (auth.response) return auth.response;
        if (!auth.runner.owner) return textResponse("Connect this computer to your own account first.", { status: 403 });
        const id = await sharedBookId(auth.runner.owner, unshareLocalId);
        const job = await readJob(env, id);
        if (!job) return jsonResponse({ removed: false });
        if (job.owner !== auth.runner.owner) return textResponse("This book belongs to another designer.", { status: 403 });
        for (const artifact of job.artifacts || []) {
          if (artifact.key) await env.BOOK_STUDIO_FILES.delete(artifact.key);
        }
        await env.BOOK_STUDIO_KV.delete("job:" + id);
        await writeIndex(env, (await readIndex(env)).filter((entry) => entry !== id));
        return jsonResponse({ removed: true });
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

      // A single book and its files. These were answered to anyone who had
      // the id, signed in or not; an audit downloaded a finished 6 MB Word
      // book with no session at all. Everyone signed in may read every book --
      // the books list already shows everyone's -- but nobody else may.
      const artifactJobId = getRouteId(pathname, "/artifact");
      if (request.method === "GET" && artifactJobId) {
        const reader = await requireUser(request, env);
        if (reader.response) return reader.response;
        const job = await readJob(env, artifactJobId);
        if (!job) return textResponse("Job not found", { status: 404 });
        const name = url.searchParams.get("name") || "";
        const found = await getArtifact(env, job, name);
        if (!found) return textResponse("Artifact not found", { status: 404 });
        return new Response(found.object.body, {
          headers: {
            "content-type": found.artifact.contentType || "application/octet-stream",
            // The name came from the machine that uploaded it; a quote in it
            // would end the header value early.
            "content-disposition": "attachment; filename=\"" + String(found.artifact.fileName || "artifact.bin").replace(/["\\\r\n]/g, "_") + "\"",
            "cache-control": "no-store"
          }
        });
      }

      const jobId = getRouteId(pathname);
      if (request.method === "GET" && jobId) {
        const reader = await requireUser(request, env);
        if (reader.response) return reader.response;
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
