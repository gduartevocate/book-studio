// Runs the real page with an in-memory HTTP boundary. Never contacts a server,
// Codex, or a real book.
//
// Ann Jackson opened Book Studio on the web site and "it was not working at
// all": the book list failed to load and the page said nothing, because the
// failure went to the status line of the New book form, which that page hides.
// A list that cannot be loaded must say so where the books would be, with a
// way to try again, and an empty list reached through the web site must say
// which folder on the computer it is showing.
const libraryFixture = {
  jobsReply: "fail",
  jobsCalls: 0,
  checks: 0,
  errors: [],
  job: { id: "library-fixture", courseCode: "LB1000", title: "Library fixture book", status: "Completed",
    workflowStage: "id-review", createdAt: "2026-09-24T09:00:00", artifacts: [], log: [] },
  machine: { runnerName: "ANN-PC / ann", seenAt: new Date().toISOString(), version: "2026.09.24.1",
    codex: { status: "Connected", version: "codex-cli 0.1" },
    studio: { status: "other-folder", installPath: "C:\\Users\\ann\\AppData\\Local\\Book Studio<img src=x>", bookCount: 0,
      agentPath: "C:\\Users\\ann\\book-studio", agentBookCount: 12 } }
};
// A real dialog blocks a headless browser forever.
window.confirm = () => true;
window.alert = () => {};
window.prompt = () => null;
window.setInterval = () => 0; // The test drives loading itself.
window.addEventListener("error", (event) => libraryFixture.errors.push(event.message));
const reply = (body, status = 200, type = "application/json") =>
  new Response(typeof body === "string" ? body : JSON.stringify(body), { status, headers: { "content-type": type } });
window.fetch = async (input) => {
  const path = String(input);
  if (path === "/api/jobs") {
    libraryFixture.jobsCalls++;
    if (libraryFixture.jobsReply === "fail") return reply({ bridgeError: "Book Studio on your computer did not answer in time." }, 502);
    if (libraryFixture.jobsReply === "html") return reply("<!doctype html><title>Bad gateway</title><h1>Bad gateway</h1>", 500, "text/html");
    if (libraryFixture.jobsReply === "empty") return reply({ jobs: [] });
    return reply({ jobs: [libraryFixture.job] });
  }
  if (path === "/api/health") return reply({ status: "ok", service: "book-studio", installPath: "C:\\Users\\ann\\AppData\\Local\\Book Studio",
    installPathLength: 38, installPathWarning: "", bookCount: 0 });
  if (path === "/version.json") return reply({ version: "test-only" });
  if (path === "/api/packages") return reply({ packages: [] });
  if (path === "/api/codex/status") return reply({ installed: true, available: false, notes: [] });
  if (path.startsWith("/api/updates/status")) return reply({ installedVersion: "test-only", isRepository: false, message: "Fixture." });
  if (path === "/cloud/api/identity") return reply({ email: "ann@vocate.org" });
  if (path === "/cloud/api/runner/status") return reply({ connected: true, machines: [libraryFixture.machine] });
  if (path.endsWith("/chapters")) return reply({ chapters: [] });
  if (path.endsWith("/codex-prompts")) return reply({ prompts: [] });
  if (path.endsWith("/visuals")) return reply({ visuals: [] });
  if (path.includes("/ai-requests")) return reply({ requests: [], sessionId: "fixture" });
  return reply({ error: "Not in the fixture: " + path }, 404);
};

window.addEventListener("DOMContentLoaded", async () => {
  const output = document.querySelector("#test-result");
  const check = (ok, message) => { if (!ok) throw new Error(message); libraryFixture.checks++; };
  const settle = async () => {
    for (let round = 0; round < 6; round++) {
      for (let i = 0; i < 50; i++) await Promise.resolve();
      await new Promise((resolve) => setTimeout(resolve, 0));
    }
  };
  try {
    await settle();
    const error = document.querySelector("#bookListError");
    const empty = document.querySelector("#bookListEmpty");
    const retry = document.querySelector("#bookListRetry");
    check(libraryFixture.jobsCalls >= 1, "The page must ask for the book list when it opens.");
    check(error && !error.hidden, "A book list that could not be loaded must say so on the books page, not leave it blank.");
    check(error.textContent.includes("could not be loaded") && error.textContent.includes("did not answer in time"),
      "The message must say the books could not be loaded, in the words the computer used: " + error.textContent);
    check(empty.hidden, "A list that failed to load must not claim there are no books.");
    check(retry && !retry.disabled && /try again/i.test(retry.textContent), "There must be a way to try again.");

    // An error page is not a sentence, and must not be shown as markup.
    libraryFixture.jobsReply = "html";
    retry.click(); await settle();
    check(!error.hidden && !error.textContent.includes("<") && error.textContent.includes("could not be loaded"),
      "An HTML error page must still end in a readable message: " + error.textContent);

    // Trying again once the computer answers shows the books and clears the message.
    libraryFixture.jobsReply = "ok";
    const before = libraryFixture.jobsCalls;
    retry.click(); await settle();
    check(libraryFixture.jobsCalls === before + 1, "Try again must ask for the list again.");
    check(error.hidden, "The message must go once the list loads.");
    check(document.querySelector("#bookList").textContent.includes("Library fixture book"), "The books must appear after trying again.");

    // Books on screen, then a refresh that fails: that is visible too.
    libraryFixture.jobsReply = "fail";
    await loadJobs({ force: true }).catch(() => {}); await settle();
    check(!error.hidden && error.textContent.includes("could not be refreshed"), "A failed refresh must be visible: " + error.textContent);

    // Reached through the web site, an empty list names the folder it is showing.
    libraryFixture.jobsReply = "empty";
    await loadInstallStatus(); await loadJobs({ force: true }); await settle();
    check(error.hidden && !empty.hidden, "A list that loaded empty is an empty list, not an error.");
    check(empty.textContent.includes("C:\\Users\\ann\\AppData\\Local\\Book Studio"), "An empty list must name the folder it is showing: " + empty.textContent);

    // Settings names the folder each computer is serving and how many books it
    // has -- and the folder it keeps up to date, when that is another one.
    await loadCloudSettings(); await settle();
    const machines = document.querySelector("#cloudMachines");
    check(machines.textContent.includes("Serving C:\\Users\\ann\\AppData\\Local\\Book Studio") && machines.textContent.includes("0 books"),
      "Settings must say which folder the computer is serving, and its books: " + machines.textContent);
    check(machines.textContent.includes("C:\\Users\\ann\\book-studio") && machines.textContent.includes("12 books"),
      "A different folder must name the one kept up to date, and its books: " + machines.textContent);
    check(!machines.querySelector("img"), "A folder name is text, never markup.");
    check(!libraryFixture.errors.length, "The page raised errors: " + libraryFixture.errors.join("; "));
    output.textContent = `PASS: ${libraryFixture.checks} book list checks (visible failure, readable reason, try again, failed refresh, empty list names its folder, Settings names the served folder)`;
  } catch (failure) {
    output.textContent = "FAIL: " + failure.message;
  }
});
