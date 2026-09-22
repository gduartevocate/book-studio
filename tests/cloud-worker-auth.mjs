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
const worker = (await import(pathToFileURL(copy).href)).default;

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
  ADMIN_EMAILS: "boss@vocate.org"
};

const base = "https://ebook.vocate.app";
async function call(method, path, { body, cookie, headers = {} } = {}) {
  const init = { method, headers: { ...headers } };
  if (body !== undefined) { init.body = JSON.stringify(body); init.headers["content-type"] = "application/json"; }
  if (cookie) init.headers.cookie = cookie;
  const response = await worker.fetch(new Request(base + path, init), env);
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
check(page.headers.get("location") === "/login?next=%2Fconnect", "The redirect must remember where the designer was going.");
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

console.log("PASS: " + checks + " sign-in checks (sessions, password storage, lockout, administration, runner tokens)");
