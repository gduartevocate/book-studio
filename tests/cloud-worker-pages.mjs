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
  ADMIN_EMAILS: "boss@vocate.org"
};

async function page(path) {
  const response = await worker.fetch(new Request("https://ebook.vocate.app" + path), env);
  check(response.status === 200, "The worker must serve " + path + ", got " + response.status);
  return await response.text();
}

const pages = {
  "/connect": await page("/connect"),
  "/login": await page("/login"),
  "/": await page("/")
};

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
    const ids = new Set([...html.matchAll(/id="([A-Za-z0-9_-]+)"/g)].map((match) => match[1]));
    for (const used of [...script.matchAll(/\bel\("([A-Za-z0-9_-]+)"\)/g)].map((match) => match[1])) {
      check(ids.has(used), path + ' uses el("' + used + '"), but the page has no element with that id.');
    }

    // And a page whose script never reaches the server is a page that shows
    // its placeholder text for ever.
    if (path !== "/login") {
      check(/fetch\(|api\(/.test(script), path + " never calls the API, so nothing on it can update.");
    }
  });
}

// What a designer copies has to be one command they can paste and run: the
// agent, the token, a Windows path, and nothing to assemble by hand. It used to
// be two lines and an environment variable, which is a developer's habit, not
// something to ask a designer to get right on a locked-down PC.
const connect = pages["/connect"];
const command = (connect.match(/<pre id="cmd">([\s\S]*?)<\/pre>/) || [])[1] || "";
check(/\.\\cloud-book-runner\.ps1/.test(command), "The connect page must show the agent being started, with a Windows path.");
check(/-Token/.test(command), "The connect page must show the token being passed to the agent.");
check(!command.includes("\n"), "The command must be one line; a second line is a second thing to get wrong.");
check(!/\$env:/.test(command), "The command must not ask a designer to set an environment variable.");
const script = (connect.match(/<script>([\s\S]*?)<\/script>/) || [])[1];
const rewritten = (script.match(/el\("cmd"\)\.textContent = ([^;]+);/) || [])[1] || "";
check(/\\\\cloud-book-runner/.test(rewritten), "After minting a token the command must still contain the backslash before the script name.");
check(/-Token/.test(rewritten) && /created\.token/.test(rewritten), "After minting, the command must carry the new token itself.");
check(!/\\n/.test(rewritten), "After minting, the command must still be a single line.");
// The page has to say how to stop doing this every morning, because a machine
// whose agent is not running reads as missing with nothing to explain it.
check(/-StartWithWindows/.test(connect), "The connect page must say how to make the agent start with Windows.");

// The connect page is where a designer finds out whether their machine is
// there, so the fields it reads must be the ones the worker sends.
for (const field of ["connected", "runnerName", "seenAt", "detail"]) {
  check(script.includes("status." + field), "The connect page no longer reads status." + field + ".");
}

console.log("PASS: " + checks + " page checks (delivered scripts parse, ids exist, connect command survives minting)");
