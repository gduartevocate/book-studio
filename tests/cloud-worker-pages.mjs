// The worker serves its pages from template literals inside itself, so
// `node --check` on the worker proves only that the literal is closed. The
// script a browser actually receives has had one level of escaping eaten by
// that literal: a "\n" written once became a real newline inside a quoted
// string, the connect page's whole script failed to parse, and the page sat
// on "Checking..." with every button dead. Nothing in the repository noticed,
// because the HTML was served, contained every expected word, and was wrong.
//
// So the pages are fetched from the worker itself, exactly as a browser gets
// them, and parsed.
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { webcrypto } from "node:crypto";
import { pathToFileURL } from "node:url";

if (!globalThis.crypto) globalThis.crypto = webcrypto;

const workerPath = process.argv[2];
const scratch = mkdtempSync(join(tmpdir(), "worker-pages-"));
const copy = join(scratch, "worker.mjs");
writeFileSync(copy, readFileSync(workerPath));
const worker = (await import(pathToFileURL(copy).href)).default;

let checks = 0;
const check = (condition, message) => { if (!condition) throw new Error(message); checks++; };

const store = new Map();
const kv = {
  async get(key, type) {
    const value = store.get(key);
    if (value === undefined) return null;
    return type === "json" ? JSON.parse(value) : value;
  },
  async put(key, value) { store.set(key, String(value)); },
  async delete(key) { store.delete(key); },
  async list() { return { keys: [], list_complete: true }; }
};
const env = {
  BOOK_STUDIO_KV: kv,
  BOOK_STUDIO_FILES: { async get() { return null; } },
  ACCESS_TEAM_DOMAIN: "vocate.cloudflareaccess.com",
  ACCESS_AUD: "aud-for-tests",
  // Sign-in off, so the pages are served rather than redirected: this suite is
  // about what the page contains, not about who may see it.
  REQUIRE_ACCESS: "false",
  ADMIN_EMAILS: "boss@vocate.org",
  STUDIO_HOSTNAMES: "ebookstudio.vocate.app"
};

async function page(path) {
  const response = await worker.fetch(new Request("https://ebookstudio.vocate.app" + path, { headers: { accept: "text/html" } }), env);
  check(response.status === 200, "The worker must serve " + path + ", got " + response.status);
  return await response.text();
}

// Served the way the one site serves them: Book Studio at the root, the cloud
// under /cloud. The prefix has to be resolved by the time a browser sees them,
// or every link on them points at a page that is not there.
const pages = {
  "/cloud/connect": await page("/cloud/connect"),
  "/cloud/admin": await page("/cloud/admin"),
  "/cloud/login": await page("/cloud/login"),
  "/cloud/": await page("/cloud/")
};
for (const [path, html] of Object.entries(pages)) {
  check(!html.includes("__CLOUD__"), path + " still carries the unresolved link marker, so its links go nowhere.");
  check(html.includes("/cloud/"), path + " has no link into the cloud half of the site.");
}

for (const [path, html] of Object.entries(pages)) {
  const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((match) => match[1]);
  check(scripts.length > 0, path + " has no inline script; the scan pattern is wrong.");

  scripts.forEach((script, index) => {
    // Parsed exactly as delivered. Anything the template literal already
    // resolved stays resolved, which is the whole point.
    const file = join(scratch, path.replace(/\W+/g, "_") + index + ".mjs");
    writeFileSync(file, script);
    try {
      execFileSync(process.execPath, ["--check", file], { stdio: "pipe" });
      checks++;
    } catch (error) {
      const detail = ((error.stderr || Buffer.from("")).toString() + " " + (error.message || ""))
        .split("\n").map((line) => line.trim()).filter(Boolean).slice(0, 3).join(" | ");
      throw new Error("The script " + path + " sends to the browser does not parse: " + detail);
    }

    // A script that parses can still address elements that are not there,
    // which fails just as silently.
    // Both ways a page addresses its own elements. The scan used to know only
    // el("x"); the cloud page uses document.querySelector("#x"), so retiring a
    // panel left its script reaching for elements that no longer existed, and
    // one of those stops the whole script before anything runs.
    const ids = new Set([...html.matchAll(/id="([A-Za-z0-9_-]+)"/g)].map((match) => match[1]));
    const addressed = [
      ...[...script.matchAll(/\bel\("([A-Za-z0-9_-]+)"\)/g)].map((match) => match[1]),
      ...[...script.matchAll(/querySelector\("#([A-Za-z0-9_-]+)"\)/g)].map((match) => match[1])
    ];
    check(addressed.length > 0, path + " addresses no elements at all; the scan pattern is wrong.");
    for (const used of addressed) {
      check(ids.has(used), path + " reaches for #" + used + ", which the page does not have.");
    }

    // And a page whose script never reaches the server is a page that shows
    // its placeholder text for ever.
    if (path !== "/cloud/login") {
      check(/fetch\(|api\(/.test(script), path + " never calls the API, so nothing on it can update.");
    }
  });
}

// What a designer copies has to be one command they can paste and run: the
// agent, the token, a Windows path, and nothing to assemble by hand. It used to
// be two lines and an environment variable, which is a developer's habit, not
// something to ask a designer to get right on a locked-down PC.
const connect = pages["/cloud/connect"];
const command = (connect.match(/<pre id="cmd">([\s\S]*?)<\/pre>/) || [])[1] || "";
check(!command.includes("\n"), "The command must be one line; a second line is a second thing to get wrong.");
check(!/\$env:/.test(command), "The command must not ask a designer to set an environment variable.");
const script = (connect.match(/<script>([\s\S]*?)<\/script>/) || [])[1];
const rewritten = (script.match(/el\("cmd"\)\.textContent = ([^;]+);/) || [])[1] || "";
check(/setup\.ps1\?token=/.test(rewritten), "After minting, the command must fetch the setup script with that token.");
check(/created\.token/.test(rewritten), "After minting, the command must carry the token that was just issued.");
check(/iex/.test(rewritten), "After minting, the command must run what it fetches.");
check(!/\\n/.test(rewritten), "After minting, the command must still be a single line.");

// A designer told to "paste this" and nothing else has to guess where. The page
// has to name the window, and name the two things the script cannot install for
// them, or they find out by failing.
check(/PowerShell/.test(connect), "The connect page must say which window to paste the command into.");
check(/git-scm\.com/.test(connect), "The connect page must say where to get Git.");
check(/codex login/.test(connect), "The connect page must say Codex has to be signed in.");
check(/sign in to Windows/.test(connect), "The connect page must say the computer reconnects by itself afterwards.");
check(/Copy/.test(connect), "The connect page must offer to copy the command rather than make a designer select it.");

// The connect page is where a designer finds out whether their machine is
// there, so the fields it reads must be the ones the worker sends. One line per
// computer: a laptop and a desktop used to share a single record and overwrite
// each other, so a laptop that had never connected could show its owner a
// "Ready" belonging to a machine in another building.
check(script.includes("status.machines"), "The connect page must show every computer, not one of them.");
check(script.includes("status.detail"), "A person with no computer running must be told why.");
for (const field of ["runnerName", "seenAt", "codex"]) {
  check(script.includes("machine." + field), "Each computer listed must show its " + field + ".");
}
check(/last heard from/.test(script), "Each computer must say when it was last heard from; that is what tells a designer theirs is not running.");

// The front page is where a designer lands after signing in. It has to say
// whose books these are, offer the shared view, and let them leave.
const app = pages["/cloud/"];
check(/My books/.test(app), "The front page must show a designer their own books.");
check(/Everyone/.test(app), "The front page must offer everyone's books.");
check(/id="who"/.test(app), "The front page must say who is signed in.");
check(/id="signout"/.test(app), "The front page must offer a way to sign out.");
check(/href="\/cloud\/connect"/.test(app), "The front page must link to connecting a computer.");
const appScript = (app.match(/<script>([\s\S]*?)<\/script>/) || [])[1] || "";
check(/scope=/.test(appScript), "The front page must ask the server for one scope or the other.");
check(/job\.owner/.test(appScript), "The shared view must show whose book each one is.");

// Every page must say where the others are. The connect page had no way back
// to the books at all, so signing in and connecting a computer left a designer
// at a dead end with nothing to click.
check(/href="\/cloud\/"/.test(connect), "The connect page must link back to the books.");
check(/id="signout"/.test(connect), "The connect page must offer a way to sign out.");

// Books are not made here. This page offered an uploader with none of the steps
// a designer needs -- no curriculum-draft analysis, no outcomes review, no
// production settings, no format review, no quality findings -- and a book
// started here failed twenty minutes later for a reason Book Studio would have
// caught before it began.
check(!/id="bookForm"/.test(app), "The cloud page must not offer a way to start a book; Book Studio is where that happens.");
check(!/readFileAsBase64/.test(appScript), "Nothing should be uploadable from the cloud page.");
check(/href="\/"/.test(app), "The cloud page must send a designer to Book Studio, which is this site's own root.");
// One name for it everywhere a designer reads it: two names for the same place
// is how somebody ends up bookmarking the one that is later retired.
check(!/studio\.vocate\.app/.test(app), "Nothing may point at a second address for Book Studio.");
check(!/studio\.vocate\.app/.test(connect), "The connect page must not point at a second address either.");
check(/Book Studio/.test(app), "And say so in words.");

// A computer that has stopped updating itself must say so on the page where
// someone would look, not only in the record behind it.
check(/machine\.version/.test(script), "The connect page must show which Book Studio each computer runs.");
check(/not updating itself/.test(script), "The connect page must say when a computer has stopped updating itself.");
check(/keeps itself up to date/.test(script), "And say when it has not.");

// Found by the security audit of 2026-09-23: values from other machines and
// other people were written into this page as markup. A computer names itself
// and an administrator types an address; either could carry a script.
const adminPage = pages["/cloud/admin"];
const adminScript = (adminPage.match(/<script>([\s\S]*?)<\/script>/) || [])[1] || "";
const markupWrites = [...(script + " " + adminScript).matchAll(/innerHTML\s*=([\s\S]*?);\s*$/gm)].map((match) => match[1]);
check(markupWrites.length > 3, "The markup scan found too few writes; the pattern is wrong.");
for (const write of markupWrites) {
  const risky = [...write.matchAll(/\+\s*([A-Za-z_][\w.]*(?:\.(?:message|email|detail|token|password|version|reason|runnerName|label))[\w.]*)/g)].map((m) => m[1]);
  for (const value of risky) check(false, "The connect page writes " + value + " as markup without esc().");
}
check(/function esc\(/.test(script), "The connect page must have an escaping helper.");
check(/function esc\(/.test(adminScript), "The admin page must have an escaping helper.");

// Account approvals have a page of their own, and every way in points there.
// They used to be section 5 at the bottom of Your computer, where the one
// administrator could not find them.
for (const id of ['id="requests"', 'id="roster"', 'id="newEmail"', 'id="notAdmin"']) {
  check(adminPage.includes(id), "The admin page must have " + id + ".");
}
check(adminScript.includes('"/cloud/api/signups/approve"') && adminScript.includes('"/cloud/api/signups/decline"'), "The admin page must approve and decline requests.");
check(!connect.includes('id="roster"') && connect.includes('href="/cloud/admin"') && /request waiting/.test(script), "Your computer must link to the admin page, with the number waiting, instead of holding it.");
const booksPage2 = pages["/cloud/"];
check(booksPage2.includes('id="peopleLink" href="/cloud/admin" hidden') && booksPage2.includes("waiting for your approval"), "The books page must show an administrator the way to People and who is waiting.");
const studioClient = readFileSync(new URL("../book-studio/app.js", import.meta.url), "utf8");
check(studioClient.includes('fetch("/cloud/api/signups"') && studioClient.includes('review.href = "/cloud/admin"'), "Book Studio must tell an administrator when someone is waiting.");
check(!script.includes('"""'), "The escaping helper must survive the template literal it lives in.");

// Chapter links. A manuscript link became <a href> with whatever it said, so
// [see this](javascript:...) ran script when clicked, on a site that shares an
// origin with the cloud's own account pages.
const client = readFileSync(new URL("../book-studio/app.js", import.meta.url), "utf8");
const helpers = client.slice(client.indexOf("function escapeHtml"), client.indexOf("function markdownTableToHtml"));
const linkApi = new Function(helpers + "; return { inlineMarkdownToHtml, isSafeLinkTarget };")();
for (const bad of ["javascript:alert(1)", " JavaScript:alert(1)", "data:text/html,x", "vbscript:x", "//elsewhere.example"]) {
  check(!linkApi.isSafeLinkTarget(bad), "A chapter link to " + bad + " must not become a link.");
  check(!/<a /.test(linkApi.inlineMarkdownToHtml("[x](" + bad + ")")), "A chapter link to " + bad + " must render as plain text.");
}
for (const good of ["https://example.org/a", "http://example.org", "mailto:a@b.co", "#chapter-1-note-1", "/relative/path"]) {
  check(linkApi.isSafeLinkTarget(good), "A chapter link to " + good + " must still work.");
}

// The guide for instructional designers. A guide that names a button
// slightly differently from the button sends people looking for something that
// is not there, so every control it names in bold must exist, word for word, in
// Book Studio itself.
const guide = await page("/cloud/guide");
const signupPage = await page("/cloud/signup");
const studioText = ["app.js", "production.js", "setup-change.js", "outcome-analysis.js", "index.html"]
  .map((file) => readFileSync(new URL("../book-studio/" + file, import.meta.url), "utf8")).join("\n");
const decode = (text) => text.replace(/&amp;/g, "&");
const named = [...guide.matchAll(/<strong>([^<]{3,60})<\/strong>/g)].map((m) => decode(m[1]))
  .filter((label) => /^[A-Z]/.test(label) && !/[.?:]$/.test(label) && label.split(" ").length <= 8);
// Checked from both ends. Each control a designer is sent to must be named in
// the guide exactly, and must exist in Book Studio: a label that only matched
// a pattern let a renamed button slip out of the check unnoticed.
const requiredControls = ["Change setup", "Read readings from the document again", "Remove entries with no URL", "Fix QA with Codex",
  "Delete book", "Approve format & generate book", "Save changes & update preview", "Sources and image setting"];
for (const label of requiredControls) {
  check(named.includes(label), "The guide must name the control '" + label + "' exactly as Book Studio shows it.");
}
const controls = named.filter((label) => requiredControls.includes(label));
check(controls.length >= 6, "The guide should name the controls a designer uses; found " + controls.length);
for (const label of controls) {
  check(studioText.includes(label), "The guide names '" + label + "', which Book Studio does not show.");
}
for (const option of ["Uploaded teaching documents only", "Required readings from blueprint and links below", "Discover additional sources (advanced)", "Also research additional sources beyond the required readings"]) {
  check(guide.includes(option), "The guide must use the source option wording Book Studio shows: " + option);
  check(studioText.includes(option), "Book Studio no longer shows '" + option + "', so the guide is out of date.");
}
for (const section of ['id="new"', 'id="steps"', 'id="sources"', 'id="change"', 'id="fix"', 'id="safe"']) {
  check(guide.includes(section), "The guide is missing its section " + section + ".");
}
check(/href="\/cloud\/signup"/.test(guide) && /href="\/cloud\/connect"/.test(guide), "The guide must link to asking for an account and to connecting a computer.");
check(/<html lang="en">/.test(guide) && /class="skip"/.test(guide), "The guide must declare its language and let a keyboard user skip to it.");

// The request form: labelled fields, an announced result, and a way back.
for (const field of ['for="name"', 'for="email"', 'for="note"']) check(signupPage.includes(field), "The request form must label " + field + ".");
check(/role="status"[^>]*aria-live="polite"|aria-live="polite"[^>]*role="status"/.test(signupPage), "The request form must announce its result.");
check(!/var status\s*=/.test(signupPage), "A top-level 'status' is window.status, a string; the form must not use it.");
check(signupPage.includes("/cloud/login") && signupPage.includes("/cloud/guide"), "The request form must link to signing in and to the guide.");

// And the sign-in page tells a new person where to go.
const loginPage = pages["/cloud/login"];
check(loginPage.includes("/cloud/signup") && loginPage.includes("/cloud/guide"), "The sign-in page must point a new person at the request form and the guide.");
check(/id="note"[^>]*aria-live="polite"/.test(loginPage), "The sign-in page must announce why a sign-in failed.");

// The page that stopped updating. Book Studio's refresh loop swallows its own
// failures, so a designer signed out mid-book watched "last run 8:45" at 8:55
// while the book was working the whole time. A signed-out refresh must say so,
// once, and a Book Studio opened on the PC itself has nothing to say.
const takeFunction = (name) => {
  const start = client.indexOf((name === "api" ? "async function " : "function ") + name + "(");
  // The body opens after the parameter list; "options = {}" is not it.
  let depth = 0, index = client.indexOf(") {", start) + 2;
  for (let i = index; i < client.length; i++) {
    if (client[i] === "{") depth++;
    if (client[i] === "}") { depth--; if (depth === 0) return client.slice(start, i + 1); }
  }
  throw new Error("Could not find " + name);
};
const noticeSource = client.slice(client.indexOf("const connectionNotices"), client.indexOf("async function api("));
const makeNotices = (hostname, status) => {
  const added = [];
  const fakeElement = () => ({ attrs: {}, children: [], className: "", textContent: "", href: "",
    setAttribute(key, value) { this.attrs[key] = value; }, append(...items) { this.children.push(...items); } });
  const fakeDocument = { createElement: () => fakeElement(), body: { prepend: (element) => added.push(element) } };
  const fakeLocation = { hostname, pathname: "/", search: "" };
  const fakeFetch = async () => ({ ok: false, status, text: async () => "" });
  const run = new Function("document", "location", "fetch",
    noticeSource + takeFunction("reachedThroughTheCloud") + takeFunction("api") + "; return api;");
  return { api: run(fakeDocument, fakeLocation, fakeFetch), added };
};
const cloudSignedOut = makeNotices("ebookstudio.vocate.app", 401);
await cloudSignedOut.api("/api/jobs").catch(() => {});
await cloudSignedOut.api("/api/jobs").catch(() => {});
check(cloudSignedOut.added.length === 1, "A signed-out refresh must say so exactly once, got " + cloudSignedOut.added.length);
check(cloudSignedOut.added[0].attrs.role === "alert", "The notice must be announced.");
check(/\/cloud\/login\?next=/.test(cloudSignedOut.added[0].children[1].href), "The notice must lead back to signing in, to the same page.");
const machineGone = makeNotices("ebookstudio.vocate.app", 503);
await machineGone.api("/api/jobs").catch(() => {});
check(machineGone.added.length === 1 && /\/cloud\/connect/.test(machineGone.added[0].children[1].href), "A computer that stops answering must be named too.");
const onThePc = makeNotices("localhost", 401);
await onThePc.api("/api/jobs").catch(() => {});
check(onThePc.added.length === 0, "Book Studio opened on the PC itself has no sign-in to lose.");

// Download links on the books page. Stored as /api/jobs/..., which on the one
// site belongs to the viewer's own computer, so every download went there.
const booksPage = pages["/cloud/"] || await page("/cloud/");
check(booksPage.includes('indexOf("/api/") === 0 ? "/cloud" : ""'), "Download links on the books page must carry the /cloud prefix on the one site.");
check(/Shared " \+ formatDate\(job\.sharedAt/.test(booksPage), "A shared book must say when it was shared, not how many source files it has.");
check(booksPage.includes('"Stage: " + job.shared.stage'), "A shared book must show its stage, not the last file upload.");

console.log("PASS: " + checks + " page checks (delivered scripts parse, ids exist, connect command survives minting)");
