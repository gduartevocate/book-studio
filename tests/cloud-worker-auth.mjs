// Drives the deployed worker's code in-process, with a fake KV and R2, so the
// sign-in rules are exercised for real rather than inspected as text. Book
// Studio issues its own passwords because Cloudflare Access sends a one-time
// PIN by email and Microsoft Safe Links opens the link before the designer
// does; everything about that is only as good as the checks below.
import { webcrypto } from "node:crypto";
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

if (!globalThis.crypto) globalThis.crypto = webcrypto;

const workerPath = process.argv[2];
const scratch = mkdtempSync(join(tmpdir(), "worker-auth-"));
const copy = join(scratch, "worker.mjs");
writeFileSync(copy, readFileSync(workerPath));
const workerModule = await import(pathToFileURL(copy).href);
const worker = workerModule.default;

// A stand-in for the Durable Object namespace that runs the real class in
// process. The rendezvous logic is the part worth testing; Cloudflare's
// plumbing around it is not.
const bridges = new Map();
const MACHINE_BRIDGE = {
  idFromName: (name) => ({ name }),
  get: (id) => {
    if (!bridges.has(id.name)) bridges.set(id.name, new workerModule.MachineBridge({}));
    const instance = bridges.get(id.name);
    return { fetch: (url, init) => instance.fetch(new Request(url, init)) };
  }
};

// Node will happily run any iteration count; the Workers runtime refuses more
// than 100,000 and only says so when a password is checked, which is how a
// suite like this one passed while the first real sign-in failed. The count is
// read from the worker so the two cannot drift, and held to the platform cap.
const source = readFileSync(workerPath, "utf8");
const ITERATIONS = Number((source.match(/const PASSWORD_ITERATIONS = (\d+)/) || [])[1]);

let checks = 0;
const fail = (message) => { throw new Error(message); };
const check = (condition, message) => { if (!condition) fail(message); checks++; };

// A KV that behaves like the real one in the ways this code depends on:
// JSON reads, prefix listing, and values that expire.
function makeKv() {
  const store = new Map();
  const live = (key) => {
    const entry = store.get(key);
    if (!entry) return null;
    if (entry.expiresAt && entry.expiresAt <= Date.now()) { store.delete(key); return null; }
    return entry;
  };
  return {
    store,
    async get(key, type) {
      const entry = live(key);
      if (!entry) return null;
      return type === "json" ? JSON.parse(entry.value) : entry.value;
    },
    async put(key, value, options = {}) {
      store.set(key, { value: String(value), expiresAt: options.expirationTtl ? Date.now() + options.expirationTtl * 1000 : 0 });
    },
    async delete(key) { store.delete(key); },
    async list({ prefix = "" } = {}) {
      const keys = [...store.keys()].filter((key) => key.startsWith(prefix) && live(key)).map((name) => ({ name }));
      return { keys, list_complete: true };
    }
  };
}

const kv = makeKv();
const env = {
  BOOK_STUDIO_KV: kv,
  BOOK_STUDIO_FILES: { async get() { return null; }, async put() { return null; }, async delete() { return null; } },
  ACCESS_TEAM_DOMAIN: "vocate.cloudflareaccess.com",
  ACCESS_AUD: "aud-for-tests",
  REQUIRE_ACCESS: "true",
  ADMIN_EMAILS: "boss@vocate.org",
  STUDIO_HOSTNAMES: "ebookstudio.vocate.app",
  MACHINE_BRIDGE
};

const base = "https://ebookstudio.vocate.app";
async function call(method, path, { body, cookie, headers = {} } = {}) {
  const init = { method, headers: { ...headers } };
  if (body !== undefined) { init.body = JSON.stringify(body); init.headers["content-type"] = "application/json"; }
  if (cookie) init.headers.cookie = cookie;
  const response = await worker.fetch(new Request(base + (path.startsWith("/api/runner") || path.startsWith("/api/bridge") || path === "/api/health" ? path : "/cloud" + path), init), env);
  const text = await response.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* not every reply is JSON */ }
  return { status: response.status, text, json, headers: response.headers };
}

// The first account cannot be created through the app, by anyone, so it is
// seeded the way an administrator seeds it: straight into the store. Deriving
// the hash here rather than calling the worker also pins the hashing contract.
async function seedUser(email, password, extra = {}) {
  const salt = [...webcrypto.getRandomValues(new Uint8Array(16))].map((v) => v.toString(16).padStart(2, "0")).join("");
  const key = await webcrypto.subtle.importKey("raw", new TextEncoder().encode(password), { name: "PBKDF2" }, false, ["deriveBits"]);
  const bits = await webcrypto.subtle.deriveBits(
    { name: "PBKDF2", salt: new Uint8Array(salt.match(/../g).map((pair) => parseInt(pair, 16))), iterations: ITERATIONS, hash: "SHA-256" },
    key,
    256
  );
  const passwordHash = [...new Uint8Array(bits)].map((v) => v.toString(16).padStart(2, "0")).join("");
  const record = { email, salt, iterations: ITERATIONS, passwordHash, createdAt: new Date().toISOString(), ...extra };
  await kv.put("user:" + email, JSON.stringify(record));
  return record;
}

const cookieFrom = (result) => (result.headers.get("set-cookie") || "").split(";")[0];

// 1. A signed-out designer asking for a page is shown the sign-in screen, and
//    told where they were going, rather than a bare 401 they cannot act on.
const page = await call("GET", "/connect");
check(page.status === 302, "A signed-out request for /connect must redirect, got " + page.status);
check(page.headers.get("location") === "/cloud/login?next=%2Fcloud%2Fconnect", "The redirect must remember where the designer was going, within the one site; got " + page.headers.get("location"));
const loginPage = await call("GET", "/login");
check(loginPage.status === 200 && loginPage.text.includes("Sign in to Book Studio"), "The sign-in page must be served without a session.");
check(!/\bemail(ed)? (you )?a (code|link)\b/i.test(loginPage.text), "The sign-in page must not promise an emailed code; that is the flow Safe Links breaks.");

// 2. The API answers 401, because an API caller can read one.
const anonymous = await call("GET", "/api/jobs");
check(anonymous.status === 401, "An anonymous API request must be refused, got " + anonymous.status);

// 3. An unknown address and a wrong password must be indistinguishable, or the
//    sign-in page becomes a way to find out who has an account.
await seedUser("designer@vocate.org", "first-password-1234", { mustChangePassword: true });
const unknown = await call("POST", "/api/login", { body: { email: "nobody@vocate.org", password: "whatever-1234" } });
const wrong = await call("POST", "/api/login", { body: { email: "designer@vocate.org", password: "not-the-password" } });
check(unknown.status === 401 && wrong.status === 401, "Both a missing account and a wrong password must be 401.");
check(unknown.text === wrong.text, "A missing account and a wrong password must give the same message.");

// 4. A correct password starts a session, and the cookie must be one a script
//    cannot read and a cross-site form cannot send.
const signedIn = await call("POST", "/api/login", { body: { email: "designer@vocate.org", password: "first-password-1234" } });
check(signedIn.status === 200, "A correct password must sign in, got " + signedIn.status + " " + signedIn.text);
check(signedIn.json.mustChangePassword === true, "An issued password must be reported as one that has to be changed.");
const setCookie = signedIn.headers.get("set-cookie") || "";
check(/HttpOnly/i.test(setCookie), "The session cookie must be HttpOnly.");
check(/Secure/i.test(setCookie), "The session cookie must be Secure.");
check(/SameSite=Lax/i.test(setCookie), "The session cookie must be SameSite=Lax.");
check(!signedIn.text.includes("first-password-1234"), "The reply must not echo the password.");
const session = cookieFrom(signedIn);

// 5. The session is what the rest of the app reads identity from.
const mine = await call("GET", "/api/jobs", { cookie: session });
check(mine.status === 200 && mine.json.you === "designer@vocate.org", "A session must identify the person to the rest of the app.");
const connected = await call("GET", "/connect", { cookie: session });
check(connected.status === 200, "A signed-in designer must get the connect page, got " + connected.status);

// 6. The stored record must never hold the password itself.
const stored = JSON.parse(kv.store.get("user:designer@vocate.org").value);
check(!JSON.stringify(stored).includes("first-password-1234"), "The stored account must not contain the password.");
check(stored.passwordHash && stored.salt && stored.iterations === ITERATIONS, "The account must store a salted PBKDF2 hash and its iteration count.");
check(ITERATIONS > 0 && ITERATIONS <= 100000, "PBKDF2 iterations must stay within the 100,000 the Workers runtime allows, or every sign-in fails; got " + ITERATIONS);

// 7. Changing the password needs the current one, has a floor, and takes effect.
const shortOne = await call("POST", "/api/password", { cookie: session, body: { currentPassword: "first-password-1234", newPassword: "short" } });
check(shortOne.status === 400, "A password below the minimum must be refused.");
const wrongCurrent = await call("POST", "/api/password", { cookie: session, body: { currentPassword: "nope", newPassword: "a-much-longer-password" } });
check(wrongCurrent.status === 401, "Changing a password must require the current one.");
const changed = await call("POST", "/api/password", { cookie: session, body: { currentPassword: "first-password-1234", newPassword: "a-much-longer-password" } });
check(changed.status === 200, "The password change must succeed, got " + changed.text);
const oldPassword = await call("POST", "/api/login", { body: { email: "designer@vocate.org", password: "first-password-1234" } });
check(oldPassword.status === 401, "The replaced password must stop working.");
const newPassword = await call("POST", "/api/login", { body: { email: "designer@vocate.org", password: "a-much-longer-password" } });
check(newPassword.status === 200 && newPassword.json.mustChangePassword === false, "The chosen password must work and clear the change flag.");

// 8. Signing out must end the session, not just drop the cookie in one browser.
const signedOut = await call("POST", "/api/logout", { cookie: session });
check(signedOut.status === 200, "Signing out must succeed.");
check(/Max-Age=0/i.test(signedOut.headers.get("set-cookie") || ""), "Signing out must clear the cookie.");
const afterLogout = await call("GET", "/api/jobs", { cookie: session });
check(afterLogout.status === 401, "A session must stop working once it is signed out.");

// 9. Only an administrator may add or remove people.
const designer = cookieFrom(await call("POST", "/api/login", { body: { email: "designer@vocate.org", password: "a-much-longer-password" } }));
const refused = await call("POST", "/api/users", { cookie: designer, body: { email: "new@vocate.org" } });
check(refused.status === 403, "A designer must not be able to add an account, got " + refused.status);
const listRefused = await call("GET", "/api/users", { cookie: designer });
check(listRefused.status === 403, "A designer must not be able to list accounts.");

await seedUser("boss@vocate.org", "an-admin-password-1");
const admin = cookieFrom(await call("POST", "/api/login", { body: { email: "boss@vocate.org", password: "an-admin-password-1" } }));
const created = await call("POST", "/api/users", { cookie: admin, body: { email: "New@Vocate.org", name: "New Designer" } });
check(created.status === 200, "An administrator must be able to add someone, got " + created.text);
check(typeof created.json.password === "string" && created.json.password.length >= 16, "Adding someone must return a password to hand over.");
check(created.json.user.email === "new@vocate.org", "The address must be stored in one case, or two accounts appear for one person.");
check(created.json.user.mustChangePassword === true, "An issued password must have to be changed at the first sign-in.");
const issued = await call("POST", "/api/login", { body: { email: "new@vocate.org", password: created.json.password } });
check(issued.status === 200 && issued.json.mustChangePassword === true, "The issued password must actually sign that person in.");

// Issuing again replaces the password rather than making a second account.
const reissued = await call("POST", "/api/users", { cookie: admin, body: { email: "new@vocate.org" } });
check(reissued.status === 200 && reissued.json.replaced === true, "Issuing a password again must be reported as a replacement.");
const staleIssued = await call("POST", "/api/login", { body: { email: "new@vocate.org", password: created.json.password } });
check(staleIssued.status === 401, "The superseded password must stop working.");

const listed = await call("GET", "/api/users", { cookie: admin });
check(listed.status === 200 && listed.json.users.length === 3, "An administrator must see every account, saw " + (listed.json.users || []).length);
check(!listed.text.includes("passwordHash"), "The list of people must not carry password hashes.");

// 10. Removing an account, including the rule that stops an administrator
//     removing the last way in: their own.
const selfRemoval = await call("POST", "/api/users/remove", { cookie: admin, body: { email: "boss@vocate.org" } });
check(selfRemoval.status === 400, "An administrator must not remove their own account.");
const removed = await call("POST", "/api/users/remove", { cookie: admin, body: { email: "new@vocate.org" } });
check(removed.status === 200 && !kv.store.has("user:new@vocate.org"), "Removing an account must delete it.");

// 11. A disabled account cannot sign in, and an existing session for it dies at
//     the next request rather than a week later.
await seedUser("gone@vocate.org", "a-valid-password-12");
const goneSession = cookieFrom(await call("POST", "/api/login", { body: { email: "gone@vocate.org", password: "a-valid-password-12" } }));
check((await call("GET", "/api/jobs", { cookie: goneSession })).status === 200, "The account must work before it is disabled.");
const disabledRecord = JSON.parse(kv.store.get("user:gone@vocate.org").value);
disabledRecord.disabled = true;
await kv.put("user:gone@vocate.org", JSON.stringify(disabledRecord));
check((await call("GET", "/api/jobs", { cookie: goneSession })).status === 401, "Disabling an account must end its open sessions at once.");
check((await call("POST", "/api/login", { body: { email: "gone@vocate.org", password: "a-valid-password-12" } })).status === 401, "A disabled account must not sign in.");

// 12. Guessing is answered with a lockout. A worker has no memory between
//     requests, so there is nothing else to slow an attacker down with.
for (let attempt = 0; attempt < 8; attempt++) {
  await call("POST", "/api/login", { body: { email: "designer@vocate.org", password: "guess-" + attempt } });
}
const locked = await call("POST", "/api/login", { body: { email: "designer@vocate.org", password: "a-much-longer-password" } });
check(locked.status === 429, "Repeated failures must lock the account out, even for the right password, got " + locked.status);
check(/fifteen minutes|administrator/i.test(locked.text), "The lockout must say what to do about it.");
// An administrator issuing a new password clears the lockout, or the fix for a
// forgotten password would not work on the account that most needs it.
await call("POST", "/api/users", { cookie: admin, body: { email: "designer@vocate.org" } });
const afterReissue = await call("POST", "/api/login", { body: { email: "designer@vocate.org", password: "wrong-again" } });
check(afterReissue.status === 401, "Issuing a new password must clear the lockout, got " + afterReissue.status);

// 13. A forged Access header must still be worthless, and a cookie that is not
//     a session must not be treated as one.
const forged = await call("GET", "/api/jobs", { headers: { "cf-access-authenticated-user-email": "boss@vocate.org" } });
check(forged.status === 401, "The Access email header must never be trusted on its own.");
const madeUp = await call("GET", "/api/jobs", { cookie: "bs_session=" + "f".repeat(64) });
check(madeUp.status === 401, "An invented session id must not be accepted.");

// 14. The runner keeps its own credential, so turning sign-in on does not cut
//     off the machine that does the actual writing.
await kv.put("runner:token:machine-token", JSON.stringify({ owner: "designer@vocate.org", label: "NEWKING" }));
const runnerJobs = await call("GET", "/api/runner/jobs", { headers: { "x-book-runner-token": "machine-token" } });
check(runnerJobs.status === 200, "The agent must still reach its work with a runner token, got " + runnerJobs.status);
const runnerNoToken = await call("GET", "/api/runner/jobs");
check(runnerNoToken.status === 401, "A runner route without a token must be refused.");

// 15. A designer opens Book Studio and sees their own books. A colleague's
//     books are one deliberate click away, with a name against each, because a
//     team writing courses together has to see what is in flight and who has
//     it. Showing everything by default would bury a person's own work.
// A fresh account, because the account above has just been through a lockout
// and a reissued password by the time this runs.
await seedUser("reader@vocate.org", "a-reader-password-12");
await kv.put("job:mine-1", JSON.stringify({ id: "mine-1", owner: "reader@vocate.org", status: "Queued", title: "My course", createdAt: new Date().toISOString(), log: [] }));
await kv.put("job:theirs-1", JSON.stringify({ id: "theirs-1", owner: "boss@vocate.org", status: "Running", title: "Their course", createdAt: new Date().toISOString(), log: [] }));
await kv.put("job:orphan-1", JSON.stringify({ id: "orphan-1", owner: "", status: "Completed", title: "Made before accounts existed", createdAt: new Date().toISOString(), log: [] }));
await kv.put("jobs:index", JSON.stringify(["mine-1", "theirs-1", "orphan-1"]));

const designerAgain = cookieFrom(await call("POST", "/api/login", { body: { email: "reader@vocate.org", password: "a-reader-password-12" } }));
const mineOnly = await call("GET", "/api/jobs", { cookie: designerAgain });
check(mineOnly.status === 200, "The books list must load for a signed-in designer.");
const mineIds = mineOnly.json.jobs.map((job) => job.id).sort();
check(mineIds.includes("mine-1"), "A designer must see their own book.");
check(!mineIds.includes("theirs-1"), "A designer must not see someone else's book by default.");
check(mineIds.includes("orphan-1"), "A book made before accounts existed must not vanish from the list.");
check(mineOnly.json.scope === "mine", "The list must say whose books it is showing.");

const everyone = await call("GET", "/api/jobs?scope=everyone", { cookie: designerAgain });
check(everyone.status === 200, "Everyone's books must be readable by a signed-in designer.");
const allIds = everyone.json.jobs.map((job) => job.id).sort();
check(allIds.includes("mine-1") && allIds.includes("theirs-1"), "The shared view must show every book.");
check(everyone.json.scope === "everyone", "The shared view must say so.");
check(everyone.json.jobs.every((job) => "owner" in job), "Each book in the shared view must say whose it is.");
check(everyone.json.jobs.some((job) => job.status === "Running"), "The shared view must show how far along each book is.");

// Signing out must still be the end of it, whichever view was open.
const strangerScope = await call("GET", "/api/jobs?scope=everyone");
check(strangerScope.status === 401, "Everyone's books must not be readable without signing in.");

// 16. Two computers belonging to one person must both be visible. They shared
//     a single record before, so a laptop and a desktop overwrote each other
//     every twenty seconds and a designer standing at the one that was not
//     reporting was shown the other one as "Ready".
const laptopToken = await call("POST", "/api/runner-tokens", { cookie: admin, body: { label: "Vocate laptop" } });
const deskToken = await call("POST", "/api/runner-tokens", { cookie: admin, body: { label: "Desk" } });
check(laptopToken.json.token !== deskToken.json.token, "Two machines must get two tokens.");

const report = (token, name, codexStatus, extra = {}) => call("POST", "/api/runner/status", {
  headers: { "x-book-runner-token": token },
  // A current Book Studio unless a test says otherwise: most of these checks
  // are about what a machine reports, not about which version it runs.
  body: { runnerName: name, version: "2026.09.23.1", codex: { status: codexStatus, version: "codex-cli 0.154.0" }, ...extra }
});
check((await report(laptopToken.json.token, "LAPTOP / gio", "Connected")).status === 200, "A machine must be able to report itself.");
check((await report(deskToken.json.token, "NEWKING / gio", "Unavailable")).status === 200, "A second machine must be able to report itself too.");

const machines = await call("GET", "/api/runner/status", { cookie: admin });
check(machines.status === 200, "The list of computers must load.");
check(machines.json.machines.length === 2, "Both computers must be listed, saw " + machines.json.machines.length);
const names = machines.json.machines.map((machine) => machine.runnerName).sort();
check(names[0] === "LAPTOP / gio" && names[1] === "NEWKING / gio", "Each computer must keep its own name; got " + names.join(", "));
check(machines.json.machines.some((machine) => machine.codex.status === "Unavailable"), "A computer whose Codex is not working must say so rather than borrow another computer's answer.");

// And one person must not see another person's computers.
const otherSees = await call("GET", "/api/runner/status", { cookie: designerAgain });
check((otherSees.json.machines || []).length === 0, "Machines must belong to the person who connected them.");
check(otherSees.json.connected === false, "Someone with no computer running must be told so plainly.");
check(/not running|is running/i.test(otherSees.json.detail || ""), "That message must say what to do about it: " + otherSees.json.detail);

// 17. Tokens created before machines were told apart must not have to be
//     recreated by hand. The first time such a machine reports, it earns an id
//     and stops sharing a record with every other computer its owner has.
await kv.put("runner:token:old-token", JSON.stringify({ owner: "boss@vocate.org", label: "Older laptop" }));
check((await report("old-token", "OLDER / gio", "Connected")).status === 200, "An older token must still work.");
const upgraded = await kv.get("runner:token:old-token", "json");
check(Boolean(upgraded.id), "An older token must be given a machine id the first time it reports.");
check(!("tokenKey" in upgraded), "The stored token must not carry the key it is stored under.");
const afterUpgrade = await call("GET", "/api/runner/status", { cookie: admin });
check(afterUpgrade.json.machines.length === 3, "The upgraded machine must be listed alongside the others, saw " + afterUpgrade.json.machines.length);
const older = afterUpgrade.json.machines.filter((machine) => machine.runnerName === "OLDER / gio");
check(older.length === 1, "The upgraded machine must appear once, not twice; saw " + older.length);

// 17b. Running the setup command again gives a computer a new token and id,
//      while the record under its old id lingers until it expires. The Vocate
//      laptop was then listed twice and counted twice ("1 of 3 ready" with two
//      computers), and its stale copy still said Ready.
const firstSetup = await call("POST", "/api/runner-tokens", { cookie: admin, body: { label: "Laptop, first setup" } });
const secondSetup = await call("POST", "/api/runner-tokens", { cookie: admin, body: { label: "Laptop, setup run again" } });
await report(firstSetup.json.token, "VES-1H84211Y80 / GiovanniDuarte", "Connected", { version: "" });
await new Promise((resolve) => setTimeout(resolve, 5));
await report(secondSetup.json.token, "VES-1H84211Y80 / GiovanniDuarte", "Unknown", { version: "2026.09.23.12" });
const afterSetupAgain = await call("GET", "/api/runner/status", { cookie: admin });
const laptopRows = afterSetupAgain.json.machines.filter((machine) => machine.runnerName === "VES-1H84211Y80 / GiovanniDuarte");
check(laptopRows.length === 1, "A computer set up twice must be listed once, saw " + laptopRows.length);
check(laptopRows[0].version === "2026.09.23.12" && laptopRows[0].codex.status === "Unknown", "And as its running agent reports it, not as the stale copy.");
// Case and spacing in the name do not make a second computer.
await new Promise((resolve) => setTimeout(resolve, 5));
await report(firstSetup.json.token, " ves-1h84211y80 / giovanniduarte ", "Connected", { version: "2026.09.23.12" });
const recased = (await call("GET", "/api/runner/status", { cookie: admin })).json.machines.filter((machine) => /ves-1h84211y80/i.test(machine.runnerName));
check(recased.length === 1 && recased[0].codex.status === "Connected", "The newest report for a computer wins, however its name is cased.");
// Two different computers are still two.
check(afterSetupAgain.json.machines.some((machine) => machine.runnerName === "LAPTOP / gio") && afterSetupAgain.json.machines.some((machine) => machine.runnerName === "NEWKING / gio"), "Different computers must still each be listed.");
await kv.delete("runner:status:boss@vocate.org:" + (await kv.get("runner:token:" + firstSetup.json.token, "json")).id);
await kv.delete("runner:status:boss@vocate.org:" + (await kv.get("runner:token:" + secondSetup.json.token, "json")).id);

// 18. A computer has no browser session, so it cannot ask the page whether it
//     arrived. It asks with the credential it already has, which is what lets
//     the setup command answer "did that work?" on the screen the designer is
//     looking at.
const selfBefore = await call("GET", "/api/runner/self", { headers: { "x-book-runner-token": "machine-token" } });
check(selfBefore.status === 200 && selfBefore.json.reported === false, "A machine that has not reported must be told so, not refused.");
await report("machine-token", "SELFCHECK / gio", "Connected");
const selfAfter = await call("GET", "/api/runner/self", { headers: { "x-book-runner-token": "machine-token" } });
check(selfAfter.json.reported === true, "A machine that has reported must be able to see itself.");
check(selfAfter.json.runnerName === "SELFCHECK / gio", "It must see its own record, not another machine's.");
check((await call("GET", "/api/runner/self")).status === 401, "Asking without a token must be refused.");

// 19. Everything the agent reads must survive the trip. An option the cloud
//     drops is replaced by a default on a designer's PC twenty minutes later,
//     in a book they then have to read to notice.
const made = await call("POST", "/api/jobs", { cookie: designerAgain, body: {
  courseCode: "RB1010", title: "Options survive",
  readingLevel: 10, sourceMode: "Assigned", allowAdditionalResearch: true,
  imageSettings: { context: "Healthcare", instructions: "no clinical scenes" },
  files: [{ name: "draft.docx", size: 12, contentBase64: "AAAA" }]
} });
check(made.status === 201, "A book must be creatable, got " + made.status + " " + made.text);
check(made.json.options.readingLevel === 10, "The reading level must be kept, got " + made.json.options.readingLevel);
check(made.json.options.sourceMode === "Assigned", "The choice of sources must be kept.");
check(made.json.options.allowAdditionalResearch === true, "Extra research must be kept.");
check(made.json.options.imageSettings.context === "Healthcare", "The image setting must be kept.");
check(made.json.owner === "reader@vocate.org", "A book must belong to whoever made it.");

// A made-up source mode must not reach the generator as itself.
const odd = await call("POST", "/api/jobs", { cookie: designerAgain, body: {
  title: "Odd", sourceMode: "WhateverIWant",
  files: [{ name: "draft.docx", size: 12, contentBase64: "AAAA" }]
} });
check(odd.json.options.sourceMode === "UploadedOnly", "An unknown source mode must fall back to the safe one, got " + odd.json.options.sourceMode);

// 20. The bridge. The Book Studio a designer knows is thousands of lines of
//     PowerShell on their own PC, so the browser asks the cloud, the cloud
//     asks the agent, and the agent answers from that machine. Rewriting any
//     of it up here would make a second copy of the rules that drifts.
const studioEnv = env;
const studioCall = async (path, options = {}) => {
  const init = { method: options.method || "GET", headers: { ...(options.headers || {}) } };
  if (options.cookie) init.headers.cookie = options.cookie;
  if (options.body !== undefined) { init.body = JSON.stringify(options.body); init.headers["content-type"] = "application/json"; }
  const response = await worker.fetch(new Request("https://ebookstudio.vocate.app" + path, init), studioEnv);
  return { status: response.status, text: await response.text(), headers: response.headers };
};

// Nobody signed in: a page is sent to sign in, an API call is refused.
const strangerPage = await studioCall("/", { headers: { accept: "text/html" } });
check(strangerPage.status === 302, "A signed-out page request must go to the sign-in screen, got " + strangerPage.status);
check((await studioCall("/api/jobs")).status === 401, "A signed-out API call must be refused.");

// Signed in, but nothing of theirs is running: say so instead of hanging.
const noMachinePage = await studioCall("/", { cookie: designerAgain, headers: { accept: "text/html" } });
check(noMachinePage.status === 503, "With no computer running, the page must say so, got " + noMachinePage.status);
check(/not answering on your computer/i.test(noMachinePage.text), "That page must explain what is missing.");
check(/connect/i.test(noMachinePage.text), "That page must say where to go to fix it.");

// With a machine, the request is carried to it and its answer comes back.
// The browser is sent to whichever machine reported most recently, so this one
// reports last and is therefore the one the request must reach.
await report(laptopToken.json.token, "LAPTOP / gio", "Connected");
const admins = await call("GET", "/api/runner/status", { cookie: admin });
check(admins.json.machines[0].runnerName === "LAPTOP / gio", "The most recent machine must be the one listed first, saw " + admins.json.machines[0].runnerName);
const bridged = studioCall("/api/jobs", { cookie: admin });
// The agent collects it, answers, and the browser call completes.
const collected = await call("GET", "/api/bridge/next", { headers: { "x-book-runner-token": laptopToken.json.token } });
check(collected.status === 200, "The agent must be able to collect a request, got " + collected.status);
check(collected.json.path === "/api/jobs", "The request must arrive with the path the browser asked for, got " + collected.json.path);
check(collected.json.method === "GET", "The method must survive the trip.");
const answer = { id: collected.json.id, status: 200, headers: { "content-type": "application/json" },
  bodyBase64: Buffer.from(JSON.stringify({ jobs: ["from the local machine"] })).toString("base64") };
const delivered = await call("POST", "/api/bridge/reply", { headers: { "x-book-runner-token": laptopToken.json.token }, body: answer });
check(delivered.json.delivered === true, "An answer must reach the browser call that was waiting.");
const finished = await bridged;
check(finished.status === 200, "The browser must get the local answer, got " + finished.status);
check(finished.text.includes("from the local machine"), "The body must be the local one, got " + finished.text.slice(0, 80));
check(finished.headers.get("content-type") === "application/json", "The local content type must survive.");

// And the bridge is a runner route: it needs the machine credential.
check((await call("GET", "/api/bridge/next")).status === 401, "Collecting work must require a runner token.");
check((await call("POST", "/api/bridge/reply", { body: { id: "1" } })).status === 401, "Answering must require a runner token.");

// 21. Which Book Studio each computer is running, and whether it can fetch the
//     next one by itself. A machine that has quietly stopped updating is the
//     reason a fix that shipped weeks ago never reached the person using it.
await report(deskToken.json.token, "DESK / gio", "Connected", {
  version: "2026.09.22.8", updates: { automatic: true, reason: "" }
});
await report(laptopToken.json.token, "LAPTOP / gio", "Connected", {
  version: "2026.09.20.1", updates: { automatic: false, reason: "there are unsaved changes in this folder" }
});
const fleet = await call("GET", "/api/runner/status", { cookie: admin });
const desk = fleet.json.machines.find((machine) => machine.runnerName === "DESK / gio");
const laptop = fleet.json.machines.find((machine) => machine.runnerName === "LAPTOP / gio");
check(desk.version === "2026.09.22.8", "Each machine must report which Book Studio it runs, got " + desk.version);
check(desk.updates.automatic === true, "A machine that keeps itself current must say so.");
check(laptop.updates.automatic === false, "A machine that has stopped updating must say so.");
check(/unsaved changes/.test(laptop.updates.reason), "It must say why it stopped: " + laptop.updates.reason);

// 22. One site. A designer changing a setting must not have to leave Book
//     Studio for a second address: the cloud half is under /cloud on the same
//     site, and the old address moves a person there rather than serving a
//     second copy of it.
const movedPage = await worker.fetch(new Request("https://ebook.vocate.app/connect", { headers: { accept: "text/html" } }), env);
check(movedPage.status === 302, "The old address must move a person to the one site, got " + movedPage.status);
check((movedPage.headers.get("location") || "").includes("ebookstudio.vocate.app/cloud/connect"), "It must move them to the same page on the one site, got " + movedPage.headers.get("location"));
const movedRoot = await worker.fetch(new Request("https://ebook.vocate.app/", { headers: { accept: "text/html" } }), env);
check((movedRoot.headers.get("location") || "").endsWith("/cloud/"), "The old front page must land on the books, got " + movedRoot.headers.get("location"));

// An agent talks to whichever address it was given, so its routes must answer
// on both rather than being redirected into a browser page.
const agentOnOldName = await worker.fetch(new Request("https://ebook.vocate.app/api/runner/jobs", { headers: { "x-book-runner-token": "machine-token" } }), env);
check(agentOnOldName.status === 200, "An agent on the old address must still be served, got " + agentOnOldName.status);
const healthOnOldName = await worker.fetch(new Request("https://ebook.vocate.app/api/health"), env);
check(healthOnOldName.status === 200, "The health probe must answer on both addresses.");

// 23. A designer is sent to a computer that can answer. A laptop that reported
//     thirty seconds ago and runs a Book Studio from before any of this worked
//     is worse than a desktop that reported a minute ago and can serve the
//     page: routing to the first means a minute of nothing and then a failure,
//     which is exactly what was happening.
await report(deskToken.json.token, "DESK / gio", "Connected", { version: "2026.09.23.1" });
await report(laptopToken.json.token, "OLD LAPTOP / gio", "Connected", { version: "2026.09.22.2" });
const seen = await call("GET", "/api/runner/status", { cookie: admin });
check(seen.json.machines[0].runnerName === "OLD LAPTOP / gio", "The old laptop must be the most recent, or this proves nothing.");

const routed = studioCall("/api/jobs", { cookie: admin });
const collectedByDesk = await call("GET", "/api/bridge/next", { headers: { "x-book-runner-token": deskToken.json.token } });
check(collectedByDesk.json.path === "/api/jobs", "The request must go to the computer that can answer, not the most recent one.");
await call("POST", "/api/bridge/reply", { headers: { "x-book-runner-token": deskToken.json.token }, body: {
  id: collectedByDesk.json.id, status: 200, headers: { "content-type": "application/json" },
  bodyBase64: Buffer.from(JSON.stringify({ jobs: [] })).toString("base64") } });
check((await routed).status === 200, "And the designer gets their page.");

// With nothing but an old computer, the page says which one and why, at once,
// rather than holding the tab open for a minute first.
// Only the old laptop remains: every other machine of theirs stops reporting.
const deskRecord = await kv.get("runner:token:" + deskToken.json.token, "json");
const oldRecord = await kv.get("runner:token:old-token", "json");
await kv.delete("runner:status:boss@vocate.org:" + deskRecord.id);
if (oldRecord && oldRecord.id) await kv.delete("runner:status:boss@vocate.org:" + oldRecord.id);
const stale = await studioCall("/", { cookie: admin, headers: { accept: "text/html" } });
check(stale.status === 503, "An unusable computer must be reported, got " + stale.status);
check(stale.text.includes("OLD LAPTOP / gio"), "It must name the computer holding them up.");
check(/older than this page needs/.test(stale.text), "It must say what is wrong with it.");
check(/updates itself within the hour/.test(stale.text), "It must say that it mends itself.");
check(stale.text.includes("2026.09.22.2"), "It must say which version that computer has.");

// 24. A computer that is current but not listening -- switched off, or its
//     Book Studio window closed -- must be reported at once. Waiting the full
//     minute to discover it is a tab that hangs and then says something a
//     designer cannot act on, which is what they kept seeing.
const quietToken = await call("POST", "/api/runner-tokens", { cookie: admin, body: { label: "Quiet" } });
await report(quietToken.json.token, "QUIET / gio", "Connected");
const started = Date.now();
const quiet = await studioCall("/api/jobs", { cookie: admin });
const waited = Date.now() - started;
check(quiet.status === 503, "A machine that is not listening must be reported, got " + quiet.status);
check(waited < 5000, "It must be reported at once, not after the timeout; waited " + waited + " ms");
check(/not listening/i.test(quiet.text), "It must say nobody is listening there: " + quiet.text.slice(0, 120));
check(/within the hour|not be running/i.test(quiet.text), "And what to do about it.");

// 25. Found by the security audit of 2026-09-23. Each check stands for a hole
//     that was open on the live site.

// A single book and its Word file were answered to anyone with the id, signed
// in or not: the audit downloaded a finished 6 MB book with no session at all.
await kv.put("job:private-1", JSON.stringify({ id: "private-1", owner: "reader@vocate.org", status: "Completed", title: "Private", createdAt: new Date().toISOString(), log: [], artifacts: [] }));
const strangerBook = await worker.fetch(new Request("https://ebookstudio.vocate.app/cloud/api/jobs/private-1"), env);
check(strangerBook.status === 401, "A book must not be readable without signing in, got " + strangerBook.status);
const strangerFile = await worker.fetch(new Request("https://ebookstudio.vocate.app/cloud/api/jobs/private-1/artifact?name=x.docx"), env);
check(strangerFile.status === 401, "A book's files must not be downloadable without signing in, got " + strangerFile.status);
const memberBook = await call("GET", "/api/jobs/private-1", { cookie: designerAgain });
check(memberBook.status === 200, "A signed-in designer can still read a book, got " + memberBook.status);

// The session cookie was set for the whole vocate.app domain, handing every
// designer's session to every other app on it.
const freshLogin = await call("POST", "/api/login", { body: { email: "reader@vocate.org", password: "a-reader-password-12" } });
const cookieHeader = freshLogin.headers.get("set-cookie") || "";
check(cookieHeader.startsWith("__Host-"), "The session cookie must carry the __Host- prefix, got " + cookieHeader.split("=")[0]);
check(!/Domain=/i.test(cookieHeader), "The session cookie must not be set for a whole domain.");
check(/Path=\//.test(cookieHeader) && /Secure/.test(cookieHeader) && /HttpOnly/.test(cookieHeader), "And it must stay Secure, HttpOnly and site-wide.");

// The shared token from the first spike could claim anyone's book.
await kv.put("runner:token", "shared-spike-token");
const legacyTry = await call("GET", "/api/runner/jobs", { headers: { "x-book-runner-token": "shared-spike-token" } });
check(legacyTry.status === 401, "The old shared runner token must no longer be honoured, got " + legacyTry.status);

// A book with no owner dates from before accounts; no machine may claim it.
await kv.put("job:ownerless-1", JSON.stringify({ id: "ownerless-1", owner: "", status: "Queued", title: "Ownerless", createdAt: new Date().toISOString(), log: [] }));
const indexNow = JSON.parse(kv.store.get("jobs:index").value);
await kv.put("jobs:index", JSON.stringify([...indexNow, "ownerless-1"]));
const claimable = await call("GET", "/api/runner/jobs", { headers: { "x-book-runner-token": laptopToken.json.token } });
check(!claimable.json.jobs.some((job) => job.id === "ownerless-1"), "A machine must not be offered a book that has no owner.");

// A change asked for from another site is refused; SameSite does not cover
// other apps on vocate.app, which count as the same site.
const crossSite = await worker.fetch(new Request("https://ebookstudio.vocate.app/cloud/api/logout", { method: "POST", headers: { origin: "https://typing.vocate.app", cookie: designerAgain } }), env);
check(crossSite.status === 403, "A change requested from another site must be refused, got " + crossSite.status);
const sameSite = await worker.fetch(new Request("https://ebookstudio.vocate.app/cloud/api/logout", { method: "POST", headers: { origin: "https://ebookstudio.vocate.app" } }), env);
check(sameSite.status === 200, "A change requested from this site must still work, got " + sameSite.status);
const agentNoOrigin = await call("POST", "/api/runner/status", { headers: { "x-book-runner-token": laptopToken.json.token }, body: { runnerName: "LAPTOP / gio", codex: { status: "Connected" } } });
check(agentNoOrigin.status === 200, "An agent, which sends no Origin, must still be able to report itself.");

// Every response carries the headers that stop framing and content sniffing.
const anyPage = await worker.fetch(new Request("https://ebookstudio.vocate.app/cloud/login", { headers: { accept: "text/html" } }), env);
check(anyPage.headers.get("x-frame-options") === "DENY", "Pages must refuse to be framed.");
check(/frame-ancestors 'none'/.test(anyPage.headers.get("content-security-policy") || ""), "The content policy must forbid framing too.");
check(anyPage.headers.get("x-content-type-options") === "nosniff", "Responses must not be content-sniffed.");
check(Boolean(anyPage.headers.get("strict-transport-security")), "Browsers must be told to keep to HTTPS.");

// Guessing across many addresses from one network is limited as well.
for (let attempt = 0; attempt < 32; attempt++) {
  await worker.fetch(new Request("https://ebookstudio.vocate.app/cloud/api/login", { method: "POST", headers: { "content-type": "application/json", "cf-connecting-ip": "203.0.113.9" }, body: JSON.stringify({ email: "spray" + attempt + "@vocate.org", password: "guess" }) }), env);
}
const sprayed = await worker.fetch(new Request("https://ebookstudio.vocate.app/cloud/api/login", { method: "POST", headers: { "content-type": "application/json", "cf-connecting-ip": "203.0.113.9" }, body: JSON.stringify({ email: "reader@vocate.org", password: "a-reader-password-12" }) }), env);
check(sprayed.status === 429, "One network guessing across many addresses must be slowed down, got " + sprayed.status);

// An administrator could store markup as an address; the only check was an @.
const markupAddress = await call("POST", "/api/users", { cookie: admin, body: { email: "<img src=x onerror=alert(1)>@vocate.org" } });
check(markupAddress.status === 400, "An address that is not an address must be refused, got " + markupAddress.status);

// The old addresses must land on the page asked for, not on /cloud/cloud/...
const oldLogin = await worker.fetch(new Request("https://ebook.vocate.app/cloud/login", { headers: { accept: "text/html" } }), env);
check(!(oldLogin.headers.get("location") || "").includes("/cloud/cloud"), "An old link must not gain a second /cloud, got " + oldLogin.headers.get("location"));

// 26. Asking for an account. Only a vocate.org address may ask, and asking
//     creates nothing: an address proves only that someone typed it, so an
//     administrator who knows their people approves every request. Before
//     this, the only way in was an administrator adding someone by hand.
const studioEnvForSignup = { ...env, SIGNUP_DOMAIN: "vocate.org" };
const ask = (body, ip = "198.51.100." + Math.floor(Math.random() * 200)) => worker.fetch(new Request("https://ebookstudio.vocate.app/cloud/api/signup", {
  method: "POST", headers: { "content-type": "application/json", "cf-connecting-ip": ip }, body: JSON.stringify(body)
}), studioEnvForSignup).then(async (response) => ({ status: response.status, text: await response.text() }));

check((await ask({ name: "Someone", email: "someone@gmail.com" })).status === 400, "An address outside vocate.org must not be able to ask for an account.");
check((await ask({ name: "Someone", email: "someone@vocate.org.evil.example" })).status === 400, "A look-alike domain must not pass as vocate.org.");
check((await ask({ name: "", email: "someone@vocate.org" })).status === 400, "A request must say who is asking.");
const asked = await ask({ name: "New Designer", email: "New.Designer@Vocate.org", note: "RB1010" });
check(asked.status === 200, "A vocate.org address may ask for an account, got " + asked.status);
check(/administrator/.test(asked.text) && /Nothing is emailed/.test(asked.text), "The reply must say what happens next, and that nothing is emailed.");

// Asking is not getting in.
const tooSoon = await call("POST", "/api/login", { body: { email: "new.designer@vocate.org", password: "anything-at-all-12" } });
check(tooSoon.status === 401, "Asking for an account must not create one.");

// The same reply whether or not the address already has an account, so this
// form cannot be used to find out who does.
const already = await ask({ name: "Reader", email: "reader@vocate.org" });
check(already.text === asked.text, "An address that already has an account must get the same reply as a new one.");
check(!kv.store.has("signup:reader@vocate.org"), "And no request is recorded for someone who already has an account.");

// Only an administrator sees and decides the requests.
check((await call("GET", "/api/signups", { cookie: designerAgain })).status === 403, "A designer must not see account requests.");
const pendingList = await call("GET", "/api/signups", { cookie: admin });
check(pendingList.status === 200 && pendingList.json.requests.some((r) => r.email === "new.designer@vocate.org"), "An administrator sees the request, with the address in one case.");
check(pendingList.json.requests.find((r) => r.email === "new.designer@vocate.org").note === "RB1010", "The note the person left is kept for the administrator.");
check((await call("POST", "/api/signups/approve", { cookie: designerAgain, body: { email: "new.designer@vocate.org" } })).status === 403, "A designer must not approve a request.");

const approved = await call("POST", "/api/signups/approve", { cookie: admin, body: { email: "new.designer@vocate.org" } });
check(approved.status === 200 && typeof approved.json.password === "string" && approved.json.password.length >= 16, "Approving issues a password to hand over.");
check(approved.json.user.mustChangePassword === true, "The issued password has to be changed at the first sign-in.");
const firstIn = await call("POST", "/api/login", { body: { email: "new.designer@vocate.org", password: approved.json.password } });
check(firstIn.status === 200 && firstIn.json.mustChangePassword === true, "The approved person can sign in, and is asked to choose a password.");
check(!kv.store.has("signup:new.designer@vocate.org"), "An approved request no longer waits.");
check((await call("POST", "/api/signups/approve", { cookie: admin, body: { email: "new.designer@vocate.org" } })).status === 404, "A request cannot be approved twice.");

await ask({ name: "Not Staff", email: "declined@vocate.org" });
const declined = await call("POST", "/api/signups/decline", { cookie: admin, body: { email: "declined@vocate.org" } });
check(declined.status === 200 && !kv.store.has("signup:declined@vocate.org"), "A declined request is removed.");
check((await call("POST", "/api/login", { body: { email: "declined@vocate.org", password: "anything-at-all-12" } })).status === 401, "A declined request leaves no way in.");

// One network cannot flood the administrator with requests.
let lastFromOneNetwork = null;
for (let attempt = 0; attempt < 12; attempt++) lastFromOneNetwork = await ask({ name: "Flood " + attempt, email: "flood" + attempt + "@vocate.org" }, "192.0.2.77");
check(lastFromOneNetwork.status === 429, "Requests from one network must be limited, got " + lastFromOneNetwork.status);

// The guide and the request form are read before anyone has an account.
for (const open of ["/cloud/guide", "/cloud/signup"]) {
  const openPage = await worker.fetch(new Request("https://ebookstudio.vocate.app" + open, { headers: { accept: "text/html" } }), env);
  check(openPage.status === 200, open + " must be readable without signing in, got " + openPage.status);
}

console.log("PASS: " + checks + " sign-in checks (sessions, password storage, lockout, administration, runner tokens)");
