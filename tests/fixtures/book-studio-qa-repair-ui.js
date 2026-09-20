// Runs the actual app and click handlers with an in-memory HTTP boundary.
// Never contacts Codex, starts a real repair, or writes to an existing book.
const qaFixture = {
  posts: [], tests: 0, sequence: 0, requests: [], checks: 0, errors: [],
  connected: false, testPass: true, postError: "", chatError: false,
  confirms: [], alerts: [], confirmAnswer: true, stopped: [],
  job: { id: "qa-fixture", courseCode: "QA1000", title: "QA repair fixture", status: "Completed",
    outputFolder: "fixture-only", workflowStage: "id-review", createdAt: "2026-09-17T12:00:00",
    qaSummary: { status: "FAIL", failedChapters: 5 }, chatSessionId: "fixture-session", artifacts: [], log: [] }
};
// A real confirm() blocks a headless browser forever, so a button that asks
// before acting would hang this test instead of failing it.
window.confirm = message => { qaFixture.confirms.push(String(message)); return qaFixture.confirmAnswer; };
window.alert = message => { qaFixture.alerts.push(String(message)); };
window.addEventListener("error", event => qaFixture.errors.push(event.message));
window.addEventListener("unhandledrejection", event => qaFixture.errors.push(String(event.reason)));
window.setInterval = () => 0; // Tests drive the actual polling functions deterministically.
localStorage.clear(); // Isolated browser profile, not the user's browser.
window.fetch = async (path, options = {}) => {
  const reply = (body, ok = true) => ({ ok, text: async () => typeof body === "string" ? body : JSON.stringify(body), json: async () => body });
  const status = () => ({ installed: true, available: qaFixture.connected,
    connectionTestedAt: qaFixture.connected ? new Date().toISOString() : "",
    notes: [qaFixture.testPass ? "Connection has not been tested." : "Workspace spending limit reached; ask the workspace owner."] });
  if (path === "/version.json") return reply({ version: "test-only" });
  if (path === "/api/packages") return reply({ packages: [] });
  if (path === "/api/codex/status") return reply(status());
  if (path === "/api/codex/test") {
    qaFixture.tests++;
    if (qaFixture.connectionWait) await qaFixture.connectionWait;
    qaFixture.connected = qaFixture.testPass;
    return reply(status());
  }
  if (path === "/api/jobs") return reply({ jobs: [{ ...qaFixture.job, aiRequests: qaFixture.requests },
    ...(qaFixture.extraJob ? [{ ...qaFixture.job, id: "other-book", title: "Other book", outputFolder: "fixture-only-2", chatSessionId: "other-session", aiRequests: [] }] : [])] });
  if (path === "/api/jobs/other-book/ai-requests") return reply({ requests: [], sessionId: "other-session" });
  if (path === "/api/jobs/qa-fixture/ai-requests") {
    if (options.method === "POST") {
      qaFixture.posts.push(JSON.parse(options.body));
      if (qaFixture.postError) return reply(qaFixture.postError, false);
      const request = { ...JSON.parse(options.body), id: `repair-${++qaFixture.sequence}`, status: "Running",
        createdAt: new Date(Date.now() + qaFixture.sequence).toISOString(), errorUrl: "/fixture/error.log" };
      qaFixture.requests.unshift(request);
      return reply(request);
    }
    if (qaFixture.chatError) return reply("Network interrupted", false);
    return reply({ requests: qaFixture.requests, sessionId: "fixture-session" });
  }
  if (path.endsWith("/stop") && options.method === "POST") {
    const id = path.split("/").slice(-2)[0];
    qaFixture.stopped.push(id);
    qaFixture.requests = qaFixture.requests.map(entry => entry.id === id ? { ...entry, status: "Failed", error: "Stopped from Book Studio." } : entry);
    return reply({ stopped: true, id });
  }
  if (path.endsWith("/chapters")) return reply({ chapters: [] });
  if (path.endsWith("/codex-prompts")) return reply({ prompts: [] });
  if (path.endsWith("/visuals")) return reply({ visuals: [] });
  throw new Error(`Unexpected fixture request: ${path}`);
};

window.addEventListener("DOMContentLoaded", async () => {
  const check = (ok, message) => { if (!ok) throw new Error(message); qaFixture.checks++; };
  const settle = async () => { for (let i = 0; i < 100; i++) await Promise.resolve(); };
  const button = () => document.querySelector(".qa-repair-button");
  const panel = () => document.querySelector(".qa-repair-status");
  const panelButton = label => {
    const match = Array.from(panel().querySelectorAll("button")).find(node => node.textContent.trim() === label);
    if (!match) throw new Error(`The repair panel has no "${label}" button; it offers: ${Array.from(panel().querySelectorAll("button")).map(node => node.textContent.trim()).join(", ") || "none"}`);
    return match;
  };
  const reset = async () => {
    await settle();
    qaFixture.requests = []; qaFixture.posts = []; qaFixture.tests = 0;
    qaFixture.connected = false; qaFixture.testPass = true; qaFixture.postError = "";
    qaFixture.chatError = false; qaFixture.connectionWait = null; qaFixture.extraJob = false;
    qaFixture.job.qaSummary.status = "FAIL";
    qaRepairStates.clear(); aiRequestCache.clear(); aiPostProcessSignatures.clear();
    bookChatHasRunningRequests = false; codexAssistantAvailable = false; codexConnectionExpiresAt = 0;
    setFocusedJob(qaFixture.job.id); showView("active-book");
    await loadJobs({ force: true }); await settle();
    check(newBookView.hidden && !activeBookView.hidden, "Fixture must reproduce the hidden New book form");
  };
  const refreshChat = async () => { aiRequestCache.clear(); await loadBookChat({ force: true }); await settle(); };
  const start = async () => { button().click(); await settle(); };
  try {
    await reset();
    let release;
    qaFixture.connectionWait = new Promise(resolve => { release = resolve; });
    button().click();
    check(button().disabled && panel().textContent.includes("Checking the Codex connection"), "Click must immediately show visible connection progress");
    check(panel().getAttribute("role") === "status" && !panel().hidden, "Progress must be accessible beside the action");
    button().click();
    await startQaRepair(getSelectedBookChatJob());
    check(qaFixture.tests === 1 && qaFixture.posts.length === 0, "Double click must not submit a duplicate or skip preflight");
    release(); await settle();
    check(qaFixture.posts.length === 1, "Verified connection must launch one repair");
    const payload = qaFixture.posts[0];
    check(payload.requestKind === "QaRepair" && payload.chatSessionId === "fixture-session" && payload.allowEdits && !payload.includeHistory, "Repair must be tagged and bound to the current book conversation");
    check(button().disabled && panel().textContent.includes("QA repair is running"), "Accepted repair must stay disabled and visible");
    check(!panel().textContent.includes("Current automated QA: PASS"), "Starting cannot be labeled a QA pass");
    await loadJobs({ force: true }); await settle();
    check(button().disabled && panel().textContent.includes("repair-1"), "Refresh must retain running state and request ID");
    // Select by label. Picking the first button silently follows any change to
    // the panel's button order into whichever action happens to come first.
    panelButton("View repair conversation").click(); await settle();
    check(!bookChatPanel.hidden && bookChatThread.textContent.includes("Edits allowed"), "Conversation action must open the real request thread");
    qaFixture.chatError = true; await refreshChat();
    check(button().disabled && panel().textContent.includes("Cannot refresh repair progress"), "Polling errors must stay visible without enabling duplicate edits");
    qaFixture.chatError = false;
    Object.assign(qaFixture.requests[0], { status: "Failed", failureKind: "quota", statusDetail: "Workspace spending limit reached. Ask a workspace owner to increase the spend cap.", logPreview: "ERROR: spend cap" });
    await refreshChat();
    check(!button().disabled && panel().textContent.includes("spend cap") && panel().textContent.includes("Partial edits"), "Spend-cap failure and partial-edit warning must appear next to button");
    check(panel().querySelector("a").getAttribute("href") === "/fixture/error.log", "Failure must expose the request's full log");
    qaRepairStates.clear(); await loadJobs({ force: true }); await settle();
    check(panel().textContent.includes("spend cap"), "Stored repair failure must be recoverable after a reload");
    // A later full generation supersedes earlier repair outcomes.
    qaFixture.job.progress = { startedAt: new Date(Date.now() + 60 * 1000).toISOString() };
    await loadJobs({ force: true }); await settle();
    check(panel().hidden && !button().disabled, "Repairs from before the latest generation must not be shown");
    delete qaFixture.job.progress;
    qaRepairStates.clear(); await loadJobs({ force: true }); await settle();
    check(!panel().hidden && panel().textContent.includes("spend cap"), "Current-run repairs must still be shown");

    // Migrate the precise legacy request shape from the reported screenshot.
    delete qaFixture.requests[0].requestKind;
    qaRepairStates.clear(); await loadJobs({ force: true }); await settle();
    check(panel().textContent.includes("QA repair failed"), "Legacy QA requests must be recognized without the new tag");

    await reset(); qaFixture.testPass = false; await start();
    check(qaFixture.posts.length === 0 && !button().disabled && panel().textContent.includes("spending limit"), "Connection failure must prevent edits and explain the reason inline");
    await loadJobs({ force: true }); await settle();
    check(panel().textContent.includes("No repair request was started"), "Preflight failure must survive job refresh");

    await reset(); codexAssistantAvailable = true; codexConnectionExpiresAt = Date.now() - 1000;
    await start();
    check(qaFixture.tests === 1 && qaFixture.posts.length === 1, "An expired green connection must be retested");
    await reset(); codexAssistantAvailable = true; codexConnectionExpiresAt = Date.now() + 60000;
    await start();
    check(qaFixture.tests === 0 && qaFixture.posts.length === 1, "A current verified connection should not require a redundant test");

    await reset(); qaFixture.postError = "A request is already running for this book."; await start();
    check(panel().textContent.includes("already running") && !button().disabled, "Server rejection must be visible in Current work");
    await reset(); bookChatHasRunningRequests = true; await start();
    check(qaFixture.posts.length === 0 && panel().textContent.includes("already busy"), "An active chat request must block a concurrent QA edit");

    await reset(); qaFixture.connectionWait = new Promise(resolve => { release = resolve; });
    button().click();
    // A real switch: the designer opens another book from the library while the check runs.
    qaFixture.extraJob = true; setFocusedJob("other-book"); await loadJobs({ force: true }); await settle();
    release(); await settle();
    check(qaFixture.posts.length === 0, "Changing books during preflight must never edit the wrong book");
    qaFixture.extraJob = false; setFocusedJob(qaFixture.job.id); await loadJobs({ force: true }); await settle();
    check(panel().textContent.includes("selected book changed") && !button().disabled, "Returning to the original book must explain why its repair did not start");

    await reset(); await start();
    Object.assign(qaFixture.requests[0], { status: "Completed", postProcessStatus: "Package rebuild failed after edit-mode Codex request: export error" });
    await refreshChat();
    check(panel().textContent.includes("exports were not rebuilt successfully"), "A final response cannot hide an export rebuild failure");
    const twentyMinutesAgo = new Date(Date.now() - 20 * 60 * 1000).toISOString();
    Object.assign(qaFixture.requests[0], { postProcessStatus: "Package rebuild queued after edit-mode Codex request.", completedAt: twentyMinutesAgo, postProcessedAt: twentyMinutesAgo });
    await refreshChat();
    check(!button().disabled && panel().textContent.includes("was not confirmed"), "A stale queued rebuild must not keep Fix QA disabled");
    Object.assign(qaFixture.requests[0], { postProcessStatus: "", failureKind: "sandbox", statusDetail: "Codex ran with read-only file access instead of workspace-write, so it could not save any changes." });
    await refreshChat();
    check(!button().disabled && panel().textContent.includes("read-only file access"), "A read-only Codex session must be shown as a failed repair");
    Object.assign(qaFixture.requests[0], { failureKind: "", statusDetail: "" });
    qaFixture.requests[0].postProcessStatus = "Package rebuilt after edit-mode Codex request.";
    await refreshChat();
    check(panel().textContent.includes("current QA is FAIL") && !panel().textContent.includes("Current automated QA: PASS"), "Completed repair with failing gates must not claim success");
    qaFixture.job.qaSummary.status = "PASS";
    await loadJobs({ force: true }); await settle();
    check(!button() && panel().textContent.includes("Current automated QA: PASS") && panel().textContent.includes("Human review"), "Passing gates must preserve the visible result and human-approval boundary");

    // A Codex run that hangs otherwise blocks every action on the book,
    // deletion included, so a running repair must be stoppable from here.
    await reset(); await start();
    check(!panelButton("Stop Codex request").disabled, "A running repair must offer a way to stop it");
    // The fixture numbers requests across the whole run, so read the id rather
    // than assuming this is the first repair.
    const runningId = qaFixture.requests[0].id;
    qaFixture.confirms = []; qaFixture.confirmAnswer = false;
    panelButton("Stop Codex request").click(); await settle();
    check(qaFixture.confirms.length === 1, "Stopping a Codex request must ask before acting");
    check(qaFixture.stopped.length === 0 && !panelButton("Stop Codex request").disabled, "Declining the confirmation must leave the request running");
    qaFixture.confirmAnswer = true;
    panelButton("Stop Codex request").click(); await settle();
    check(qaFixture.stopped.length === 1 && qaFixture.stopped[0] === runningId, `Confirming must stop the running request ${runningId}, but stopped: ${qaFixture.stopped.join(", ") || "nothing"}`);
    check(!button().disabled, "A stopped repair must release the book for another attempt");

    // Finish with a realistic failure state for the saved visual review screenshot.
    await reset(); await start();
    Object.assign(qaFixture.requests[0], { status: "Failed", failureKind: "quota", statusDetail: "Codex reached the workspace spending limit. Ask a workspace owner to increase the spend cap, then Test connection.", logPreview: "ERROR: You hit your spend cap set by the owner of your workspace." });
    await refreshChat();
    check(qaFixture.errors.length === 0, `Browser errors: ${qaFixture.errors.join(" | ")}`);
    document.querySelector(".active-job-panel").scrollIntoView();
    document.getElementById("test-result").textContent = `PASS: ${qaFixture.checks} full-app QA repair browser assertions; no real Codex or book edits`;
  } catch (error) {
    document.getElementById("test-result").textContent = `FAIL: ${error.stack}`;
  }
});
