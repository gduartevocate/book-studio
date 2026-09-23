const form = document.querySelector("#bookForm");
const formStatus = document.querySelector("#formStatus");
const generateButton = document.querySelector("#generateButton");
const refreshJobsButton = document.querySelector("#refreshJobs");
const importForm = document.querySelector("#importForm");
const importStatus = document.querySelector("#importStatus");
const importButton = document.querySelector("#importButton");
const refreshPackagesButton = document.querySelector("#refreshPackages");
const packageSelect = document.querySelector("#packageSelect");
const packageMeta = document.querySelector("#packageMeta");
const packageZipInput = document.querySelector("#packageZipInput");
const importZipButton = document.querySelector("#importZipButton");
const appVersion = document.querySelector("#appVersion");
const refreshCodexButton = document.querySelector("#refreshCodex");
const codexStatus = document.querySelector("#codexStatus");
const codexPathForm = document.querySelector("#codexPathForm");
const codexPathInput = document.querySelector("#codexPathInput");
const saveCodexPath = document.querySelector("#saveCodexPath");
const clearCodexPath = document.querySelector("#clearCodexPath");
const codexPathStatus = document.querySelector("#codexPathStatus");
const codexLoginCommand = document.querySelector("#codexLoginCommand");
const codexAppCommand = document.querySelector("#codexAppCommand");
const codexNotes = document.querySelector("#codexNotes");
const booksButton = document.querySelector("#booksButton");
const newBookButton = document.querySelector("#newBookButton");
const settingsButton = document.querySelector("#settingsButton");
const libraryNewBook = document.querySelector("#libraryNewBook");
const homeNewBook = document.querySelector("#homeNewBook");
const homeImportBook = document.querySelector("#homeImportBook");
const cancelNewBook = document.querySelector("#cancelNewBook");
const activeBookBack = document.querySelector("#activeBookBack");
const settingsBack = document.querySelector("#settingsBack");
const booksHome = document.querySelector("#booksHome");
const newBookView = document.querySelector("#newBookView");
const activeBookView = document.querySelector("#activeBookView");
const settingsView = document.querySelector("#settingsView");
const bookList = document.querySelector("#bookList");
const bookListEmpty = document.querySelector("#bookListEmpty");
const bookCount = document.querySelector("#bookCount");
const activeBookTitle = document.querySelector("#activeBookTitle");
const activeBookStage = document.querySelector("#activeBookStage");
const activeBookMeta = document.querySelector("#activeBookMeta");
const activeBookAction = document.querySelector("#activeBookAction");
const activeBookProgress = document.querySelector("#activeBookProgress");
const bookChatPanel = document.querySelector("#bookChatPanel");
const newBookBack = document.querySelector("#newBookBack");
const newBookNext = document.querySelector("#newBookNext");
const wizardStepLabel = document.querySelector("#wizardStepLabel");
const bookChatForm = document.querySelector("#bookChatForm");
const bookChatJobSelect = document.querySelector("#bookChatJobSelect");
const bookChatScopeSelect = document.querySelector("#bookChatScopeSelect");
const bookChatMessage = document.querySelector("#bookChatMessage");
const bookChatAllowEdits = document.querySelector("#bookChatAllowEdits");
const bookChatSend = document.querySelector("#bookChatSend");
const bookChatStatus = document.querySelector("#bookChatStatus");
const bookChatThread = document.querySelector("#bookChatThread");
const bookChatNew = document.querySelector("#bookChatNew");
const bookChatConnectionStatus = document.querySelector("#bookChatConnectionStatus");
const bookChatTestConnection = document.querySelector("#bookChatTestConnection");
const jobsList = document.querySelector("#jobsList");
const jobCount = document.querySelector("#bookCount");
const jobTemplate = document.querySelector("#jobTemplate");

const activeStatuses = new Set(["Queued", "Running"]);
const activeAiRequestStatuses = new Set(["queued", "running"]);
const focusedJobStorageKey = "bookStudioFocusedJobId";
const visualManifestCache = new Map();
const codexPromptCache = new Map();
const chapterManifestCache = new Map();
const aiRequestCache = new Map();
const aiPostProcessSignatures = new Map();
const qaRepairStates = new Map();
const renderedJobSignatures = new Map();
let availablePackages = [];
let allJobs = [];
let currentJobs = [];
let focusedJobId = localStorage.getItem(focusedJobStorageKey) || "";
let selectedBookChatJobId = focusedJobId;
let renderedBookChatOptionsSignature = "";
let renderedBookChatThreadSignature = "";
let codexAssistantAvailable = false;
let lastObservedAuthFailure = "";
let bookChatHasRunningRequests = false;
let bookChatSubmissionPending = false;
let bookChatResetPending = false;
let chatLoadGeneration = 0;
let codexConnectionTestPending = false;
let codexConnectionExpiresAt = 0;
let codexConnectionTestedAt = "";
let codexConnectionMessage = "Check the connection before sending.";
const bookChatSessions = new Map();
let currentView = "books";
let wizardStep = 1;
const visualReviewStatuses = ["Not reviewed", "Approved", "Needs revision", "Regenerate"];
const chapterReviewStatuses = ["Not reviewed", "In ID review", "Needs revision", "Approved for SME", "Approved"];
const workflowSteps = [
  { id: "intake", label: "Set up book" },
  { id: "format-review", label: "Review format" },
  { id: "generating", label: "Generate book" },
  { id: "id-review", label: "ID review" },
  { id: "sme-review", label: "SME handoff" },
  { id: "delivery", label: "Delivery" }
];

function setStatus(message) {
  formStatus.textContent = message || "";
}

function setImportStatus(message) {
  importStatus.textContent = message || "";
}

function showView(view) {
  currentView = view;
  booksHome.hidden = view !== "books";
  newBookView.hidden = view !== "new-book";
  activeBookView.hidden = view !== "active-book";
  settingsView.hidden = view !== "settings";
}

function bookLabel(job) {
  return `${job.courseCode ? `${job.courseCode}: ` : ""}${job.title || "Untitled book"}`;
}

function workflowStageLabel(job) {
  const stage = getWorkflowStage(job);
  if (stage === "outcomes-analysis") return "Outcome review";
  if (stage === "format-review") return "Format review";
  if (stage === "generating" || isJobProcessing(job)) return "Generating book";
  if (stage === "sme-review") return "SME handoff";
  if (stage === "generation-failed" || job.status === "Failed") return "Needs attention";
  return "Instructional designer review";
}

function renderBookLibrary(jobs) {
  const books = Array.isArray(jobs) ? [...jobs] : [];
  books.sort((a, b) => new Date(b.updatedAt || b.createdAt || 0) - new Date(a.updatedAt || a.createdAt || 0));
  bookList.textContent = "";
  bookListEmpty.hidden = books.length > 0;
  bookCount.textContent = books.length ? `${books.length}` : "";

  for (const job of books) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `book-list-item${job.id === focusedJobId && currentView === "active-book" ? " selected" : ""}`;
    button.addEventListener("click", () => {
      setFocusedJob(job.id);
      showView("active-book");
      loadJobs({ force: true, focusJobId: job.id }).catch((error) => setStatus(error.message));
    });
    const title = makeElement("strong", "book-list-title", bookLabel(job));
    const stage = makeElement("span", `book-list-stage ${String(job.status || "").toLowerCase()}`, workflowStageLabel(job));
    const next = makeElement("span", "book-list-next", getWorkflowStatus(job));
    button.append(title, stage, next);
    bookList.append(button);
  }
}

function scrollToCurrentWork() {
  document.querySelector(".active-job-panel")?.scrollIntoView({ behavior: "smooth", block: "start" });
}

function scrollToChapterEditor() {
  const panel = document.querySelector(".chapter-panel:not([hidden])");
  if (!panel) {
    setStatus("The chapter editor is still loading. Try again in a moment.");
    window.setTimeout(() => {
      const retryPanel = document.querySelector(".chapter-panel:not([hidden])");
      if (retryPanel) retryPanel.scrollIntoView({ behavior: "smooth", block: "start" });
    }, 700);
    return;
  }
  panel.scrollIntoView({ behavior: "smooth", block: "start" });
  const firstEditor = panel.querySelector("details.chapter-editor");
  if (firstEditor) firstEditor.open = true;
}

function renderActiveBookHeader(job) {
  if (!job) return;
  activeBookTitle.textContent = bookLabel(job);
  activeBookStage.textContent = workflowStageLabel(job);
  activeBookMeta.textContent = `${getWorkflowStatus(job)}${job.updatedAt ? ` · Updated ${formatDate(job.updatedAt)}` : ""}`;
  activeBookAction.textContent = "";

  const action = document.createElement("button");
  action.type = "button";
  if (isJobProcessing(job)) {
    action.textContent = "Generation in progress";
    action.disabled = true;
  } else if (getWorkflowStage(job) === "outcomes-analysis") {
    action.textContent = "Review course outcomes";
    action.addEventListener("click", scrollToCurrentWork);
  } else if (getWorkflowStage(job) === "format-review") {
    action.textContent = "Review format preview";
    action.addEventListener("click", scrollToCurrentWork);
  } else if (job.status === "Queued") {
    action.textContent = "Continue generation";
    action.addEventListener("click", () => runJob(job.id, getWorkflowRunMode(job)).catch((error) => reportJobActionError(job, error.message)));
  } else if (job.status === "Failed") {
    action.textContent = "Retry step";
    action.addEventListener("click", () => runJob(job.id, getWorkflowRunMode(job)).catch((error) => reportJobActionError(job, error.message)));
  } else {
    action.textContent = "Continue review";
    action.addEventListener("click", scrollToCurrentWork);
  }
  activeBookAction.append(action);
  if (job.status === "Completed" && job.outputFolder && getWorkflowStage(job) !== "format-review") {
    const edit = document.createElement("button");
    edit.type = "button";
    edit.className = "secondary";
    edit.textContent = "Edit book content";
    edit.title = "Open the chapter editor for direct edits to the book source";
    edit.addEventListener("click", scrollToChapterEditor);
    activeBookAction.append(edit);
  }
  activeBookProgress.textContent = "";
  renderWorkflowPanel(activeBookProgress, job);
}

function isScrolledNearBottom(element) {
  return element.scrollHeight - element.scrollTop - element.clientHeight < 80;
}

function scrollToBottom(element) {
  requestAnimationFrame(() => {
    element.scrollTop = element.scrollHeight;
  });
}

function readFileAsBase64(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const result = String(reader.result || "");
      const commaIndex = result.indexOf(",");
      resolve(commaIndex >= 0 ? result.slice(commaIndex + 1) : result);
    };
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}

// Said once, at the top of the page, when Book Studio reached through the web
// can no longer reach the book: the session ended, or the computer writing the
// books stopped answering. The refresh loop swallows its own failures, so
// without this a designer watched a page that had quietly stopped updating --
// "last run 8:45" at 8:55 -- while the book itself was working the whole time.
const connectionNotices = new Set();
function showConnectionNotice(kind) {
  if (connectionNotices.has(kind)) return;
  connectionNotices.add(kind);
  const banner = document.createElement("div");
  banner.className = "connection-notice";
  banner.setAttribute("role", "alert");
  const text = document.createElement("span");
  const action = document.createElement("a");
  if (kind === "signed-out") {
    text.textContent = "You have been signed out, so this page has stopped updating. Your books carry on regardless. ";
    action.href = "/cloud/login?next=" + encodeURIComponent(location.pathname + location.search);
    action.textContent = "Sign in again";
  } else {
    text.textContent = "Book Studio on your computer is not answering, so this page has stopped updating. ";
    action.href = "/cloud/connect";
    action.textContent = "Check your computer";
  }
  banner.append(text, action);
  document.body.prepend(banner);
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "content-type": "application/json" },
    ...options
  });

  if (!response.ok && reachedThroughTheCloud()) {
    if (response.status === 401) showConnectionNotice("signed-out");
    if (response.status === 503 || response.status === 504) showConnectionNotice("machine");
  }

  if (!response.ok) {
    const message = await response.text();
    throw new Error(message || `Request failed: ${response.status}`);
  }

  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

function formatDate(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString();
}

function formatBytes(value) {
  const bytes = Number(value || 0);
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function lastLogLine(job) {
  const entries = Array.isArray(job.log) ? job.log : [];
  if (!entries.length) return "";
  const last = entries[entries.length - 1];
  return `${formatDate(last.at)} - ${last.message}`;
}

function formatElapsedSince(value) {
  if (!value) return "";
  const start = new Date(value);
  if (Number.isNaN(start.getTime())) return "";
  const seconds = Math.max(0, Math.floor((Date.now() - start.getTime()) / 1000));
  const minutes = Math.floor(seconds / 60);
  const remainingSeconds = seconds % 60;
  if (minutes < 1) return `${remainingSeconds}s`;
  const hours = Math.floor(minutes / 60);
  const remainingMinutes = minutes % 60;
  if (hours < 1) return `${minutes}m ${remainingSeconds}s`;
  return `${hours}h ${remainingMinutes}m`;
}

function formatAiElapsed(request) {
  if (!request?.createdAt) return "";
  const start = new Date(request.createdAt);
  if (Number.isNaN(start.getTime())) return "";
  const end = request.completedAt ? new Date(request.completedAt) : new Date();
  const endTime = Number.isNaN(end.getTime()) ? Date.now() : end.getTime();
  const seconds = Math.max(0, Math.floor((endTime - start.getTime()) / 1000));
  const minutes = Math.floor(seconds / 60);
  const remainingSeconds = seconds % 60;
  if (minutes < 1) return `${remainingSeconds}s`;
  const hours = Math.floor(minutes / 60);
  const remainingMinutes = minutes % 60;
  if (hours < 1) return `${minutes}m ${remainingSeconds}s`;
  return `${hours}h ${remainingMinutes}m`;
}

function formatShortTime(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

function renderAiProgressCard(request, elapsed) {
  const card = makeElement("div", "ai-progress-card");
  const heading = makeElement("div", "ai-progress-heading");
  heading.append(
    makeElement("span", "ai-progress-pulse", ""),
    makeElement("strong", "", request.currentAction || request.statusDetail || "Codex is working on this request.")
  );
  card.append(heading);

  const facts = makeElement("div", "ai-progress-facts");
  if (elapsed) facts.append(makeElement("span", "", `Elapsed ${elapsed}`));
  const lastActivity = formatShortTime(request.lastActivityAt);
  if (lastActivity) facts.append(makeElement("span", "", `Last activity ${lastActivity}`));
  facts.append(makeElement("span", "", request.allowEdits ? "May edit package files" : "Advice only"));
  card.append(facts);

  if (request.latestActivity) {
    const latest = makeElement("div", "ai-progress-latest");
    latest.append(makeElement("span", "", "Latest"), makeElement("p", "", request.latestActivity));
    card.append(latest);
  }

  if (request.nextExpectation) {
    card.append(makeElement("p", "ai-progress-note", request.nextExpectation));
  }
  return card;
}

function recentProgressEntries(job) {
  const progressEntries = Array.isArray(job.progress?.recent) ? job.progress.recent : [];
  if (progressEntries.length) return progressEntries.slice(-10);
  const logEntries = Array.isArray(job.log) ? job.log : [];
  return logEntries.slice(-10).map((entry) => ({
    at: entry.at,
    phase: "",
    detail: entry.message || "",
    level: "Info"
  }));
}

function isJobProcessing(job) {
  // A book sitting at a review stage with no runner process is not generating
  // anything, whatever its stored status says. It is waiting for a person.
  // Calling it busy hides the very button that would move it on, disables the
  // header action, and forces a re-render on every poll.
  const reviewStages = ["outcomes-analysis", "format-review"];
  if (reviewStages.includes(String(job?.workflowStage || "")) && !job?.runnerProcessId) return false;
  return activeStatuses.has(job.status);
}

function getWorkflowStage(job) {
  if (job?.lifecycleStatus === "Official") return "delivery";
  if (job?.workflowStage) return String(job.workflowStage);
  if (job?.cloudReview?.reviewUrl) return "sme-review";
  if (activeStatuses.has(job?.status)) return "generating";
  if (job?.outputFolder) return "id-review";
  return "format-review";
}

function getWorkflowStatus(job) {
  if (job?.workflowStatus) return String(job.workflowStatus);
  const stage = getWorkflowStage(job);
  if (stage === "outcomes-analysis") return "Course outcomes need review before planning";
  if (stage === "format-review") return "Format preview required before generation";
  if (stage === "id-review") return "Book ready for instructional-designer review";
  if (stage === "delivery") return "Book marked official and ready for delivery";
  return job?.status || "Waiting";
}

function getWorkflowRunMode(job) {
  const stage = getWorkflowStage(job);
  return stage === "format-review" || stage === "outcomes-analysis" ? "Blueprint" : "Full";
}

// Live outline editors by job, so a Codex suggestion can be loaded into the fields.
const outlineEditors = new Map();

function parseSuggestedOutlineChanges(text) {
  // Codex ends a format-review reply with:
  //   SUGGESTED OUTLINE CHANGES / Chapter N title|focus|guidance: ... / END SUGGESTED OUTLINE CHANGES
  const match = /SUGGESTED OUTLINE CHANGES\s*\r?\n([\s\S]*?)(?:\r?\nEND SUGGESTED OUTLINE CHANGES|$)/i.exec(text || "");
  if (!match) return [];
  const changes = [];
  let current = null;
  for (const rawLine of match[1].split(/\r?\n/)) {
    const line = rawLine.replace(/^[-*\s]+/, "").trim();
    const field = /^Chapter\s+(\d+)\s+(title|focus|guidance)\s*:\s*(.*)$/i.exec(line);
    if (field) {
      current = { number: Number(field[1]), field: field[2].toLowerCase(), value: field[3].trim() };
      changes.push(current);
    } else if (current && line && current.field === "guidance") {
      current.value = `${current.value} ${line}`.trim();
    }
  }
  return changes.filter((change) => change.value);
}

function applySuggestedOutlineChanges(jobId, changes) {
  const editor = outlineEditors.get(jobId);
  if (!editor || !editor.container.isConnected) return "Open this book's format review to load suggestions into the outline editor.";
  let applied = 0;
  for (const change of changes) {
    const field = editor.fields.find((entry) => entry.number === change.number);
    if (!field) continue;
    const input = change.field === "title" ? field.titleInput : change.field === "focus" ? field.focusInput : field.guidanceInput;
    input.value = change.value;
    input.classList.add("outline-suggested");
    applied += 1;
  }
  editor.status.textContent = applied
    ? `${applied} suggested change(s) loaded. Review them, then click Save outline & regenerate preview.`
    : "The suggestions did not match this book's chapters.";
  editor.container.scrollIntoView({ behavior: "smooth", block: "start" });
  return "";
}

async function applySuggestedOutlineChangesAndRegenerate(jobId, changes) {
  const editor = outlineEditors.get(jobId);
  if (!editor || !editor.container.isConnected) return "Open this book's format review to apply suggestions.";
  if (editor.save.disabled) return "An outline update is already in progress.";

  let applied = 0;
  for (const change of changes) {
    const field = editor.fields.find((entry) => entry.number === change.number);
    if (!field) continue;
    const input = change.field === "title" ? field.titleInput : change.field === "focus" ? field.focusInput : field.guidanceInput;
    input.value = change.value;
    input.classList.add("outline-suggested");
    applied += 1;
  }
  if (!applied) return "The suggestions did not match this book's chapters.";

  const chapters = editor.fields.map((field) => ({
    number: field.number,
    title: field.titleInput.value.trim(),
    focus: field.focusInput.value.trim(),
    guidance: field.guidanceInput.value.trim(),
    objectives: field.objectiveInput.value.split(/\r?\n/).map((value) => value.trim()).filter(Boolean)
  }));
  if (chapters.some((chapter) => !chapter.title || !chapter.focus || !chapter.objectives.length)) {
    return "Each chapter needs a title, focus, and source objectives.";
  }

  editor.save.disabled = true;
  editor.status.textContent = "Applying suggestions and rebuilding the complete preview...";
  try {
    await api(`/api/jobs/${jobId}/outline`, { method: "POST", body: JSON.stringify({ chapters, planHash: editor.planHash }) });
    editor.status.textContent = "Suggestions applied. Reloading the updated preview...";
    await loadJobs({ force: true, focusJobId: jobId });
    return "";
  } catch (error) {
    editor.save.disabled = false;
    editor.status.textContent = error.message;
    return error.message;
  }
}

function renderOutlineEditor(container, job, outline) {
  container.textContent = "";
  const heading = makeElement("div", "outline-editor-heading");
  heading.append(
    makeElement("div", "", "Edit the planned outline"),
    makeElement("span", "hint", "Changes regenerate the complete preview and clear any previous approval.")
  );
  container.append(heading);
  container.append(makeElement("p", "outline-editor-intro", "Edit chapter titles, focus, and writer guidance. Saving refreshes the browser preview and downloadable outlines/planning packets. Objectives remain unchanged unless you explicitly review and confirm a replacement below."));
  if (outline.lastUpdate?.message) { const receipt = makeElement("p", "outline-update-receipt", outline.lastUpdate.message); receipt.setAttribute("role", "status"); container.append(receipt); }

  const form = document.createElement("form");
  form.className = "outline-editor-form";
  const fields = [];
  for (const chapter of outline.chapters || []) {
    const card = document.createElement("fieldset");
    card.className = "outline-chapter-card";
    const legend = document.createElement("legend");
    legend.textContent = `Chapter ${chapter.number}`;
    card.append(legend);

    const titleLabel = document.createElement("label");
    titleLabel.append(makeElement("span", "", "Chapter title"));
    const titleInput = document.createElement("input");
    titleInput.type = "text";
    titleInput.value = chapter.title || "";
    titleInput.required = true;
    titleInput.maxLength = 180;
    titleLabel.append(titleInput);
    card.append(titleLabel);

    const focusLabel = document.createElement("label");
    focusLabel.append(makeElement("span", "", "Chapter focus"));
    const focusInput = document.createElement("input");
    focusInput.type = "text";
    focusInput.value = chapter.focus || "";
    focusInput.required = true;
    focusInput.maxLength = 2000;
    focusLabel.append(focusInput);
    card.append(focusLabel);

    const guidanceLabel = document.createElement("label");
    guidanceLabel.append(makeElement("span", "", "Guidance for the writer (optional)"));
    const guidanceInput = document.createElement("textarea");
    guidanceInput.rows = 3;
    guidanceInput.maxLength = 2000;
    guidanceInput.placeholder = "Emphasis, examples to use or avoid, tone, depth, terminology. Codex follows this while drafting; it is never printed in the book.";
    guidanceInput.value = chapter.guidance || "";
    guidanceLabel.append(guidanceInput);
    card.append(guidanceLabel);

    const objectiveLabel = document.createElement("label");
    objectiveLabel.append(makeElement("span", "", "Source learning objectives (locked)"));
    const objectiveInput = document.createElement("textarea");
    objectiveInput.rows = Math.max(3, Math.min(8, (chapter.objectives || []).length + 1));
    objectiveInput.required = true;
    objectiveInput.readOnly = true;
    objectiveInput.value = (chapter.objectives || []).join("\n");
    objectiveLabel.append(objectiveInput);
    card.append(objectiveLabel);
    const objectiveHint = makeElement("span", "hint", "These official objectives must stay word-for-word aligned with the course source.");
    objectiveHint.id = `outline-objectives-help-${chapter.number}`;
    objectiveInput.setAttribute("aria-describedby", objectiveHint.id);
    card.append(objectiveHint);
    form.append(card);
    fields.push({ number: chapter.number, titleInput, focusInput, guidanceInput, objectiveInput });
  }

  const actions = makeElement("div", "outline-editor-actions");
  const save = document.createElement("button");
  save.type = "submit";
  save.textContent = "Save outline & regenerate preview";
  const status = makeElement("span", "outline-editor-status");
  actions.append(save, status);
  form.append(actions);
  container.append(form);
  const outcomeEditor = appendOutcomeReplacement(container, job, outline);
  outlineEditors.set(job.id, { fields, form, status, save, container, planHash: outline.planHash, outcomeEditor });

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const chapters = fields.map((field) => ({
      number: field.number,
      title: field.titleInput.value.trim(),
      focus: field.focusInput.value.trim(),
      guidance: field.guidanceInput.value.trim(),
      objectives: field.objectiveInput.value.split(/\r?\n/).map((value) => value.trim()).filter(Boolean)
    }));
    if (chapters.some((chapter) => !chapter.title || !chapter.focus || !chapter.objectives.length)) {
      status.textContent = "Each chapter needs a title, focus, and source objectives.";
      return;
    }
    save.disabled = true;
    status.textContent = "Saving and rebuilding the complete preview...";
    try {
      await api(`/api/jobs/${job.id}/outline`, { method: "POST", body: JSON.stringify({ chapters, planHash: outline.planHash }) });
      status.textContent = "Outline saved. Reloading the updated preview...";
      await loadJobs({ force: true, focusJobId: job.id });
    } catch (error) {
      status.textContent = error.message;
      save.disabled = false;
    }
  });
}

async function loadOutlineEditor(container, job) {
  container.textContent = "";
  container.append(makeElement("p", "outline-editor-loading", "Loading the current planned outline..."));
  try {
    const outline = await api(`/api/jobs/${job.id}/outline`);
    renderOutlineEditor(container, job, outline);
  } catch (error) {
    container.textContent = "";
    container.append(makeElement("p", "outline-editor-error", `The outline editor could not load: ${error.message}`));
  }
}

function renderWorkflowPanel(container, job) {
  container.textContent = "";
  const stage = getWorkflowStage(job);
  const activeIndex = Math.max(0, workflowSteps.findIndex((step) => step.id === stage));
  const heading = makeElement("div", "workflow-heading");
  heading.append(
    makeElement("strong", "", getWorkflowStatus(job)),
    makeElement("span", "workflow-next", stage === "format-review" ? "Next: approve the format preview" : stage === "id-review" ? "Next: review the generated book" : "")
  );
  container.append(heading);

  const list = makeElement("ol", "workflow-steps");
  workflowSteps.forEach((step, index) => {
    const item = makeElement("li", "workflow-step");
    if (index < activeIndex || (step.id === "sme-review" && stage === "sme-review")) item.classList.add("complete");
    if (index === activeIndex) item.classList.add("current");
    if (stage === "generation-failed" && index === 1) item.classList.add("failed");
    item.append(makeElement("span", "workflow-step-number", String(index + 1)), makeElement("span", "workflow-step-label", step.label));
    list.append(item);
  });
  container.append(list);
}

function renderFormatReviewPanel(job, panel) {
  panel.textContent = "";
  const stage = getWorkflowStage(job);
  const formatChanged = job.formatReview?.required && (job.formatState?.needsRefresh || job.formatReview?.fingerprint !== job.formatState?.fingerprint);
  if (!job.outputFolder || activeStatuses.has(job.status) || (stage !== "format-review" && !formatChanged)) {
    panel.hidden = true;
    return;
  }

  panel.hidden = false;
  const heading = makeElement("div", "format-review-heading");
  const headingText = makeElement("div");
  headingText.append(makeElement("h3", "", "Step 1 · Review the book format"));
  headingText.append(makeElement("p", "panel-intro", "This preview shows the complete planned book. Confirm the chapter sequence, objectives, reading layout, hierarchy, and visual treatment before generation.") );
  const status = makeElement("span", job.formatReview?.status === "Needs revision" ? "visual-status warning" : "visual-status", job.formatReview?.status || "Not reviewed");
  heading.append(headingText, status);
  panel.append(heading);

  const guidance = makeElement("div", "format-review-guidance");
  guidance.append(
    makeElement("strong", "", "What happens next"),
    makeElement("span", "", "Edit chapter titles and focus below, then save to regenerate this complete-book preview. Official learning objectives remain locked to the course source for traceability. Ask Codex for recommendations if you are unsure. When the preview is right, confirm the review checkbox and approve it to generate the full manuscript. Direct chapter prose editing becomes available after generation.")
  );
  panel.append(guidance);

  if (job.intake) {
    panel.append(makeElement("p", "panel-intro", `Source intake: ${job.intake.readFiles}/${job.intake.uploadedFiles} files read without truncation. Blueprint: ${job.intake.primarySource}. ${job.options?.sourceMode === "UploadedOnly" ? "Uploaded documents only; no additional reading search." : job.options?.sourceMode === "Assigned" ? "Required reading URLs only; review their chapter assignments and retrieval results under Sources and image setting." : "External source discovery enabled."} Academic coverage still requires review.`));
  }

  const outlineEditor = makeElement("section", "outline-editor-panel");
  outlineEditor.setAttribute("aria-label", "Edit planned outline");
  panel.append(outlineEditor);
  loadOutlineEditor(outlineEditor, job);

  const previewFrame = document.createElement("iframe");
  previewFrame.className = "format-preview-frame";
  previewFrame.title = "Book format preview";
  previewFrame.loading = "lazy";
  previewFrame.src = `/api/jobs/${job.id}/asset?path=${encodeURIComponent("book-format-preview.html")}&v=${encodeURIComponent(job.formatState?.fingerprint || "")}`;
  panel.append(previewFrame);

  const links = makeElement("div", "format-review-links");
  const open = document.createElement("a");
  open.href = previewFrame.src;
  open.target = "_blank";
  open.rel = "noreferrer";
  open.textContent = "Open preview in a new tab";
  links.append(open);
  panel.append(links);

  const layoutLabel = document.createElement("label");
  layoutLabel.append(makeElement("span", "", "Book layout"));
  const layout = document.createElement("select");
  layout.setAttribute("aria-label", "Book layout");
  for (const [value, label] of [["standard", "Approved standard — Aptos 12 pt"], ["large-text", "Larger text — Aptos 14 pt"]]) {
    const option = document.createElement("option"); option.value = value; option.textContent = label; layout.append(option);
  }
  layout.value = job.formatState?.layout || "standard";
  layoutLabel.append(layout);
  panel.append(layoutLabel);

  const notesLabel = document.createElement("label");
  notesLabel.className = "format-review-notes";
  notesLabel.append(makeElement("span", "", "Additional requests (notes do not change the layout automatically)"));
  const notes = document.createElement("textarea");
  notes.value = job.formatReview?.notes || "";
  notes.placeholder = "Record requests not covered by the layout options. Resolve or withdraw them before approval.";
  notesLabel.append(notes);
  panel.append(notesLabel);
  const resolutionLabel = document.createElement("label");
  const resolution = document.createElement("input"); resolution.type = "checkbox";
  resolutionLabel.append(resolution, document.createTextNode(" I reviewed the preview; additional requests are resolved or withdrawn."));
  panel.append(resolutionLabel);

  const actions = makeElement("div", "format-review-actions");
  const requestChanges = document.createElement("button");
  requestChanges.type = "button";
  requestChanges.className = "secondary";
  requestChanges.textContent = "Save changes & update preview";
  const askCodex = document.createElement("button");
  askCodex.type = "button";
  askCodex.className = "secondary";
  askCodex.textContent = "Ask Codex about this format";
  const approve = document.createElement("button");
  approve.type = "button";
  approve.textContent = "Approve format & generate book";
  const actionStatus = makeElement("span", "format-review-status");
  actions.append(requestChanges, askCodex, approve, actionStatus);
  panel.append(actions);

  const submitReview = async (action, button, successText) => {
    const noteText = notes.value.trim();
    if (action === "approve" && !resolution.checked) {
      actionStatus.textContent = "Review the preview and confirm the checkbox before approval.";
      return;
    }
    requestChanges.disabled = true;
    approve.disabled = true;
    askCodex.disabled = true;
    button.textContent = action === "approve" ? "Starting generation..." : "Saving...";
    actionStatus.textContent = "";
    try {
      await api(`/api/jobs/${job.id}/format-review`, {
        method: "POST",
        body: JSON.stringify({ action, notes: noteText, reviewedBy: "Instructional Designer", layout: layout.value, previewFingerprint: job.formatState?.fingerprint, notesResolved: resolution.checked })
      });
      actionStatus.textContent = successText;
      await loadJobs({ force: true, focusJobId: job.id });
    } catch (error) {
      actionStatus.textContent = error.message;
    } finally {
      requestChanges.disabled = false;
      approve.disabled = false;
      askCodex.disabled = false;
      requestChanges.textContent = "Save changes & update preview";
      approve.textContent = "Approve format & generate book";
    }
  };

  requestChanges.addEventListener("click", () => submitReview("request-changes", requestChanges, "Layout applied. Review the updated preview; additional notes still require resolution."));
  approve.addEventListener("click", () => submitReview("approve", approve, "Format approved. Full generation is starting."));
  askCodex.addEventListener("click", () => {
    selectedBookChatJobId = job.id;
    renderBookChatJobOptions();
    bookChatJobSelect.value = job.id;
    bookChatMessage.value = "Review this format preview against the current Book Studio publication requirements. Explain any concerns and recommend precise changes.\n\nDesigner notes:\n" + notes.value.trim();
    bookChatPanel.hidden = false;
    loadBookChat({ job, refreshScope: true, showLoading: true, forceScroll: true }).catch((error) => {
      bookChatStatus.textContent = error.message;
    });
    bookChatPanel.scrollIntoView({ behavior: "smooth", block: "start" });
    bookChatMessage.focus();
    bookChatStatus.textContent = "Format question loaded into Ask Codex.";
  });
}

function isAiRequestActive(request) {
  return activeAiRequestStatuses.has(String(request?.status || "").toLowerCase());
}

function setFocusedJob(jobId) {
  focusedJobId = jobId || "";
  selectedBookChatJobId = focusedJobId;
  if (focusedJobId) {
    localStorage.setItem(focusedJobStorageKey, focusedJobId);
  } else {
    localStorage.removeItem(focusedJobStorageKey);
  }
  renderedBookChatOptionsSignature = "";
}

function getFocusedJobs(jobs, options = {}) {
  const sourceJobs = Array.isArray(jobs) ? jobs : [];
  if (!sourceJobs.length) {
    setFocusedJob("");
    return [];
  }

  if (options.focusJobId) {
    setFocusedJob(options.focusJobId);
  }

  const focused = focusedJobId
    ? sourceJobs.find((job) => job.id === focusedJobId)
    : null;
  if (focused) return [focused];

  setFocusedJob(sourceJobs[0].id);
  return [sourceJobs[0]];
}

function renderJobProgress(container, job) {
  container.textContent = "";

  const progress = job.progress || {};
  const isActive = isJobProcessing(job);
  const hasDetailedProgress = progress.phase || Array.isArray(progress.chapters) || Array.isArray(progress.errors);
  if (!isActive && job.status !== "Failed") {
    container.textContent = job.error ? job.error : lastLogLine(job);
    return;
  }

  if (!hasDetailedProgress) {
    container.textContent = job.error ? job.error : lastLogLine(job);
    return;
  }

  const panel = makeElement("div", `job-progress ${job.status === "Failed" ? "failed" : "active"}`);
  const header = makeElement("div", "job-progress-header");
  const phase = makeElement("div", "job-progress-phase", progress.phase || job.status || "Working");
  const elapsed = formatElapsedSince(progress.startedAt || job.createdAt);
  const metaText = [
    elapsed ? `Elapsed ${elapsed}` : "",
    progress.updatedAt ? `Updated ${formatDate(progress.updatedAt)}` : ""
  ].filter(Boolean).join(" | ");
  const meta = makeElement("div", "job-progress-meta", metaText);
  header.append(phase, meta);
  panel.append(header);

  if (progress.detail) {
    panel.append(makeElement("div", "job-progress-detail", progress.detail));
  }

  const errors = Array.isArray(progress.errors) ? progress.errors : [];
  if (errors.length || job.error) {
    const errorPanel = makeElement("div", "job-progress-errors");
    errorPanel.append(makeElement("strong", "", "Errors and warnings"));
    if (job.error) {
      errorPanel.append(makeElement("div", "", job.error));
    }
    for (const error of errors.slice(-5)) {
      const label = error.chapterNumber ? `Chapter ${error.chapterNumber}: ` : "";
      errorPanel.append(makeElement("div", "", `${label}${error.phase || "Error"} - ${error.detail || ""}`));
    }
    panel.append(errorPanel);
  }

  if (typeof progress.percent === "number") {
    const track = makeElement("div", "job-progress-track");
    const bar = makeElement("div", "job-progress-bar");
    bar.style.width = `${Math.max(0, Math.min(100, progress.percent))}%`;
    track.append(bar);
    panel.append(track);
  }

  const chapters = Array.isArray(progress.chapters) ? progress.chapters : [];
  if (chapters.length) {
    const chapterWrap = makeElement("div", "job-chapter-progress");
    chapterWrap.append(makeElement("div", "job-progress-subheading", "Chapter Progress"));
    // These cards only move while a step runs chapter by chapter. A whole-book
    // step such as Codex drafting leaves them on their last state, which reads
    // as if the chapters were already finished.
    const currentPhase = String(progress.phase || "");
    const reportedPhases = new Set(chapters.map((entry) => String(entry.phase || "")));
    if (isActive && currentPhase && !reportedPhases.has(currentPhase)) {
      chapterWrap.append(makeElement("p", "hint", `Each card shows that chapter's last completed step. ${currentPhase} works across the whole book and does not report chapter by chapter, so these will not change until it finishes.`));
    }
    const chapterGrid = makeElement("div", "job-chapter-grid");
    for (const chapter of chapters) {
      const statusKey = String(chapter.status || "Working").toLowerCase().replace(/\s+/g, "-");
      const card = makeElement("div", `job-chapter-card ${statusKey}`);
      const cardHead = makeElement("div", "job-chapter-card-head");
      cardHead.append(makeElement("strong", "", `Chapter ${chapter.chapterNumber}`));
      cardHead.append(makeElement("span", "", chapter.status || "Working"));
      card.append(cardHead);
      card.append(makeElement("div", "job-chapter-title", chapter.title || ""));
      card.append(makeElement("div", "job-chapter-phase", chapter.phase || ""));
      if (chapter.detail) {
        card.append(makeElement("div", "job-chapter-detail", chapter.detail));
      }
      chapterGrid.append(card);
    }
    chapterWrap.append(chapterGrid);
    panel.append(chapterWrap);
  }

  const entries = recentProgressEntries(job);
  if (entries.length) {
    const list = makeElement("div", "job-progress-list");
    for (const entry of entries) {
      const level = String(entry.level || "Info").toLowerCase();
      const row = makeElement("div", `job-progress-entry ${level}`);
      const time = makeElement("span", "job-progress-time", entry.at ? new Date(entry.at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) : "");
      const chapterPrefix = entry.chapterNumber ? `Chapter ${entry.chapterNumber} - ` : "";
      const text = makeElement("span", "", entry.phase ? `${chapterPrefix}${entry.phase}: ${entry.detail || ""}` : entry.detail || "");
      row.append(time, text);
      list.append(row);
    }
    panel.append(list);
  }

  container.append(panel);
}

function renderJobQaSummary(container, job) {
  const qa = job.qaSummary;
  if (job.qaReview) {
    const receipt = makeElement("p", "qa-review-result", `Last QA run: ${formatDate(job.qaReview.checkedAt)}. ${job.qaReview.message}`);
    receipt.setAttribute("role", "status");
    container.append(receipt);
  }
  if (!qa || !qa.status || qa.status === "Unknown") return;

  if (qa.stage === "outline") {
    const banner = makeElement("div", "qa-summary preview");
    banner.append(makeElement("strong", "", `Outline: ${qa.outlineStatus}`));
    banner.append(makeElement("span", "", qa.summary));
    for (const issue of qa.outlineIssues || []) banner.append(makeElement("span", "", issue));
    banner.append(makeElement("span", "", `Sources: ${qa.sourceReadiness?.status || "Not checked"}. ${qa.sourceReadiness?.detail || ""}`));
    banner.append(makeElement("span", "", "Book QA: not run yet. No manuscript has been generated; citations, images, and publication checks run later."));
    if (qa.sourceReadiness?.issues?.length) {
      const details = makeElement("details", "");
      details.append(makeElement("summary", "", `${qa.sourceReadiness.issues.length} source setup issue(s)`));
      const list = makeElement("ul", "");
      for (const issue of qa.sourceReadiness.issues) list.append(makeElement("li", "", issue));
      details.append(list); banner.append(details);
    }
    container.append(banner);
    return;
  }

  const status = String(qa.status).toUpperCase();
  const banner = makeElement("div", status === "PASS" ? "qa-summary pass" : "qa-summary fail");
  const label = status === "PASS"
    ? "QA PASS"
    : status === "WARNING"
      ? "QA WARNING"
      : qa.draftReadyForReview === true
        ? "Editorial review required"
        : "QA FAIL - Needs revision";
  const parts = [];
  if (qa.qualityStatus) parts.push(`Quality: ${qa.qualityStatus}`);
  if (qa.publishingStatus) parts.push(`Publishing: ${qa.publishingStatus}`);
  if (qa.auditStatus) parts.push(`Audit: ${qa.auditStatus}`);
  parts.push(status === "PASS" && qa.draftReadyForReview === true
    ? "Technical/editorial gates passed"
    : qa.draftReadyForReview === true
      ? "Complete book and exports ready for instructional-designer review"
      : "Draft not cleared by current gates");
  parts.push(qa.publicationReady === true ? "Publication approvals recorded" : "Not publication-approved: human approvals required");

  banner.append(makeElement("strong", "", label));
  if (parts.length) {
    banner.append(makeElement("span", "", parts.join(" | ")));
  }
  if (qa.summary && status !== "PASS") {
    banner.append(makeElement("span", "", qa.summary));
  }
  if (qa.findings?.length) {
    const details = makeElement("details", "");
    details.append(makeElement("summary", "", `${qa.findings.length} remaining QA findings (repair completion is not QA approval)`));
    const list = makeElement("ul", "");
    for (const finding of qa.findings) list.append(makeElement("li", "", `${finding.category}${finding.chapter ? ` / Chapter ${finding.chapter}` : ""}: ${finding.name} — ${finding.detail}`));
    details.append(list);
    banner.append(details);
  }
  container.append(banner);
}

function buildQaRepairInstruction(job) {
  const courseLabel = `${job.courseCode ? `${job.courseCode} ` : ""}${job.title || "this ebook"}`.trim();
  return `Fix the failed QA issues for ${courseLabel}.

Edit the learner-facing ebook package in place. This is not advice-only: revise the manuscript so QA can pass.

Required work:
- Inspect quality-report.md, publishing-editor-report.md, agent-report.md, ebook-output-audit.md, ebook-outline.md, ebook-planning-packet.md, sources.md, and the current E-Book Markdown.
- Revise all chapter Markdown/source files needed, and keep the main E-Book Markdown aligned with those revisions.
- Expand each chapter to at least 2,600 words where source context supports it; 3,200 words is preferred for a strong production draft.
- Follow the GM1000 format-only standard: Introduction and Learning Objectives first; four numbered sections for context, development, application, and integration. Include Opening Scenario, Business Case, Chapter Roadmap, Case Study Progression, Communication Toolbox, Practical Field Guide, Key Takeaways, Vocabulary Review, Looking Ahead (or final Conclusion), and Scholarly Sources in their prescribed order. Preserve this course's own weekly objectives and assigned sources.
- Do not include Knowledge Checks, Check Your Reasoning, Reflection Activity, Workplace Challenge, Chapter Summary, Think About It, quizzes, tests, or renamed assessment sections.
- Add a named **Business Case:** scenario in every chapter and carry that case through the chapter.
- Add modeled communication artifacts, field-guide/toolbox content, synthesis, key takeaways, clean numbered source notes, and applied workplace practice.
- Preserve relevant verified images and visuals. Remove local interactive-study links and promises of interactive activities from the learner-facing book.
- Remove learner-facing production residue, source-management notes, LMS language, and unclear numbered-note references.
- Keep claims grounded in available sources. Do not invent URLs, DOI values, or unsupported facts.
- If ebook-plan.json uses Assigned source mode, read every assigned source-readings text file. Ground the teaching in those readings, cite each assigned URL in its chapter's numbered Scholarly Sources, and link the relevant body claims to those notes. Never cite the blueprint, objectives, or production notes as scholarly evidence. Do not claim that listing a URL proves a claim is supported.

After editing, summarize exactly which files changed and which QA issues you addressed.`;
}

function makeElement(tagName, className, text) {
  const element = document.createElement(tagName);
  if (className) element.className = className;
  if (text) element.textContent = text;
  return element;
}

function assetStatusText(asset) {
  if (!asset?.relativePath) return "Not planned";
  if (!asset.exists) return "Missing";
  return `${formatBytes(asset.size)} ${asset.fileName ? `| ${asset.fileName}` : ""}`.trim();
}

function renderArtifactLinks(container, artifacts) {
  container.textContent = "";
  for (const artifact of artifacts || []) {
    const link = document.createElement("a");
    link.href = artifact.url;
    link.textContent = `${artifact.name} (${formatBytes(artifact.size)})`;
    container.append(link);
  }
}

function appendJobLogLinks(container, job) {
  if (!job?.logPath) return;
  const wrap = makeElement("div", "job-log-links");
  const stdout = document.createElement("a");
  stdout.href = `/api/jobs/${job.id}/log`;
  stdout.textContent = "Runner log";
  stdout.target = "_blank";
  const stderr = document.createElement("a");
  stderr.href = `/api/jobs/${job.id}/log?kind=stderr`;
  stderr.textContent = "Error log";
  stderr.target = "_blank";
  wrap.append(stdout, stderr);
  container.append(wrap);
}

function chapterAssetUrl(jobId, relativePath, download = true) {
  const route = download ? "asset/download" : "asset";
  return `/api/jobs/${jobId}/${route}?path=${encodeURIComponent(relativePath || "")}`;
}

function escapeHtml(value) {
  return String(value || "").replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "\"": "&quot;",
    "'": "&#39;"
  })[character]);
}

// Only addresses that lead somewhere: the web, an email, or a place in the
// book. A chapter link used to become <a href> with whatever the manuscript
// said, so [see this](javascript:...) ran script when clicked -- and reached
// through the web, this page shares a site with the cloud's account pages.
function isSafeLinkTarget(target) {
  const value = String(target || "").trim().replace(/&amp;/g, "&");
  return /^(https?:|mailto:|#|\/(?!\/))/i.test(value);
}

function inlineMarkdownToHtml(value) {
  return escapeHtml(value)
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, (match, text, target) => isSafeLinkTarget(target)
      ? `<a href="${target}" target="_blank" rel="noreferrer noopener">${text}</a>`
      : text);
}

function parseMarkdownTableRow(value) {
  const trimmed = String(value || "").trim();
  if (!trimmed.includes("|")) return null;
  const normalized = trimmed.replace(/^\|/, "").replace(/\|$/, "");
  const cells = normalized.split("|").map((cell) => cell.trim());
  return cells.length > 1 ? cells : null;
}

function isMarkdownTableSeparator(value) {
  const cells = parseMarkdownTableRow(value);
  return Boolean(cells?.length) && cells.every((cell) => /^:?-{3,}:?$/.test(cell));
}

function markdownTableToHtml(rows) {
  if (!rows.length) return "";
  const header = rows[0];
  const bodyRows = rows.slice(2);
  const head = `<thead><tr>${header.map((cell) => `<th>${inlineMarkdownToHtml(cell)}</th>`).join("")}</tr></thead>`;
  const body = bodyRows.length
    ? `<tbody>${bodyRows.map((row) => `<tr>${row.map((cell) => `<td>${inlineMarkdownToHtml(cell)}</td>`).join("")}</tr>`).join("")}</tbody>`
    : "";
  return `<div class="chapter-table-wrap"><table>${head}${body}</table></div>`;
}

function markdownToPreviewHtml(markdown, jobId = "") {
  const lines = String(markdown || "").split(/\r?\n/);
  const output = [];
  let list = null;
  let currentChapterNumber = 0;
  let currentSectionTitle = "";

  for (let lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    const line = lines[lineIndex];
    const trimmed = line.trim();
    if (!trimmed) {
      if (list) {
        output.push(`</${list}>`);
        list = null;
      }
      continue;
    }

    const image = trimmed.match(/^!\[([^\]]*)\]\(([^)]+)\)$/);
    if (image) {
      if (list) {
        output.push(`</${list}>`);
        list = null;
      }
      const originalSrc = image[2];
      const displaySrc = jobId && !/^(https?:|data:|\/)/i.test(originalSrc)
        ? chapterAssetUrl(jobId, originalSrc, false)
        : originalSrc;
      const figureClass = /\/?images\/chapter-\d+-.+-opener\.png$/i.test(originalSrc)
        ? "chapter-opener-figure"
        : "";
      output.push(`<figure${figureClass ? ` class="${figureClass}"` : ""}><img src="${escapeHtml(displaySrc)}" data-original-src="${escapeHtml(originalSrc)}" alt="${escapeHtml(image[1])}"></figure>`);
      continue;
    }

    const tableHeader = parseMarkdownTableRow(trimmed);
    const nextLine = lines[lineIndex + 1] || "";
    if (tableHeader && isMarkdownTableSeparator(nextLine)) {
      if (list) {
        output.push(`</${list}>`);
        list = null;
      }
      const tableRows = [tableHeader, parseMarkdownTableRow(nextLine)];
      lineIndex += 2;
      while (lineIndex < lines.length) {
        const row = parseMarkdownTableRow(lines[lineIndex]);
        if (!row || isMarkdownTableSeparator(lines[lineIndex])) {
          lineIndex--;
          break;
        }
        tableRows.push(row);
        lineIndex++;
      }
      output.push(markdownTableToHtml(tableRows));
      continue;
    }

    const heading = trimmed.match(/^(#{1,4})\s+(.+)$/);
    if (heading) {
      if (list) {
        output.push(`</${list}>`);
        list = null;
      }
      const level = Math.min(4, heading[1].length);
      const headingText = heading[2];
      const chapter = headingText.match(/^Chapter\s+(\d+)\s*:/i);
      if (level === 1 && chapter) currentChapterNumber = Number(chapter[1]);
      currentSectionTitle = headingText.trim();
      output.push(`<h${level}>${inlineMarkdownToHtml(headingText)}</h${level}>`);
      continue;
    }

    const bullet = trimmed.match(/^[-*]\s+(.+)$/);
    if (bullet) {
      if (list !== "ul") {
        if (list) output.push(`</${list}>`);
        output.push("<ul>");
        list = "ul";
      }
      output.push(`<li>${inlineMarkdownToHtml(bullet[1])}</li>`);
      continue;
    }

    const numbered = trimmed.match(/^\d+\.\s+(.+)$/);
    if (numbered) {
      if (list !== "ol") {
        if (list) output.push(`</${list}>`);
        output.push("<ol>");
        list = "ol";
      }
      const itemNumber = Number(trimmed.match(/^(\d+)\./)?.[1] || 0);
      const noteId = currentChapterNumber && /^(Notes|Scholarly Sources)$/.test(currentSectionTitle)
        ? ` id="chapter-${currentChapterNumber}-note-${itemNumber}"`
        : "";
      output.push(`<li${noteId}>${inlineMarkdownToHtml(numbered[1])}</li>`);
      continue;
    }

    if (list) {
      output.push(`</${list}>`);
      list = null;
    }
    output.push(`<p>${inlineMarkdownToHtml(trimmed)}</p>`);
  }

  if (list) output.push(`</${list}>`);
  return output.join("\n");
}

function openEditableLink(event) {
  const link = event.target?.closest?.("a[href]");
  if (!link) return;
  if (!(event.ctrlKey || event.metaKey || event.button === 1)) return;

  event.preventDefault();
  event.stopPropagation();
  const href = link.getAttribute("href") || "";
  if (!href || href.startsWith("#")) return;
  window.open(link.href, "_blank", "noopener,noreferrer");
}

function inlineDomToMarkdown(node) {
  if (node.nodeType === Node.TEXT_NODE) return node.textContent || "";
  if (node.nodeType !== Node.ELEMENT_NODE) return "";

  const tagName = node.tagName.toLowerCase();
  const text = Array.from(node.childNodes).map(inlineDomToMarkdown).join("");
  if (tagName === "strong" || tagName === "b") return `**${text}**`;
  if (tagName === "a") return `[${text}](${node.getAttribute("href") || ""})`;
  if (tagName === "br") return "\n";
  return text;
}

function tableDomToMarkdown(table) {
  const rows = Array.from(table.querySelectorAll("tr")).map((row) =>
    Array.from(row.children).map((cell) => inlineDomToMarkdown(cell).trim())
  ).filter((row) => row.length);
  if (!rows.length) return "";
  const header = rows[0];
  const separator = header.map(() => "---");
  return [header, separator, ...rows.slice(1)]
    .map((row) => `| ${row.join(" | ")} |`)
    .join("\n");
}

function blockDomToMarkdown(node) {
  if (node.nodeType === Node.TEXT_NODE) return (node.textContent || "").trim();
  if (node.nodeType !== Node.ELEMENT_NODE) return "";

  const tagName = node.tagName.toLowerCase();
  if (/^h[1-4]$/.test(tagName)) {
    return `${"#".repeat(Number(tagName.slice(1)))} ${inlineDomToMarkdown(node).trim()}`;
  }
  if (tagName === "p") {
    return inlineDomToMarkdown(node).trim();
  }
  if (tagName === "ul" || tagName === "ol") {
    return Array.from(node.children)
      .filter((child) => child.tagName?.toLowerCase() === "li")
      .map((child, index) => tagName === "ol"
        ? `${index + 1}. ${inlineDomToMarkdown(child).trim()}`
        : `- ${inlineDomToMarkdown(child).trim()}`)
      .join("\n");
  }
  if (tagName === "figure") {
    const image = node.querySelector("img");
    if (!image) return "";
    const alt = node.querySelector("figcaption")?.textContent || image.getAttribute("alt") || "";
    const src = image.dataset.originalSrc || image.getAttribute("src") || "";
    return `![${alt}](${src})`;
  }
  if (tagName === "img") {
    const alt = node.getAttribute("alt") || "";
    const src = node.dataset.originalSrc || node.getAttribute("src") || "";
    return `![${alt}](${src})`;
  }
  if (tagName === "table") {
    return tableDomToMarkdown(node);
  }
  if (tagName === "div") {
    const table = node.querySelector(":scope > table");
    if (table && node.classList.contains("chapter-table-wrap")) {
      return tableDomToMarkdown(table);
    }
    return Array.from(node.childNodes).map(blockDomToMarkdown).filter(Boolean).join("\n\n");
  }
  return inlineDomToMarkdown(node).trim();
}

function richEditorToMarkdown(editor) {
  return Array.from(editor.childNodes)
    .map(blockDomToMarkdown)
    .filter((block) => block && block.trim())
    .join("\n\n")
    .trimEnd() + "\n";
}

function shouldPauseJobAutoRefresh() {
  const active = document.activeElement;
  if (active === bookChatMessage && !bookChatMessage.value.trim()) {
    return false;
  }
  if (active && (["INPUT", "TEXTAREA", "SELECT"].includes(active.tagName) || active.isContentEditable)) {
    return true;
  }
  return Boolean(document.querySelector(".chapter-editor[open], .ai-log-preview[open], .ai-request-links[open], .codex-prompt-details[open], .visual-details[open], .chapter-source-details[open]"));
}

function shouldAutoRefreshJobs() {
  if (shouldPauseJobAutoRefresh()) return false;
  return currentJobs.some(isJobProcessing) || bookChatHasRunningRequests;
}

function renderAssetLink(container, asset, label) {
  const row = makeElement("div", "visual-asset-row");
  const name = makeElement("span", "visual-asset-name", label);
  const value = makeElement("span", asset?.exists ? "visual-asset-ok" : "visual-asset-missing", assetStatusText(asset));
  row.append(name, value);

  if (asset?.exists && asset.downloadUrl) {
    const link = document.createElement("a");
    link.href = asset.downloadUrl;
    link.textContent = "Open";
    row.append(link);
  }

  container.append(row);
}

function renderPromptBlock(chapter) {
  const details = document.createElement("details");
  details.className = "visual-details";

  const summary = document.createElement("summary");
  summary.textContent = "Prompts and descriptions";
  details.append(summary);

  const fields = [
    ["Opener prompt", chapter.openerPrompt],
    ["Opener alt text", chapter.opener?.altText],
    ["Study-aid purpose", chapter.learnerPurpose],
    ["Study-aid prompt", chapter.generationPrompt],
    ["Quick-check alt text", chapter.quickCheck?.altText],
    ["Interaction idea", chapter.interactionIdea]
  ];

  for (const [label, value] of fields) {
    if (!value) continue;
    const block = makeElement("div", "visual-prompt");
    block.append(makeElement("strong", "", label));
    block.append(makeElement("p", "", value));
    details.append(block);
  }

  return details;
}

function renderVisualReviewControls(chapter, manifest, panel) {
  const review = chapter.review || {};
  const box = makeElement("div", "visual-review-box");
  const header = makeElement("div", "visual-review-header");
  header.append(makeElement("strong", "", "Review"));
  const reviewMeta = makeElement("span", "", review.reviewedAt ? `Saved ${formatDate(review.reviewedAt)}` : "Not saved");
  header.append(reviewMeta);

  const controls = makeElement("div", "visual-review-controls");
  const statusLabel = makeElement("label", "visual-review-field");
  statusLabel.append(makeElement("span", "", "Status"));
  const statusSelect = document.createElement("select");
  for (const status of visualReviewStatuses) {
    const option = document.createElement("option");
    option.value = status;
    option.textContent = status;
    if ((review.status || "Not reviewed") === status) option.selected = true;
    statusSelect.append(option);
  }
  statusLabel.append(statusSelect);

  const notesLabel = makeElement("label", "visual-review-field notes");
  notesLabel.append(makeElement("span", "", "Notes"));
  const notes = document.createElement("textarea");
  notes.value = review.notes || "";
  notes.placeholder = "Visual approval notes, requested changes, or regeneration direction";
  notesLabel.append(notes);

  const saveRow = makeElement("div", "visual-review-save-row");
  const saveButton = document.createElement("button");
  saveButton.type = "button";
  saveButton.className = "secondary";
  saveButton.textContent = "Save Review";
  const saveStatus = makeElement("span", "visual-review-save-status");
  saveButton.addEventListener("click", async () => {
    saveButton.disabled = true;
    saveStatus.textContent = "Saving...";
    try {
      const result = await api(`/api/jobs/${manifest.jobId}/visual-reviews`, {
        method: "POST",
        body: JSON.stringify({
          chapterNumber: chapter.chapterNumber,
          status: statusSelect.value,
          notes: notes.value,
          reviewedBy: ""
        })
      });
      visualManifestCache.clear();
      codexPromptCache.clear();
      chapterManifestCache.clear();
      aiRequestCache.clear();
      saveStatus.textContent = "Saved. Report updated.";
      const jobForRefresh = { id: manifest.jobId, outputFolder: manifest.outputFolder, status: "Completed", updatedAt: String(Date.now()) };
      const jobRow = panel.closest(".job-row");
      const artifactList = jobRow?.querySelector(".artifact-list");
      if (artifactList && result.artifacts) {
        renderArtifactLinks(artifactList, result.artifacts);
      }
      await loadJobVisuals(jobForRefresh, panel);
      const codexPromptPanel = jobRow?.querySelector(".codex-prompt-panel");
      if (codexPromptPanel) {
        await loadJobCodexPrompts(jobForRefresh, codexPromptPanel);
      }
    } catch (error) {
      saveStatus.textContent = error.message;
    } finally {
      saveButton.disabled = false;
    }
  });
  saveRow.append(saveButton, saveStatus);
  controls.append(statusLabel, notesLabel, saveRow);
  box.append(header, controls);
  return box;
}

function renderOpenerReplacementControls(chapter, manifest, panel) {
  const box = makeElement("div", "visual-replacement-box");
  const label = makeElement("label", "visual-replacement-file");
  label.append(makeElement("span", "", "Replacement opener PNG"));

  const fileInput = document.createElement("input");
  fileInput.type = "file";
  fileInput.accept = "image/png";
  label.append(fileInput);

  const rebuildLabel = makeElement("label", "visual-replacement-check");
  const rebuildInput = document.createElement("input");
  rebuildInput.type = "checkbox";
  rebuildInput.checked = true;
  rebuildLabel.append(rebuildInput, makeElement("span", "", "Rebuild after upload"));

  const row = makeElement("div", "visual-replacement-row");
  const uploadButton = document.createElement("button");
  uploadButton.type = "button";
  uploadButton.className = "secondary";
  uploadButton.textContent = "Replace Opener";
  uploadButton.disabled = true;
  const uploadStatus = makeElement("span", "visual-replacement-status");

  fileInput.addEventListener("change", () => {
    uploadButton.disabled = !fileInput.files?.length;
    uploadStatus.textContent = fileInput.files?.length ? fileInput.files[0].name : "";
  });

  uploadButton.addEventListener("click", async () => {
    const file = fileInput.files?.[0];
    if (!file) return;

    uploadButton.disabled = true;
    uploadButton.textContent = rebuildInput.checked ? "Uploading and rebuilding..." : "Uploading...";
    uploadStatus.textContent = "";
    try {
      const contentBase64 = await readFileAsBase64(file);
      const result = await api(`/api/jobs/${manifest.jobId}/visuals/replacement`, {
        method: "POST",
        body: JSON.stringify({
          chapterNumber: chapter.chapterNumber,
          contentBase64,
          rebuild: rebuildInput.checked
        })
      });

      visualManifestCache.clear();
      codexPromptCache.clear();
      chapterManifestCache.clear();
      aiRequestCache.clear();
      const jobRow = panel.closest(".job-row");
      const artifactList = jobRow?.querySelector(".artifact-list");
      if (artifactList && result.artifacts) {
        renderArtifactLinks(artifactList, result.artifacts);
      }

      const refreshedJob = result.job || { id: manifest.jobId, outputFolder: manifest.outputFolder, status: "Completed", updatedAt: String(Date.now()) };
      await loadJobVisuals(refreshedJob, panel);
      const codexPromptPanel = jobRow?.querySelector(".codex-prompt-panel");
      if (codexPromptPanel) {
        await loadJobCodexPrompts(refreshedJob, codexPromptPanel);
      }
    } catch (error) {
      uploadStatus.textContent = error.message;
    } finally {
      uploadButton.disabled = !fileInput.files?.length;
      uploadButton.textContent = "Replace Opener";
    }
  });

  row.append(uploadButton, uploadStatus);
  box.append(label, rebuildLabel, row);
  return box;
}

function renderVisualPanel(panel, manifest, options = {}) {
  panel.textContent = "";
  panel.hidden = false;

  if (!options.hideHeading) {
    const heading = makeElement("div", "visual-heading");
    const title = makeElement("h3", "", "Visual Assets");
    const statusClass = manifest.status === "Ready" ? "visual-status" : "visual-status warning";
    const status = makeElement("span", statusClass, manifest.status || "Unknown");
    heading.append(title, status);
    panel.append(heading);
  }

  for (const warning of manifest.warnings || []) {
    panel.append(makeElement("div", "visual-warning", warning));
  }

  const summary = manifest.summary || {};
  panel.append(makeElement(
    "div",
    "visual-summary",
    `${summary.chapterCount || 0} chapter(s) | ${summary.openerCount || 0} opener image(s) | ${summary.studyAidCount || 0} study aid(s) | ${summary.quickCheckCount || 0} quick check(s)`
  ));

  if (!manifest.chapters?.length) {
    panel.append(makeElement("div", "empty-state compact", "No visual plan is available for this job yet."));
    return;
  }

  const list = makeElement("div", "visual-list");
  for (const chapter of manifest.chapters) {
    const item = makeElement("section", "visual-item");
    const media = makeElement("div", "visual-media");

    if (chapter.opener?.exists && chapter.opener.url) {
      const image = document.createElement("img");
      image.src = chapter.opener.url;
      image.alt = chapter.opener.altText || `Chapter ${chapter.chapterNumber} opener image`;
      image.loading = "lazy";
      media.append(image);
    } else {
      media.append(makeElement("div", "visual-missing-box", "Missing opener"));
    }

    const body = makeElement("div", "visual-body");
    body.append(makeElement("h4", "", `Chapter ${chapter.chapterNumber}: ${chapter.chapterTitle}`));

    const assets = makeElement("div", "visual-assets");
    renderAssetLink(assets, chapter.opener, "Opener PNG");
    renderAssetLink(assets, chapter.studyAid, "Study SVG");
    renderAssetLink(assets, chapter.quickCheck, "Quick check SVG");
    body.append(assets);
    body.append(renderOpenerReplacementControls(chapter, manifest, panel));

    for (const warning of chapter.warnings || []) {
      body.append(makeElement("div", "visual-warning", warning));
    }

    body.append(renderPromptBlock(chapter));
    body.append(renderVisualReviewControls(chapter, manifest, panel));
    item.append(media, body);
    list.append(item);
  }
  panel.append(list);

  if (manifest.extraAssets?.length) {
    const extras = makeElement("details", "visual-details extras");
    const extrasSummary = document.createElement("summary");
    extrasSummary.textContent = `${manifest.extraAssets.length} additional visual file(s)`;
    extras.append(extrasSummary);

    for (const asset of manifest.extraAssets) {
      const link = document.createElement("a");
      link.href = asset.downloadUrl || asset.url;
      link.textContent = `${asset.relativePath} (${formatBytes(asset.size)})`;
      extras.append(link);
    }
    panel.append(extras);
  }
}

async function loadJobVisuals(job, panel, options = {}) {
  if (!job.outputFolder || activeStatuses.has(job.status)) {
    panel.hidden = true;
    return;
  }

  panel.hidden = false;
  panel.textContent = "Loading visual assets...";
  const hideHeading = Boolean(options.hideHeading || panel.dataset?.hideVisualHeading === "1");

  const cacheKey = `${job.id}:${job.updatedAt || ""}`;
  try {
    let manifest = visualManifestCache.get(cacheKey);
    if (!manifest) {
      manifest = await api(`/api/jobs/${job.id}/visuals`);
      visualManifestCache.set(cacheKey, manifest);
    }
    renderVisualPanel(panel, manifest, { ...options, hideHeading });
  } catch (error) {
    panel.textContent = error.message;
  }
}

function renderVisualPanelShell(job, panel) {
  panel.textContent = "";
  if (!job.outputFolder || activeStatuses.has(job.status)) {
    panel.hidden = true;
    return;
  }

  panel.hidden = false;
  const wrapper = document.createElement("details");
  wrapper.className = "visual-panel-details";

  const summary = document.createElement("summary");
  const title = makeElement("span", "visual-panel-title", "Visual Assets");
  const hint = makeElement("span", "visual-panel-hint", "Open to load images and media files");
  summary.append(title, hint);
  wrapper.append(summary);

  const content = makeElement("div", "visual-panel-content");
  content.dataset.hideVisualHeading = "1";
  wrapper.append(content);
  panel.append(wrapper);

  let loaded = false;
  wrapper.addEventListener("toggle", async () => {
    if (!wrapper.open || loaded) return;
    loaded = true;
    await loadJobVisuals(job, content, { hideHeading: true });
  });
}

function renderChapterPanel(panel, manifest, job) {
  panel.textContent = "";
  panel.hidden = false;

  const heading = makeElement("div", "chapter-heading");
  const title = makeElement("h3", "", "Chapter Review");
  const actions = makeElement("div", "chapter-heading-actions");
  const status = makeElement("span", "visual-status", `${manifest.chapters?.length || 0} chapter(s)`);
  const smeButton = document.createElement("button");
  smeButton.type = "button";
  smeButton.className = "secondary";
  smeButton.textContent = "Prepare SME Review";
  const publishButton = document.createElement("button");
  publishButton.type = "button";
  publishButton.className = "secondary";
  publishButton.textContent = "Publish Online";
  const openReview = document.createElement("a");
  openReview.className = "sme-review-link";
  openReview.target = "_blank";
  openReview.rel = "noreferrer";
  openReview.textContent = "Open SME Link";
  openReview.hidden = !job.cloudReview?.reviewUrl;
  if (job.cloudReview?.reviewUrl) openReview.href = job.cloudReview.reviewUrl;
  const feedbackButton = document.createElement("button");
  feedbackButton.type = "button";
  feedbackButton.className = "secondary";
  feedbackButton.textContent = "Retrieve Feedback";
  const smeStatus = makeElement("span", "chapter-save-status");
  smeButton.addEventListener("click", async () => {
    smeButton.disabled = true;
    smeButton.textContent = "Preparing...";
    smeStatus.textContent = "";
    try {
      const result = await api(`/api/jobs/${job.id}/sme-review`, { method: "POST", body: "{}" });
      chapterManifestCache.clear();
      visualManifestCache.clear();
      codexPromptCache.clear();
      const jobRow = panel.closest(".job-row");
      const artifactList = jobRow?.querySelector(".artifact-list");
      if (artifactList && result.job?.artifacts) {
        renderArtifactLinks(artifactList, result.job.artifacts);
      }
      smeStatus.textContent = "SME package ready.";
    } catch (error) {
      smeStatus.textContent = error.message;
    } finally {
      smeButton.disabled = false;
      smeButton.textContent = "Prepare SME Review";
    }
  });
  publishButton.addEventListener("click", async () => {
    publishButton.disabled = true;
    publishButton.textContent = "Publishing...";
    smeStatus.textContent = "";
    try {
      const result = await api(`/api/jobs/${job.id}/sme-review/publish`, {
        method: "POST",
        body: JSON.stringify({ accessCode: `${job.courseCode || "BOOK"}-SME` })
      });
      if (result.cloudReview?.reviewUrl) {
        openReview.href = result.cloudReview.reviewUrl;
        openReview.hidden = false;
        smeStatus.textContent = `Published: ${result.cloudReview.accessCode}`;
      } else {
        smeStatus.textContent = "Published online.";
      }
      await loadJobs({ force: true });
    } catch (error) {
      smeStatus.textContent = error.message;
    } finally {
      publishButton.disabled = false;
      publishButton.textContent = "Publish Online";
    }
  });
  feedbackButton.addEventListener("click", async () => {
    feedbackButton.disabled = true;
    feedbackButton.textContent = "Retrieving...";
    smeStatus.textContent = "";
    try {
      const result = await api(`/api/jobs/${job.id}/sme-review/feedback`, { method: "POST", body: "{}" });
      const summary = result.summary || {};
      smeStatus.textContent = `Feedback: ${summary.chapterFeedbackCount || 0} chapter(s), ${summary.commentCount || 0} comment(s), ${summary.editedChapterCount || 0} edited chapter(s).`;
      renderSmeFeedbackSummary(panel, result);
      await loadJobs({ force: true });
    } catch (error) {
      smeStatus.textContent = error.message;
    } finally {
      feedbackButton.disabled = false;
      feedbackButton.textContent = "Retrieve Feedback";
    }
  });
  actions.append(status, smeButton, publishButton, openReview, feedbackButton, smeStatus);
  heading.append(title, actions);
  panel.append(heading);

  if (job.cloudReview?.reviewUrl || job.smeFeedback) {
    const cloudStatus = makeElement("div", "sme-cloud-status");
    if (job.cloudReview?.reviewUrl) {
      cloudStatus.append(makeElement("span", "", `Online review: ${job.cloudReview.accessCode || ""}`));
      const link = document.createElement("a");
      link.href = job.cloudReview.reviewUrl;
      link.target = "_blank";
      link.rel = "noreferrer";
      link.textContent = job.cloudReview.reviewUrl;
      cloudStatus.append(link);
    }
    if (job.smeFeedback) {
      cloudStatus.append(makeElement("span", "", `Last retrieved: ${formatDate(job.smeFeedback.retrievedAt)} | ${job.smeFeedback.chapterFeedbackCount || 0} chapter(s), ${job.smeFeedback.commentCount || 0} comment(s), ${job.smeFeedback.editedChapterCount || 0} edited chapter(s)`));
    }
    panel.append(cloudStatus);
  }

  if (!manifest.chapters?.length) {
    panel.append(makeElement("div", "empty-state compact", manifest.message || "No chapter source files are available yet."));
    return;
  }

  const summary = makeElement("div", "chapter-summary", "Chapter JSON and Markdown are the editable source of truth for review and rebuilds. Depth gate: each production-draft chapter must be at least 1,800 words; 2,200+ words is the preferred higher-ed depth target.");
  panel.append(summary);

  const list = makeElement("div", "chapter-list");
  for (const chapter of manifest.chapters) {
    const item = makeElement("section", "chapter-item");
    const itemHead = makeElement("div", "chapter-item-head");
    const headText = makeElement("div");
    headText.append(makeElement("h4", "", `Chapter ${chapter.chapterNumber}: ${chapter.title}`));
    headText.append(makeElement("div", "chapter-meta", `${chapter.wordCount || 0} words | ${chapter.reviewStatus || "Not reviewed"}`));

    const linkRow = makeElement("div", "chapter-links");
    const markdownLink = document.createElement("a");
    markdownLink.href = chapterAssetUrl(job.id, chapter.markdownFile);
    markdownLink.textContent = "Markdown";
    const jsonLink = document.createElement("a");
    jsonLink.href = chapterAssetUrl(job.id, chapter.jsonFile);
    jsonLink.textContent = "JSON";
    linkRow.append(markdownLink, jsonLink);
    itemHead.append(headText, linkRow);
    item.append(itemHead);

    const details = document.createElement("details");
    details.className = "chapter-editor";
    const summaryEl = document.createElement("summary");
    summaryEl.textContent = "Edit this chapter";
    details.append(summaryEl);

    const editor = makeElement("div", "chapter-editor-body");
    const statusLabel = makeElement("label", "chapter-review-field");
    statusLabel.append(makeElement("span", "", "Review status"));
    const statusSelect = document.createElement("select");
    for (const optionText of chapterReviewStatuses) {
      const option = document.createElement("option");
      option.value = optionText;
      option.textContent = optionText;
      if ((chapter.reviewStatus || "Not reviewed") === optionText) option.selected = true;
      statusSelect.append(option);
    }
    statusLabel.append(statusSelect);

    const notesLabel = makeElement("label", "chapter-review-field");
    notesLabel.append(makeElement("span", "", "ID notes"));
    const notes = document.createElement("textarea");
    notes.className = "chapter-notes";
    notes.value = chapter.notes || "";
    notes.placeholder = "Revision notes, SME handoff notes, or approval rationale";
    notesLabel.append(notes);

    const richBlock = makeElement("div", "chapter-preview-block");
    const richHeading = makeElement("div", "chapter-preview-heading");
    richHeading.append(makeElement("strong", "", "Edit chapter content"));
    richHeading.append(makeElement("span", "", "Click text to edit; changes apply after Save Chapter"));
    const richEditor = makeElement("div", "chapter-preview chapter-rich-editor");
    richEditor.contentEditable = "true";
    richEditor.setAttribute("role", "textbox");
    richEditor.setAttribute("aria-label", `Chapter ${chapter.chapterNumber} editable content`);
    richEditor.textContent = "Open the editor to load chapter content.";
    richEditor.addEventListener("click", openEditableLink);
    richEditor.addEventListener("auxclick", openEditableLink);
    richBlock.append(richHeading, richEditor);

    const sourceDetails = document.createElement("details");
    sourceDetails.className = "chapter-source-details";
    const sourceSummary = document.createElement("summary");
    sourceSummary.textContent = "Advanced Markdown source";
    sourceDetails.append(sourceSummary);
    const markdownLabel = makeElement("label", "chapter-review-field markdown");
    markdownLabel.append(makeElement("span", "", "Chapter Markdown"));
    const textarea = document.createElement("textarea");
    textarea.className = "chapter-markdown-editor";
    textarea.placeholder = "Loading chapter markdown...";
    markdownLabel.append(textarea);
    sourceDetails.append(markdownLabel);

    const loadRichEditorFromMarkdown = () => {
      richEditor.innerHTML = markdownToPreviewHtml(textarea.value, job.id);
    };
    const syncMarkdownFromRichEditor = () => {
      textarea.value = richEditorToMarkdown(richEditor);
    };
    textarea.addEventListener("input", loadRichEditorFromMarkdown);

    const topSaveRow = makeElement("div", "chapter-save-row chapter-save-row-top");
    const saveRow = makeElement("div", "chapter-save-row");
    const rebuildLabel = makeElement("label", "chapter-rebuild-check");
    const rebuildInput = document.createElement("input");
    rebuildInput.type = "checkbox";
    rebuildLabel.append(rebuildInput, makeElement("span", "", "Rebuild DOCX/HTML after save"));
    const saveButton = document.createElement("button");
    saveButton.type = "button";
    saveButton.className = "secondary";
    saveButton.textContent = "Save Chapter";
    const saveStatus = makeElement("span", "chapter-save-status");
    const topSaveButton = document.createElement("button");
    topSaveButton.type = "button";
    topSaveButton.textContent = "Save Chapter";
    saveRow.append(rebuildLabel, saveButton, saveStatus);
    topSaveRow.append(topSaveButton, makeElement("span", "chapter-save-status", "Changes are local until saved."));

    let loaded = false;
    details.addEventListener("toggle", async () => {
      if (!details.open || loaded) return;
      textarea.disabled = true;
      try {
        const content = await api(`/api/jobs/${job.id}/chapters/${chapter.id}`);
        textarea.value = content.markdown || "";
        notes.value = content.notes || notes.value || "";
        statusSelect.value = content.reviewStatus || statusSelect.value;
        loadRichEditorFromMarkdown();
        loaded = true;
      } catch (error) {
        textarea.value = error.message;
        loadRichEditorFromMarkdown();
      } finally {
        textarea.disabled = false;
      }
    });

    const saveChapter = async (button) => {
      syncMarkdownFromRichEditor();
      saveButton.disabled = true;
      topSaveButton.disabled = true;
      saveStatus.textContent = rebuildInput.checked ? "Saving and rebuilding..." : "Saving...";
      const topStatus = topSaveRow.querySelector(".chapter-save-status");
      topStatus.textContent = saveStatus.textContent;
      try {
        const result = await api(`/api/jobs/${job.id}/chapters/${chapter.id}`, {
          method: "POST",
          body: JSON.stringify({
            markdown: textarea.value,
            reviewStatus: statusSelect.value,
            notes: notes.value,
            rebuild: rebuildInput.checked
          })
        });
        chapterManifestCache.clear();
        visualManifestCache.clear();
        codexPromptCache.clear();
        aiRequestCache.clear();
        const jobRow = panel.closest(".job-row");
        const artifactList = jobRow?.querySelector(".artifact-list");
        if (artifactList && result.job?.artifacts) {
          renderArtifactLinks(artifactList, result.job.artifacts);
        }
        saveStatus.textContent = result.rebuilt ? "Saved and rebuilt." : "Saved.";
        topStatus.textContent = saveStatus.textContent;
        await loadJobChapters(result.job || job, panel);
      } catch (error) {
        saveStatus.textContent = error.message;
        topStatus.textContent = error.message;
      } finally {
        saveButton.disabled = false;
        topSaveButton.disabled = false;
      }
    };

    saveButton.addEventListener("click", () => saveChapter(saveButton));
    topSaveButton.addEventListener("click", () => saveChapter(topSaveButton));

    editor.append(topSaveRow, statusLabel, notesLabel, richBlock, sourceDetails, saveRow);
    details.append(editor);
    item.append(details);
    list.append(item);
  }
  panel.append(list);
}

function renderSmeFeedbackSummary(panel, result) {
  const previous = panel.querySelector(".sme-feedback-summary");
  if (previous) previous.remove();

  const feedback = result.feedback || {};
  const summary = result.summary || {};
  const wrapper = makeElement("div", "sme-feedback-summary");
  wrapper.append(makeElement("h4", "", "Retrieved SME Feedback"));
  wrapper.append(makeElement("div", "chapter-meta", `${summary.reviewerName || "Reviewer"} | Saved ${summary.savedAt ? formatDate(summary.savedAt) : "not yet"} | ${summary.outputPath || ""}`));

  const entries = Object.entries(feedback.chapterFeedback || {});
  if (!entries.length) {
    wrapper.append(makeElement("div", "empty-state compact", "No chapter feedback has been submitted yet."));
    panel.append(wrapper);
    return;
  }

  for (const [chapterId, item] of entries) {
    const card = makeElement("div", "sme-feedback-card");
    card.append(makeElement("strong", "", `${chapterId} | ${item.decision || "Not reviewed"}`));
    if (item.comments) card.append(makeElement("p", "", item.comments));
    if (item.inlineComments?.length) {
      const list = makeElement("ul", "sme-inline-comments");
      for (const comment of item.inlineComments) {
        const row = document.createElement("li");
        row.textContent = `${comment.selectedText || "Selection"}: ${comment.note || ""}`;
        list.append(row);
      }
      card.append(list);
    }
    if (item.editedHtml || item.editedText) {
      card.append(makeElement("div", "sme-edit-flag", "Edited text snapshot available for comparison."));
    }
    wrapper.append(card);
  }
  panel.append(wrapper);
}

async function loadJobChapters(job, panel) {
  if (!job.outputFolder || activeStatuses.has(job.status) || getWorkflowStage(job) === "format-review") {
    panel.hidden = true;
    return;
  }

  panel.hidden = false;
  panel.textContent = "Preparing chapter source files...";

  const cacheKey = `${job.id}:${job.updatedAt || ""}`;
  try {
    let manifest = chapterManifestCache.get(cacheKey);
    if (!manifest) {
      manifest = await api(`/api/jobs/${job.id}/chapters`);
      chapterManifestCache.set(cacheKey, manifest);
    }
    renderChapterPanel(panel, manifest, job);
  } catch (error) {
    panel.textContent = error.message;
  }
}

function renderAiRequestList(container, requests, options = {}) {
  const shouldStickToBottom = options.forceScroll || isScrolledNearBottom(container);
  container.textContent = "";
  if (!requests?.length) {
    container.append(makeElement("div", "empty-state compact", "No book chat messages yet."));
    if (options.forceScroll) scrollToBottom(container);
    return;
  }

  for (const request of [...requests].reverse()) {
    const item = makeElement("div", "ai-chat-turn");
    const scopeText = request.chapterId
      ? `${request.scope || "Chapter"} | ${request.chapterId}`
      : request.scope || "Whole package";
    const statusClass = request.status === "Running"
      ? "ai-request-status running"
      : request.status === "Failed"
        ? "ai-request-status failed"
        : "ai-request-status";
    const meta = makeElement("div", "ai-chat-meta");
    meta.append(makeElement("span", "", scopeText));
    meta.append(makeElement("span", statusClass, request.status || "Unknown"));
    const elapsed = formatAiElapsed(request);
    if (elapsed) {
      meta.append(makeElement("span", "ai-chat-elapsed", request.status === "Running" ? `Working ${elapsed}` : `Took ${elapsed}`));
    }
    meta.append(makeElement("span", request.allowEdits ? "ai-chat-edit-mode" : "ai-chat-advice-mode", request.allowEdits ? "Edits allowed" : "Advice only"));
    if (request.includeHistory === false) {
      meta.append(makeElement("span", "ai-chat-history-off", "History off"));
    }
    if (request.postProcessStatus) {
      meta.append(makeElement("span", "ai-chat-post-process", request.postProcessStatus));
    }

    const userBubble = makeElement("div", "ai-chat-message user");
    const userAvatar = makeElement("div", "ai-chat-avatar", "You");
    const userContent = makeElement("div", "ai-chat-content");
    userBubble.append(makeElement("p", "", request.instruction || ""));
    userContent.append(userBubble);
    const userRow = makeElement("div", "ai-chat-row user");
    userRow.append(userContent, userAvatar);
    item.append(userRow);

    const codexBubble = makeElement("div", request.status === "Failed" ? "ai-chat-message codex failed" : "ai-chat-message codex");
    const codexAvatar = makeElement("div", "ai-chat-avatar codex", "C");
    const codexContent = makeElement("div", "ai-chat-content");
    codexContent.append(meta);
    if (request.responsePreview) {
      const response = makeElement("pre", "ai-response-text");
      response.textContent = request.responsePreview;
      codexBubble.append(response);
      const suggestions = parseSuggestedOutlineChanges(request.responsePreview);
      if (suggestions.length) {
        const load = makeElement("button", "secondary outline-apply-button", `Load ${suggestions.length} suggested outline change(s) into the editor`);
        load.type = "button";
        const applyStatus = makeElement("span", "hint", "");
        load.addEventListener("click", () => {
          const job = getSelectedBookChatJob();
          applyStatus.textContent = job ? applySuggestedOutlineChanges(job.id, suggestions) : "Select the book first.";
        });
        const apply = makeElement("button", "secondary outline-apply-button", "Apply suggestions & regenerate preview");
        apply.type = "button";
        apply.addEventListener("click", async () => {
          const job = getSelectedBookChatJob();
          applyStatus.textContent = job
            ? await applySuggestedOutlineChangesAndRegenerate(job.id, suggestions)
            : "Select the book first.";
        });
        const applyRow = makeElement("div", "outline-apply-row");
        applyRow.append(load, apply, applyStatus);
        codexBubble.append(applyRow);
        codexBubble.append(makeElement("p", "hint", "Applies titles, focus, and writer guidance only. Official outcomes are unchanged; use the separate outcome review to replace them."));
      }
      if (/^CO\d+[.:]\s/m.test(request.instruction || "")) {
        const outcomes = makeElement("button", "secondary", "Review outcome replacement from this request"); outcomes.type = "button";
        outcomes.addEventListener("click", () => {
          const job = getSelectedBookChatJob(); const editor = outlineEditors.get(job?.id);
          if (!editor?.container.isConnected) { bookChatStatus.textContent = "Open this book's format review first."; return; }
          const start = request.instruction.search(/^CO\d+[.:]\s/m);
          editor.outcomeEditor.openWithText(request.instruction.slice(start));
        });
        codexBubble.append(outcomes);
      }
    } else if (request.status === "Running") {
      codexBubble.append(renderAiProgressCard(request, elapsed));
    } else {
      codexBubble.append(makeElement("p", "", request.statusDetail || "Waiting for a response..."));
    }
    const showActivity = request.status === "Running" || request.status === "Failed" || request.logPreview;
    if (showActivity) {
      const logDetails = document.createElement("details");
      logDetails.className = request.status === "Failed" ? "ai-log-preview failed" : "ai-log-preview";
      logDetails.open = request.status === "Running" || request.status === "Failed";
      const summary = document.createElement("summary");
      summary.textContent = request.status === "Failed" ? "Failure details" : "Activity";
      const logText = makeElement("pre", "");
      logText.textContent = request.activityPreview || request.logPreview || [
        `Status: ${request.status || "Running"}`,
        request.statusDetail || "Codex process has started.",
        elapsed ? `Elapsed: ${elapsed}` : "",
        request.nextExpectation || "",
        request.promptPath ? `Prompt file: ${request.promptPath}` : "",
        request.responsePath ? `Response file: ${request.responsePath}` : "",
        request.errorPath ? `Log file: ${request.errorPath}` : "",
        "",
        "Waiting for Codex output..."
      ].filter(Boolean).join("\n");
      logDetails.append(summary, logText);
      codexBubble.append(logDetails);
    }
    codexContent.append(codexBubble);

    const details = document.createElement("details");
    details.className = "ai-request-links";
    const summary = document.createElement("summary");
    summary.textContent = "Files";
    details.append(summary);
    if (request.responseUrl) {
      const response = document.createElement("a");
      response.href = request.responseUrl;
      response.textContent = "Open response";
      details.append(response);
    }
    if (request.promptUrl) {
      const prompt = document.createElement("a");
      prompt.href = request.promptUrl;
      prompt.textContent = "Prompt";
      details.append(prompt);
    }
    if (request.errorUrl) {
      const error = document.createElement("a");
      error.href = request.errorUrl;
      error.textContent = "Log";
      details.append(error);
    }
    codexContent.append(details);
    const codexRow = makeElement("div", "ai-chat-row codex");
    codexRow.append(codexAvatar, codexContent);
    item.append(codexRow);
    container.append(item);
  }

  if (shouldStickToBottom) {
    scrollToBottom(container);
  }
}

async function populateAiChapterScope(job, select) {
  select.textContent = "";
  const packageOption = document.createElement("option");
  packageOption.value = "";
  packageOption.textContent = "Whole package";
  select.append(packageOption);

  if (!job?.id) return;

  try {
    const manifest = await api(`/api/jobs/${job.id}/chapters`);
    for (const chapter of manifest.chapters || []) {
      const option = document.createElement("option");
      option.value = chapter.id;
      option.textContent = `Chapter ${chapter.chapterNumber}: ${chapter.title}`;
      select.append(option);
    }
  } catch {
    // Chapter scope is helpful but not required for package-level requests.
  }
}

function getBookChatJobs() {
  return currentJobs.filter((job) => job.outputFolder && !activeStatuses.has(job.status));
}

function getSelectedBookChatJob() {
  return getBookChatJobs().find((job) => job.id === selectedBookChatJobId) || null;
}

function syncBookChatComposer() {
  const job = getSelectedBookChatJob();
  const connected = codexAssistantAvailable && Date.now() < codexConnectionExpiresAt;
  const busy = bookChatSubmissionPending || bookChatResetPending;
  const formatReview = job && getWorkflowStage(job) === "format-review";
  // Connection readiness gates sending, never the ability to write a draft.
  bookChatMessage.disabled = false;
  bookChatSend.disabled = !job || busy || codexConnectionTestPending || bookChatHasRunningRequests;
  bookChatSend.textContent = bookChatSubmissionPending ? "Sending..." : connected ? "Send" : "Connect & send";
  bookChatNew.disabled = busy || bookChatHasRunningRequests || codexConnectionTestPending;
  bookChatNew.textContent = bookChatResetPending ? "Starting new chat..." : "New chat";
  bookChatJobSelect.disabled = busy || !getBookChatJobs().length;
  bookChatScopeSelect.disabled = busy || !job;
  bookChatAllowEdits.disabled = busy || !job || formatReview;
  if (formatReview) bookChatAllowEdits.checked = false;
  for (const button of [bookChatTestConnection, document.getElementById("testCodexConnection")]) {
    if (button) { button.disabled = codexConnectionTestPending; button.textContent = codexConnectionTestPending ? "Testing connection..." : "Test connection"; }
  }
  bookChatConnectionStatus.textContent = codexConnectionTestPending
    ? "Testing a real response (up to 25 seconds). You can keep typing."
    : !job ? "You can type now. Select an existing book package to send a book question; there is no need to generate another book."
      : connected ? `Connection verified ${formatDate(codexConnectionTestedAt)}. ${formatReview ? "Ask Codex for format recommendations; apply layout changes here before generation." : "Edits are off unless you enable them. A successful test does not guarantee later requests will succeed."}`
        : `You can type now. ${codexConnectionMessage}${codexConnectionTestedAt ? ` Last test: ${formatDate(codexConnectionTestedAt)}.` : ""} Use Test connection or Connect & send.`;
}

function renderBookChatJobOptions() {
  const jobs = getBookChatJobs();
  const previous = selectedBookChatJobId || bookChatJobSelect.value;
  const optionsSignature = jobs.map((job) => `${job.id}:${job.updatedAt || ""}:${job.title || ""}`).join("|");
  // Always refresh readiness, even when the package list has not changed.
  syncBookChatComposer();
  if (optionsSignature && optionsSignature === renderedBookChatOptionsSignature && jobs.some((job) => job.id === selectedBookChatJobId)) {
    return getSelectedBookChatJob();
  }

  renderedBookChatOptionsSignature = optionsSignature;
  bookChatJobSelect.textContent = "";

  if (!jobs.length) {
    renderedBookChatThreadSignature = "";
    const option = document.createElement("option");
    option.value = "";
    option.textContent = "No completed packages";
    bookChatJobSelect.append(option);
    selectedBookChatJobId = "";
    bookChatJobSelect.disabled = true;
    bookChatScopeSelect.disabled = true;
    bookChatThread.textContent = "";
    bookChatThread.append(makeElement("div", "empty-state compact", "Create or import a book to use Ask Codex."));
    syncBookChatComposer();
    return null;
  }

  bookChatJobSelect.disabled = false;
  bookChatScopeSelect.disabled = false;

  for (const job of jobs) {
    const option = document.createElement("option");
    option.value = job.id;
    option.textContent = `${job.courseCode ? `${job.courseCode}: ` : ""}${job.title || "Untitled Book"}`;
    bookChatJobSelect.append(option);
  }

  selectedBookChatJobId = jobs.some((job) => job.id === previous) ? previous : jobs[0].id;
  renderedBookChatThreadSignature = "";
  bookChatJobSelect.value = selectedBookChatJobId;
  syncBookChatComposer();
  return getSelectedBookChatJob();
}

async function refreshBookChatScope(job) {
  const previousScope = bookChatScopeSelect.value;
  await populateAiChapterScope(job, bookChatScopeSelect);
  if (Array.from(bookChatScopeSelect.options).some((option) => option.value === previousScope)) {
    bookChatScopeSelect.value = previousScope;
  }
}

async function loadBookChat(options = {}) {
  const job = options.job || renderBookChatJobOptions();
  if (!job) return;
  const loadGeneration = ++chatLoadGeneration;
  syncBookChatComposer();

  if (options.refreshScope) {
    await refreshBookChatScope(job);
  }

  if (options.showLoading) {
    bookChatThread.textContent = "Loading Ask Codex...";
  }

  const cacheWindowMs = bookChatHasRunningRequests ? 2000 : 5000;
  const cacheKey = `${job.id}:${job.updatedAt || ""}:${Date.now() - (Date.now() % cacheWindowMs)}`;
  try {
    let data = aiRequestCache.get(cacheKey);
    if (!data) {
      data = await api(`/api/jobs/${job.id}/ai-requests`);
      if (loadGeneration !== chatLoadGeneration || job.id !== selectedBookChatJobId) return;
      aiRequestCache.set(cacheKey, data);
    }
    if (loadGeneration !== chatLoadGeneration || job.id !== selectedBookChatJobId) return;
    bookChatSessions.set(job.id, data.sessionId || job.chatSessionId || "legacy");
    bookChatHasRunningRequests = (data.requests || []).some(isAiRequestActive);
    // The job list may still contain Running from its previous poll. Use the
    // newest request result for button state, not that stale job snapshot.
    const currentJob = currentJobs.find((item) => item.id === job.id) || job;
    currentJob.aiRequests = data.requests || [];
    syncQaRepairRequests(currentJob, data.requests || []);
    syncBookChatComposer();
    const authFailure = (data.requests || []).find((request) => request.failureKind === "authentication");
    if (authFailure && lastObservedAuthFailure !== `${job.id}:${authFailure.id}`) {
      lastObservedAuthFailure = `${job.id}:${authFailure.id}`;
      await loadCodexStatus();
    }
    const postProcessSignature = (data.requests || [])
      .filter((request) => request.allowEdits && request.postProcessStatus)
      .map((request) => `${request.id}:${request.postProcessedAt || ""}:${request.postProcessStatus || ""}`)
      .join("|");
    const previousPostProcessSignature = aiPostProcessSignatures.get(job.id);
    aiPostProcessSignatures.set(job.id, postProcessSignature);
    if (previousPostProcessSignature !== undefined && previousPostProcessSignature !== postProcessSignature) {
      chapterManifestCache.clear();
      visualManifestCache.clear();
      codexPromptCache.clear();
      renderedJobSignatures.delete(job.id);
      bookChatStatus.textContent = "Ask Codex edits finished. Refreshing the chapter view...";
      await loadJobs({ force: true, focusJobId: job.id, skipBookChat: true });
    }

    if (loadGeneration !== chatLoadGeneration || job.id !== selectedBookChatJobId) return;
    const threadSignature = `${job.id}|${job.outlineUpdate?.at || ""}|${job.outlineUpdate?.planHash || ""}|${data.sessionId || "legacy"}|${(data.requests || []).map((request) => `${request.id}:${request.status}:${request.completedAt || ""}:${request.responsePreview || ""}:${request.statusDetail || ""}:${request.currentAction || ""}:${request.latestActivity || ""}:${request.activityPreview || ""}:${request.logPreview || ""}:${request.postProcessedAt || ""}:${request.postProcessStatus || ""}`).join("|")}`;
    if (!options.force && !options.showLoading && threadSignature === renderedBookChatThreadSignature) {
      return;
    }
    renderedBookChatThreadSignature = threadSignature;
    renderAiRequestList(bookChatThread, data.requests || [], { forceScroll: options.forceScroll || options.showLoading });
    if (job.outlineUpdate?.message) { const receipt = makeElement("p", "outline-update-receipt", job.outlineUpdate.message); receipt.setAttribute("role", "status"); bookChatThread.prepend(receipt); }
  } catch (error) {
    if (loadGeneration !== chatLoadGeneration || job.id !== selectedBookChatJobId) return;
    const repair = qaRepairStates.get(job.id);
    if (repair?.busy && repair.request) {
      setQaRepairState(job, { ...repair, message: `Cannot refresh repair progress: ${error.message}. The request may still be running; do not submit it again. Use Refresh to check.` });
    }
    if ((error.message || "").includes("404")) {
      renderedBookChatThreadSignature = `${job.id}|missing-ai-requests`;
      renderAiRequestList(bookChatThread, [], { forceScroll: options.forceScroll || options.showLoading });
      return;
    }
    bookChatThread.textContent = error.message;
  }
}

async function pollBookChat() {
  if (!selectedBookChatJobId) return;
  if (!bookChatHasRunningRequests || document.hidden) return;
  await loadBookChat({ refreshScope: false, showLoading: false });
}

function renderCodexPromptPanel(panel, manifest) {
  panel.textContent = "";
  panel.hidden = false;

  const wrapper = document.createElement("details");
  wrapper.className = "codex-prompt-details";
  const summary = document.createElement("summary");
  summary.textContent = "Advanced prompt files";
  wrapper.append(summary);

  const heading = makeElement("div", "codex-prompt-heading");
  heading.append(makeElement("h3", "", "Prompt Files"));
  heading.append(makeElement("span", manifest.status === "Ready" ? "visual-status" : "visual-status warning", manifest.status || "Unknown"));
  wrapper.append(heading);

  if (manifest.message) {
    wrapper.append(makeElement("div", "codex-prompt-message", manifest.message));
  }

  if (!manifest.prompts?.length) {
    wrapper.append(makeElement("div", "empty-state compact", "No Codex prompt files are available for this job yet."));
    panel.append(wrapper);
    return;
  }

  const list = makeElement("div", "codex-prompt-list");
  for (const prompt of manifest.prompts) {
    const item = makeElement("div", "codex-prompt-item");
    const title = makeElement("strong", "", prompt.title || prompt.fileName);
    const meta = makeElement("span", "", `${prompt.fileName} (${formatBytes(prompt.size)})`);
    const open = document.createElement("a");
    open.href = prompt.url || prompt.downloadUrl;
    open.textContent = "Open";
    const download = document.createElement("a");
    download.href = prompt.downloadUrl || prompt.url;
    download.textContent = "Download";
    item.append(title, meta, open, download);
    list.append(item);
  }
  wrapper.append(list);

  if (manifest.command) {
    const details = document.createElement("details");
    details.className = "codex-command-details";
    const summary = document.createElement("summary");
    summary.textContent = "CLI command";
    const command = makeElement("code", "", manifest.command);
    details.append(summary, command);
    wrapper.append(details);
  }

  panel.append(wrapper);
}

async function loadJobCodexPrompts(job, panel) {
  if (!job.outputFolder || activeStatuses.has(job.status)) {
    panel.hidden = true;
    return;
  }

  panel.hidden = false;
  panel.textContent = "Preparing Codex prompts...";

  const cacheKey = `${job.id}:${job.updatedAt || ""}`;
  try {
    let manifest = codexPromptCache.get(cacheKey);
    if (!manifest) {
      manifest = await api(`/api/jobs/${job.id}/codex-prompts`);
      codexPromptCache.set(cacheKey, manifest);
    }
    renderCodexPromptPanel(panel, manifest);
  } catch (error) {
    panel.textContent = error.message;
  }
}

function getJobRenderSignature(job) {
  const lastLog = Array.isArray(job.log) && job.log.length ? job.log[job.log.length - 1] : null;
  const artifacts = (job.artifacts || []).map((artifact) => `${artifact.fileName}:${artifact.size}`).join("|");
  const aiRequests = (job.aiRequests || []).map((request) => `${request.id}:${request.status}:${request.completedAt || ""}`).join("|");
  const warnings = (job.packageFormat?.warnings || []).join("|");
  const cloudReview = job.cloudReview ? `${job.cloudReview.status}:${job.cloudReview.accessCode}:${job.cloudReview.reviewUrl}:${job.cloudReview.publishedAt}` : "";
  const smeFeedback = job.smeFeedback ? `${job.smeFeedback.retrievedAt}:${job.smeFeedback.chapterFeedbackCount}:${job.smeFeedback.commentCount}:${job.smeFeedback.editedChapterCount}` : "";
  const progress = job.progress ? {
    phase: job.progress.phase || "",
    detail: job.progress.detail || "",
    percent: job.progress.percent,
    updatedAt: job.progress.updatedAt || "",
    recentCount: Array.isArray(job.progress.recent) ? job.progress.recent.length : 0,
    chapters: (job.progress.chapters || []).map((chapter) => `${chapter.chapterNumber}:${chapter.status}:${chapter.phase}:${chapter.updatedAt || ""}`).join("|"),
    errors: (job.progress.errors || []).map((error) => `${error.at}:${error.phase}:${error.detail}`).join("|")
  } : null;
  return JSON.stringify({
    id: job.id,
    status: job.status,
    outcomeAnalysis: job.outcomeAnalysis ? `${job.outcomeAnalysis.status}:${job.outcomeAnalysis.completedAt || ""}:${job.outcomeAnalysis.approvedAt || ""}` : "",
    workflowStage: getWorkflowStage(job),
    workflowStatus: getWorkflowStatus(job),
    formatReview: job.formatReview || null,
    formatState: job.formatState || null,
    lifecycleStatus: job.lifecycleStatus || "",
    publishedAt: job.publishedAt || "",
    updatedAt: job.updatedAt,
    error: job.error || "",
    lastLog,
    progress,
    artifacts,
    aiRequests,
    cloudReview,
    smeFeedback,
    warnings
  });
}

function findRenderedJobNode(jobId) {
  return Array.from(jobsList.children).find((child) => child.dataset?.jobId === jobId) || null;
}

function appendPackageRebuildAction(actions, job) {
  const hasManuscript = (job.artifacts || []).some(artifact => artifact.name === "Markdown ebook");
  if (!job.outputFolder || isJobProcessing(job)
      || !["Failed", "Completed"].includes(job.status)
      || (job.status === "Failed" && !hasManuscript)) return;
  const rebuild = makeElement("button", "secondary", "Rebuild Package");
  rebuild.type = "button";
  rebuild.title = "Rebuild Word and HTML from the saved manuscript. Does not rerun AI drafting or generate images.";
  const error = makeElement("span", "hint");
  error.setAttribute("role", "status");
  rebuild.addEventListener("click", async () => {
    error.textContent = "";
    try { await rebuildJobPackage(job.id, rebuild); }
    catch (failure) { error.textContent = `Rebuild failed: ${failure.message}`; }
  });
  actions.append(rebuild, error);
}

function renderJobs(jobs, options = {}) {
  allJobs = jobs || [];
  currentJobs = getFocusedJobs(allJobs, options);
  const totalCount = allJobs.length;
  renderBookLibrary(allJobs);
  jobCount.textContent = totalCount ? `${totalCount}` : "";
  renderBookChatJobOptions();

  if (options.force) {
    jobsList.textContent = "";
    renderedJobSignatures.clear();
  }

  if (!currentJobs.length) {
    showView(currentView === "new-book" || currentView === "settings" ? currentView : "books");
    jobsList.textContent = "";
    renderedJobSignatures.clear();
    const empty = document.createElement("div");
    empty.className = "empty-state";
    empty.textContent = "No book jobs yet.";
    jobsList.append(empty);
    return;
  }

  if (currentView === "active-book") renderActiveBookHeader(currentJobs[0]);
  const chatJob = currentJobs[0];
  bookChatPanel.hidden = currentView !== "active-book"
    || !chatJob.outputFolder
    || activeStatuses.has(chatJob.status);

  const incomingIds = new Set(currentJobs.map((job) => job.id));
  for (const child of Array.from(jobsList.children)) {
    if (!child.dataset?.jobId || !incomingIds.has(child.dataset.jobId)) {
      if (child.dataset?.jobId) renderedJobSignatures.delete(child.dataset.jobId);
      child.remove();
    }
  }

  for (const job of currentJobs) {
    syncQaRepairRequests(job, job.aiRequests || []);
    const signature = getJobRenderSignature(job);
    const existing = findRenderedJobNode(job.id);
    if (!options.force && existing && renderedJobSignatures.get(job.id) === signature && !activeStatuses.has(job.status)) {
      continue;
    }

    const node = jobTemplate.content.firstElementChild.cloneNode(true);
    node.dataset.jobId = job.id;
    const title = node.querySelector(".job-title");
    const meta = node.querySelector(".job-meta");
    const status = node.querySelector(".job-status");
    const actions = node.querySelector(".job-actions");
    const workflowPanel = node.querySelector(".workflow-panel");
    const productionPanel = node.querySelector(".production-panel");
    const log = node.querySelector(".job-log");
    const artifacts = node.querySelector(".artifact-list");
    const outcomeAnalysisPanel = node.querySelector(".outcome-analysis-panel");
    const formatReviewPanel = node.querySelector(".format-review-panel");
    const chapterPanel = node.querySelector(".chapter-panel");
    const codexPromptPanel = node.querySelector(".codex-prompt-panel");
    const visualPanel = node.querySelector(".visual-panel");

    title.textContent = `${job.courseCode ? `${job.courseCode}: ` : ""}${job.title || "Untitled Book"}`;
    const packageFormat = job.packageFormat?.status ? ` | ${job.packageFormat.status} package` : "";
    const lifecycle = job.lifecycleStatus && job.lifecycleStatus !== "Active" ? ` | ${job.lifecycleStatus}${job.publishedAt ? ` ${formatDate(job.publishedAt)}` : ""}` : "";
    meta.textContent = `${getWorkflowStatus(job)} | Created ${formatDate(job.createdAt)} | ${job.uploadedFiles?.length || 0} source file(s)${packageFormat}${lifecycle}`;
    status.textContent = job.status || "Unknown";
    status.classList.add(String(job.status || "").toLowerCase());
    if (job.lifecycleStatus && job.lifecycleStatus !== "Active") {
      status.classList.add(String(job.lifecycleStatus).toLowerCase());
    }
    renderJobProgress(log, job);
    appendJobLogLinks(log, job);
    renderJobQaSummary(log, job);
    renderWorkflowPanel(workflowPanel, job);
    // Available whenever nothing is running, including before a preview has
    // ever been built: correcting a name or the wrong document is exactly what
    // a designer needs then.
    if (!isJobProcessing(job)) appendSetupChange(productionPanel, job, api, loadJobs);
    if (!isJobProcessing(job) && job.outputFolder) appendProductionPreferences(productionPanel, job);
    if (!isJobProcessing(job) && job.outputFolder) {
      const review = makeElement("button", "secondary qa-review-button", "Run QA again");
      review.type = "button";
      review.title = "Check saved outline or manuscript and source evidence without rewriting content.";
      review.addEventListener("click", () => rerunJobQa(job.id, review));
      actions.append(review);
    }

    if (isJobProcessing(job)) {
      const busy = document.createElement("span");
      busy.className = "job-meta";
      busy.textContent = "Processing";
      actions.append(busy);
    } else if (job.status === "Failed") {
      const retry = document.createElement("button");
      retry.type = "button";
      retry.className = "secondary";
      retry.textContent = "Retry";
      retry.addEventListener("click", () => runJob(job.id, getWorkflowRunMode(job)).catch((error) => reportJobActionError(job, error.message)));
      actions.append(retry);
      // A full run refuses to start without a current approved preview. Offer
      // the way back instead of leaving the designer with a dead Retry.
      if (job.outputFolder) {
        const recreate = makeElement("button", "secondary", "Recreate format preview");
        recreate.type = "button";
        recreate.addEventListener("click", () => runJob(job.id, "Blueprint").catch((error) => reportJobActionError(job, error.message)));
        actions.append(recreate);
      }
      appendPackageRebuildAction(actions, job);
      if (job.artifacts?.some((artifact) => artifact.fileName?.endsWith(" - E-Book.md"))) {
        const fixQa = makeElement("button", "danger qa-repair-button", "Fix QA with Codex");
        fixQa.type = "button";
        fixQa.addEventListener("click", () => startQaRepair(job));
        actions.append(fixQa);
      }
    } else if (getWorkflowStage(job) === "outcomes-analysis") {
      // A queued curriculum draft has no book to run yet. Offering Run here
      // would be a button whose only outcome is the server refusing it.
      const review = makeElement("button", "secondary", "Review course outcomes");
      review.type = "button";
      review.addEventListener("click", scrollToCurrentWork);
      actions.append(review);
    } else if (getWorkflowStage(job) === "format-review") {
      const recreate = document.createElement("button");
      recreate.type = "button";
      // Before the first run there is no preview to recreate, and "Recreate"
      // reads as though one already exists somewhere.
      recreate.className = job.outputFolder ? "secondary" : "";
      recreate.textContent = job.outputFolder ? "Recreate preview" : "Create format preview";
      recreate.addEventListener("click", () => runJob(job.id, "Blueprint").catch((error) => reportJobActionError(job, error.message)));
      actions.append(recreate);
    } else if (job.status === "Queued") {
      const run = document.createElement("button");
      run.type = "button";
      run.textContent = "Run";
      run.addEventListener("click", () => runJob(job.id, getWorkflowRunMode(job)).catch((error) => reportJobActionError(job, error.message)));
      actions.append(run);
    } else if (job.status === "Completed") {
      if (String(job.qaSummary?.status || "").toUpperCase() === "FAIL") {
        const fixQa = document.createElement("button");
        fixQa.type = "button";
        fixQa.className = "danger qa-repair-button";
        fixQa.textContent = "Fix QA with Codex";
        fixQa.addEventListener("click", () => startQaRepair(job));
        actions.append(fixQa);
      }

      appendPackageRebuildAction(actions, job);

      const refresh = document.createElement("button");
      refresh.type = "button";
      refresh.className = "secondary";
      refresh.textContent = "Refresh Artifacts";
      refresh.addEventListener("click", () => refreshJobArtifacts(job.id, refresh));
      actions.append(refresh);

      const lifecycleState = job.lifecycleStatus || "Active";
      if (lifecycleState !== "Archived") {
        const archive = document.createElement("button");
        archive.type = "button";
        archive.className = "secondary";
        archive.textContent = "Archive";
        archive.addEventListener("click", () => updateJobLifecycle(job.id, "Archived", archive));
        actions.append(archive);
      }

      if (lifecycleState !== "Official") {
        const official = document.createElement("button");
        official.type = "button";
        official.className = "secondary";
        official.textContent = "Mark Official";
        official.addEventListener("click", () => updateJobLifecycle(job.id, "Official", official));
        actions.append(official);
      }

      if (lifecycleState !== "Active") {
        const active = document.createElement("button");
        active.type = "button";
        active.className = "secondary";
        active.textContent = "Restore Active";
        active.addEventListener("click", () => updateJobLifecycle(job.id, "Active", active));
        actions.append(active);
      }

    }
    appendDeleteBookAction(actions, job);

    renderArtifactLinks(artifacts, job.artifacts || []);
    for (const warning of job.packageFormat?.warnings || []) {
      artifacts.append(makeElement("div", "package-format-warning", warning));
    }

    renderedJobSignatures.set(job.id, signature);
    if (existing) {
      existing.replaceWith(node);
    } else {
      jobsList.append(node);
    }
    renderQaRepairStatus(job, node);
    loadJobChapters(job, chapterPanel).catch(() => {});
    loadJobCodexPrompts(job, codexPromptPanel).catch(() => {});
    renderVisualPanelShell(job, visualPanel);
    renderOutcomeAnalysisPanel(job, outcomeAnalysisPanel);
    renderFormatReviewPanel(job, formatReviewPanel);
  }

  if (options.force && !options.skipBookChat && !bookChatPanel.hidden) {
    loadBookChat({ refreshScope: true, showLoading: true }).catch(() => {});
  }
}

async function loadJobs(options = {}) {
  const data = await api("/api/jobs");
  renderJobs(data.jobs || [], options);
}

function reportJobActionError(job, message) {
  // setStatus writes into the New book form, which the active-book screen
  // hides, so an action failure there used to look like nothing happened.
  const node = findRenderedJobNode(job.id);
  const actions = node?.querySelector(".job-actions");
  if (!actions) {
    window.alert(message);
    return;
  }
  let panel = node.querySelector(".job-action-error");
  if (!panel) {
    panel = makeElement("div", "job-action-error");
    panel.setAttribute("role", "alert");
    actions.after(panel);
  }
  panel.textContent = message;
  panel.hidden = false;
  setStatus(message);
}

async function runJob(jobId, mode = "Auto") {
  showView("active-book");
  setFocusedJob(jobId);
  try {
    await api(`/api/jobs/${jobId}/run`, { method: "POST", body: JSON.stringify({ mode }) });
  } catch (error) {
    // The runner starts in a separate process. If the server loses the
    // response after queuing it, refresh before reporting a false retry
    // failure to the user.
    await loadJobs({ force: true, focusJobId: jobId });
    const activeJob = currentJobs.find((job) => job.id === jobId);
    if (activeJob && isJobProcessing(activeJob)) return activeJob;
    setStatus(error.message);
    throw error;
  }
  await loadJobs({ force: true, focusJobId: jobId });
  return currentJobs.find((job) => job.id === jobId) || null;
}

async function rerunJobQa(jobId, button) {
  button.disabled = true;
  button.textContent = "Running QA...";
  const result = makeElement("span", "qa-review-result", "Checking saved content...");
  result.setAttribute("role", "status");
  button.after(result);
  try {
    const review = await api(`/api/jobs/${jobId}/run-qa`, { method: "POST", body: "{}" });
    result.textContent = review.message;
    await loadJobs();
  } catch (error) {
    result.textContent = `QA review could not finish: ${error.message}`;
  } finally {
    button.disabled = false;
    button.textContent = "Run QA again";
  }
}

async function rebuildJobPackage(jobId, button) {
  if (button) {
    button.disabled = true;
    button.textContent = "Rebuilding...";
  }
  try {
    await api(`/api/jobs/${jobId}/rebuild-package`, { method: "POST", body: "{}" });
    visualManifestCache.clear();
    codexPromptCache.clear();
    chapterManifestCache.clear();
    aiRequestCache.clear();
    await loadJobs({ force: true });
  } finally {
    if (button) {
      button.disabled = false;
      button.textContent = "Rebuild Package";
    }
  }
}

function isQaRepairRequest(request) {
  // Recognize older button requests too, so existing failures are visible after reload.
  return request.requestKind === "QaRepair"
    || (request.allowEdits && /^Fix the failed QA issues for /i.test(request.instruction || ""));
}

function setQaRepairState(job, state) {
  qaRepairStates.set(job.id, state);
  renderQaRepairStatus(job);
}

function syncQaRepairRequests(job, requests) {
  const previous = qaRepairStates.get(job.id);
  // A connection/start error belongs to this click, not to an older stored request.
  if (previous?.local) return;
  // A repair that ran before the latest full generation was superseded by it;
  // its outcome belongs to the old package, not the book on screen.
  const generationStartedAt = Date.parse(job.progress?.startedAt || "");
  const current = (request) => {
    const createdAt = Date.parse(request.createdAt || "");
    return !Number.isFinite(generationStartedAt) || !Number.isFinite(createdAt) || createdAt >= generationStartedAt;
  };
  const latest = requests.filter(isQaRepairRequest).filter(current)
    .sort((a, b) => String(b.createdAt || "").localeCompare(String(a.createdAt || "")))[0];
  if (!latest) {
    if (previous?.request && !current(previous.request)) {
      qaRepairStates.delete(job.id);
      renderQaRepairStatus(job);
    }
    return;
  }
  if (previous?.request && previous.request.id !== latest.id
      && String(previous.request.createdAt || "") >= String(latest.createdAt || "")) return;
  const request = { ...(previous?.request?.id === latest.id ? previous.request : {}), ...latest };
  let phase = "warning";
  let busy = false;
  let message;
  if (isAiRequestActive(request)) {
    phase = "running";
    busy = true;
    message = `QA repair is running. ${request.currentAction || "Codex is reviewing and editing this book."} The package will rebuild afterward; QA has not passed yet.`;
  } else if (request.status === "Failed") {
    phase = "failed";
    message = `QA repair failed. ${request.statusDetail || "Open the repair conversation or error log for the reason."} Partial edits may exist; review them before retrying.`;
  } else if (request.failureKind === "sandbox") {
    // Codex answered politely but never had write access; nothing was edited.
    phase = "failed";
    message = `QA repair could not edit this book. ${request.statusDetail || "Codex ran without file-editing access."} Run Test connection, then retry.`;
  } else if (/rebuild (failed|skipped|was not confirmed)/i.test(request.postProcessStatus || "")) {
    phase = /was not confirmed/i.test(request.postProcessStatus) ? "warning" : "failed";
    message = `Codex finished, but exports were not rebuilt successfully. ${request.postProcessStatus}`;
  } else if (/rebuild queued/i.test(request.postProcessStatus || "")) {
    // A queued rebuild that never reported back must not disable repairs forever.
    const queuedAt = Date.parse(request.postProcessedAt || request.completedAt || request.createdAt || "");
    const stale = Number.isFinite(queuedAt) && Date.now() - queuedAt > 15 * 60 * 1000 && !activeStatuses.has(job.status);
    phase = stale ? "warning" : "running";
    busy = !stale;
    message = stale
      ? "Codex finished, but the package rebuild for this request was not confirmed. A later generation or rebuild supersedes it; use Rebuild Package if its edits still matter."
      : "Codex finished. The package rebuild and QA checks are still pending.";
  } else if (/package rebuilt/i.test(request.postProcessStatus || "")) {
    const passed = String(job.qaSummary?.status || "").toUpperCase() === "PASS";
    phase = passed ? "complete" : "warning";
    message = passed
      ? "Repair and package rebuild finished. Current automated QA: PASS. Human review and publication approvals are still required."
      : `Repair and package rebuild finished, but current QA is ${job.qaSummary?.status || "not verified"}. Review the quality reports; this book is not cleared.`;
  } else {
    message = "Codex finished, but a successful package rebuild has not been confirmed. Review the conversation and rebuild the package before relying on its exports.";
  }
  setQaRepairState(job, { phase, busy, message, request });
}

function renderQaRepairStatus(job, node = findRenderedJobNode(job.id)) {
  if (!node) return;
  const state = qaRepairStates.get(job.id);
  const button = node.querySelector(".qa-repair-button");
  const busy = state?.busy || (job.aiRequests || []).some(isAiRequestActive);
  if (button) {
    button.disabled = Boolean(busy);
    button.textContent = state?.phase === "checking" ? "Checking connection..."
      : state?.phase === "starting" ? "Starting QA fix..."
      : busy ? "Codex is working..." : "Fix QA with Codex";
  }
  let panel = node.querySelector(".qa-repair-status");
  if (!panel) {
    panel = makeElement("div", "qa-repair-status");
    panel.setAttribute("role", "status");
    panel.setAttribute("aria-live", "polite");
    node.querySelector(".job-actions").after(panel);
  }
  panel.hidden = !state;
  if (!state) return;
  panel.dataset.phase = state.phase;
  panel.textContent = "";
  panel.append(makeElement("p", "", state.message));
  if (state.request) {
    panel.append(makeElement("small", "", `Request ${state.request.id} | ${state.request.status || "Running"}`));
    const conversation = makeElement("button", "secondary", "View repair conversation");
    conversation.type = "button";
    conversation.addEventListener("click", () => {
      selectedBookChatJobId = job.id;
      bookChatPanel.hidden = false;
      bookChatPanel.scrollIntoView({ behavior: "smooth", block: "start" });
      aiRequestCache.clear();
      loadBookChat({ job, showLoading: true, forceScroll: true }).catch((error) => { bookChatStatus.textContent = error.message; });
    });
    panel.append(conversation);
    if (busy) {
      // A hung Codex run otherwise blocks every action on this book, deletion included.
      const stop = makeElement("button", "secondary", "Stop Codex request");
      stop.type = "button";
      stop.addEventListener("click", async () => {
        if (!window.confirm("Stop this Codex request? Edits it already saved stay on disk, and no rebuild runs automatically.")) return;
        stop.disabled = true;
        try {
          await api(`/api/jobs/${job.id}/ai-requests/${state.request.id}/stop`, { method: "POST", body: "{}" });
          qaRepairStates.delete(job.id);
          aiRequestCache.clear();
          await loadJobs({ force: true, focusJobId: job.id });
        } catch (error) {
          stop.disabled = false;
          reportJobActionError(job, error.message);
        }
      });
      panel.append(stop);
    }
    if (state.request.errorUrl) {
      const log = makeElement("a", "", "Open repair log");
      log.href = state.request.errorUrl;
      panel.append(log);
    }
  }
}

async function startQaRepair(job) {
  if (!job?.id) return;
  if (qaRepairStates.get(job.id)?.busy) return;
  if (bookChatSubmissionPending || bookChatResetPending || codexConnectionTestPending
      || bookChatHasRunningRequests || (job.aiRequests || []).some(isAiRequestActive)) {
    setQaRepairState(job, { phase: "warning", local: true, message: "Codex or a connection check is already busy. Wait for it to finish before starting a QA repair." });
    return;
  }
  const chatSessionId = bookChatSessions.get(job.id) || job.chatSessionId || "legacy";
  bookChatSubmissionPending = true;
  syncBookChatComposer();
  setQaRepairState(job, { phase: "checking", local: true, busy: true, message: "Checking the Codex connection before editing this book (up to 25 seconds)..." });
  try {
    if ((!codexAssistantAvailable || Date.now() >= codexConnectionExpiresAt) && !await testBookChatConnection()) {
      throw new Error(`Connection failed. ${codexConnectionMessage} No repair request was started.`);
    }
    if (getSelectedBookChatJob()?.id !== job.id) throw new Error("The selected book changed. Return to the intended book and start the repair there. No repair request was started.");
    setQaRepairState(job, { phase: "starting", local: true, busy: true, message: "Starting the QA repair for this book..." });
    const request = await api(`/api/jobs/${job.id}/ai-requests`, {
      method: "POST",
      body: JSON.stringify({
        instruction: buildQaRepairInstruction(job),
        scope: "Package",
        chapterId: "",
        allowEdits: true,
        includeHistory: false,
        chatSessionId,
        requestKind: "QaRepair"
      })
    });
    // Keep the accepted request visible even if the user navigated during POST.
    setQaRepairState(job, { request: { ...request, requestKind: "QaRepair" }, busy: true, phase: "running", message: "QA repair started. Codex is editing this book; the package will rebuild afterward. QA has not passed yet." });
    aiRequestCache.clear();
    renderedBookChatThreadSignature = "";
    if (selectedBookChatJobId === job.id) {
      bookChatHasRunningRequests = true;
      bookChatStatus.textContent = "QA repair started. Progress and failures also appear beside Fix QA with Codex.";
      await loadBookChat({ job, refreshScope: false, showLoading: true, forceScroll: true });
    }
  } catch (error) {
    setQaRepairState(job, { phase: "failed", local: true, message: error.message });
  } finally {
    bookChatSubmissionPending = false;
    syncBookChatComposer();
  }
}

async function refreshJobArtifacts(jobId, button) {
  if (button) button.disabled = true;
  try {
    await api(`/api/jobs/${jobId}/refresh-artifacts`, { method: "POST", body: "{}" });
    visualManifestCache.clear();
    codexPromptCache.clear();
    chapterManifestCache.clear();
    aiRequestCache.clear();
    await loadJobs({ force: true });
  } finally {
    if (button) button.disabled = false;
  }
}

async function updateJobLifecycle(jobId, state, button) {
  if (button) button.disabled = true;
  try {
    await api(`/api/jobs/${jobId}/lifecycle`, {
      method: "POST",
      body: JSON.stringify({ state })
    });
    await loadJobs({ force: true });
  } finally {
    if (button) button.disabled = false;
  }
}

function isBookDeletionBlocked(job) {
  return isJobProcessing(job) || (job.aiRequests || []).some(request => activeStatuses.has(request.status));
}

function appendDeleteBookAction(actions, job) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "danger delete-book-button";
  button.textContent = "Delete book";
  button.disabled = isBookDeletionBlocked(job);
  button.title = button.disabled ? "Wait for generation or Codex work to finish before deleting." : "Permanently remove this book from Book Studio.";
  button.addEventListener("click", () => deleteBookJob(job, button));
  actions.append(button);
}

async function deleteBookJob(job, button) {
  if (button?.disabled || isBookDeletionBlocked(job)) return;
  const label = job.courseCode || job.id;
  const typed = window.prompt(`Delete "${job.title || label}"?\n\nThis permanently removes the book, its chat history, and its Book Studio-managed uploads, generated files, and logs. Original documents, downloaded copies, and packages outside this book's managed folders are kept. This cannot be undone in the app.\n\nType ${label} to confirm.`);
  if (typed !== label) {
    return;
  }

  if (button) {
    button.disabled = true;
    button.textContent = "Deleting...";
  }
  try {
    await api(`/api/jobs/${job.id}/delete`, {
      method: "POST",
      body: JSON.stringify({ deleteFiles: true })
    });
    if (focusedJobId === job.id) {
      setFocusedJob("");
    }
    visualManifestCache.clear();
    codexPromptCache.clear();
    chapterManifestCache.clear();
    aiRequestCache.clear();
    await loadJobs({ force: true });
  } catch (error) {
    // A duplicate entry, an imported package, or a linked folder can share
    // files with another book. The entry can still leave the library.
    const sharesFiles = /uses these files|linked folder|outside its managed storage/i.test(error.message || "");
    if (sharesFiles && window.confirm(`${error.message}\n\nRemove "${job.title || label}" from your library anyway and keep every file on disk?`)) {
      try {
        await api(`/api/jobs/${job.id}/delete`, {
          method: "POST",
          body: JSON.stringify({ deleteFiles: false })
        });
        if (focusedJobId === job.id) setFocusedJob("");
        visualManifestCache.clear();
        codexPromptCache.clear();
        chapterManifestCache.clear();
        aiRequestCache.clear();
        await loadJobs({ force: true });
        return;
      } catch (removeError) {
        window.alert(`Could not remove the book from the library: ${removeError.message}`);
      }
    } else if (!sharesFiles) {
      window.alert(`Could not complete deletion: ${error.message}`);
    }
  } finally {
    if (button) {
      button.disabled = false;
      button.textContent = "Delete book";
    }
  }
}

function renderPackageMeta() {
  const selected = availablePackages.find((item) => item.outputFolder === packageSelect.value);
  if (!selected) {
    packageMeta.textContent = "";
    return;
  }

  const format = selected.packageFormat?.status || "Unknown";
  packageMeta.textContent = `${selected.relativePath} | ${format} package | ${selected.pngCount || 0} PNG | ${selected.svgCount || 0} SVG | Updated ${formatDate(selected.modifiedAt)}`;
}

function renderPackages(packages) {
  const previous = packageSelect.value;
  availablePackages = packages || [];
  packageSelect.textContent = "";

  if (!availablePackages.length) {
    const option = document.createElement("option");
    option.value = "";
    option.textContent = "No generated packages found";
    packageSelect.append(option);
    packageSelect.disabled = true;
    importButton.disabled = true;
    renderPackageMeta();
    return;
  }

  packageSelect.disabled = false;
  importButton.disabled = false;
  for (const item of availablePackages) {
    const option = document.createElement("option");
    option.value = item.outputFolder;
    const code = item.courseCode ? `${item.courseCode}: ` : "";
    const title = item.title || item.name || item.label || "Untitled package";
    option.textContent = `${code}${title}`;
    option.title = item.relativePath || item.outputFolder || "";
    packageSelect.append(option);
  }
  if (previous && availablePackages.some((item) => item.outputFolder === previous)) {
    packageSelect.value = previous;
  }
  renderPackageMeta();
}

async function loadPackages() {
  setImportStatus("Scanning packages...");
  const data = await api("/api/packages");
  renderPackages(data.packages || []);
  setImportStatus("");
}

async function loadAppVersion() {
  if (!appVersion) return;
  try {
    const response = await fetch("/version.json", { cache: "no-store" });
    if (!response.ok) throw new Error("Version unavailable");
    const version = await response.json();
    const product = version.product || "Book Studio ID";
    const number = version.version ? `v${version.version}` : "";
    appVersion.textContent = [product, number].filter(Boolean).join(" ");
    appVersion.title = version.buildDate ? `Build date: ${version.buildDate}` : appVersion.textContent;
  } catch {
    appVersion.textContent = "Book Studio ID v2026.09.11.1";
  }
}

// Settings > Updates: git-based self-update for cloned installs.
const updatesStatus = document.getElementById("updatesStatus");
const updatesChanges = document.getElementById("updatesChanges");
const checkUpdatesButton = document.getElementById("checkUpdates");
const applyUpdateButton = document.getElementById("applyUpdate");
const updatesProgress = document.getElementById("updatesProgress");
const updatesLog = document.getElementById("updatesLog");
const updateBadge = document.getElementById("updateBadge");
let updatePollTimer = 0;
let updateInProgress = false;

function renderUpdateStatus(status) {
  const available = Boolean(status.updateAvailable);
  updatesStatus.className = `codex-status ${available ? "warning" : (status.isRepository && status.fetched ? "ready" : "")}`;
  updatesStatus.textContent = status.message || "";
  updatesChanges.textContent = "";
  for (const line of status.changes || []) updatesChanges.append(makeElement("li", "", line));
  updatesChanges.hidden = !(status.changes || []).length;
  applyUpdateButton.hidden = !available;
  applyUpdateButton.disabled = !status.canUpdate || updateInProgress;
  updateBadge.hidden = !available;
  updateBadge.textContent = available ? `Update available${status.latestVersion ? `: v${status.latestVersion}` : ""}` : "";
}

async function loadUpdateStatus(fetchRemote) {
  checkUpdatesButton.disabled = true;
  if (fetchRemote) {
    updatesStatus.className = "codex-status";
    updatesStatus.textContent = "Contacting the update server...";
  }
  try {
    const status = await api(`/api/updates/status${fetchRemote ? "?fetch=1" : ""}`);
    renderUpdateStatus(status);
    return status;
  } catch (error) {
    updatesStatus.className = "codex-status warning";
    updatesStatus.textContent = `Could not check for updates: ${error.message}`;
    return null;
  } finally {
    checkUpdatesButton.disabled = updateInProgress;
  }
}

function showUpdateProgress(status, message, logTail) {
  updatesProgress.hidden = false;
  updatesProgress.dataset.phase = status === "Completed" ? "complete" : status === "Failed" ? "failed" : "running";
  updatesProgress.querySelector("p").textContent = message || "";
  updatesLog.textContent = (logTail || []).join("\n");
  updatesLog.hidden = !(logTail || []).length;
}

function pollUpdateProgress() {
  clearTimeout(updatePollTimer);
  let wentOffline = false;
  const tick = async () => {
    try {
      const progress = await api("/api/updates/progress");
      if (wentOffline) {
        // The updated server is back; load the new client.
        showUpdateProgress("Completed", `Book Studio v${progress.installedVersion || ""} is running. Reloading...`, progress.logTail);
        setTimeout(() => location.reload(), 1500);
        return;
      }
      showUpdateProgress(progress.status, progress.message, progress.logTail);
      if (progress.status === "Completed") {
        updateInProgress = false;
        if (progress.restart) setTimeout(() => location.reload(), 1500);
        else { checkUpdatesButton.disabled = false; loadUpdateStatus(false).catch(() => {}); }
        return;
      }
      if (progress.status === "Failed") {
        updateInProgress = false;
        checkUpdatesButton.disabled = false;
        applyUpdateButton.disabled = false;
        return;
      }
    } catch {
      wentOffline = true;
      showUpdateProgress("Running", "Book Studio is restarting. This page reloads automatically when it is back.", []);
    }
    updatePollTimer = setTimeout(tick, 2000);
  };
  tick();
}

async function applyUpdate() {
  if (updateInProgress) return;
  updateInProgress = true;
  applyUpdateButton.disabled = true;
  checkUpdatesButton.disabled = true;
  showUpdateProgress("Running", "Starting the update...", []);
  try {
    await api("/api/updates/apply", { method: "POST", body: "{}" });
    pollUpdateProgress();
  } catch (error) {
    updateInProgress = false;
    showUpdateProgress("Failed", error.message, []);
    applyUpdateButton.disabled = false;
    checkUpdatesButton.disabled = false;
  }
}

// Settings > Install location: warn early about paths that will fail Windows' 260-character limit.
const installStatus = document.getElementById("installStatus");
const installBadge = document.getElementById("installBadge");
async function loadInstallStatus() {
  try {
    const health = await api("/api/health");
    const warning = health.installPathWarning || "";
    installStatus.className = `codex-status ${warning ? "warning" : "ready"}`;
    installStatus.textContent = warning || `Installed at ${health.installPath} (${health.installPathLength} characters). This location is fine.`;
    installBadge.hidden = !warning;
  } catch (error) {
    installStatus.className = "codex-status";
    installStatus.textContent = `Could not read the install location: ${error.message}`;
  }
}
installBadge.addEventListener("click", () => {
  showView("settings");
  document.getElementById("installHeading").scrollIntoView({ behavior: "smooth", block: "start" });
});

checkUpdatesButton.addEventListener("click", () => loadUpdateStatus(true));
applyUpdateButton.addEventListener("click", () => applyUpdate());
updateBadge.addEventListener("click", () => {
  showView("settings");
  document.getElementById("updatesHeading").scrollIntoView({ behavior: "smooth", block: "start" });
});

async function importSelectedPackage() {
  const outputFolder = packageSelect.value;
  if (!outputFolder) {
    throw new Error("Choose a generated package.");
  }

  setImportStatus("Importing package...");
  importButton.disabled = true;
  try {
    const importedJob = await api("/api/packages/import", {
      method: "POST",
      body: JSON.stringify({ outputFolder })
    });
    if (importedJob?.id) {
      setFocusedJob(importedJob.id);
      showView("active-book");
    }
    visualManifestCache.clear();
    codexPromptCache.clear();
    chapterManifestCache.clear();
    aiRequestCache.clear();
    await loadJobs({ force: true, focusJobId: importedJob?.id });
    setImportStatus(importedJob?.courseCode
      ? `${importedJob.courseCode} package imported and selected.`
      : "Package imported and selected.");
  } finally {
    importButton.disabled = false;
  }
}

async function importPackageZip() {
  const file = packageZipInput?.files?.[0];
  if (!file) {
    throw new Error("Choose a generated package .zip file.");
  }
  if (!file.name.toLowerCase().endsWith(".zip")) {
    throw new Error("Package import expects a .zip file.");
  }

  setImportStatus("Importing ZIP package...");
  importZipButton.disabled = true;
  importButton.disabled = true;
  try {
    const contentBase64 = await readFileAsBase64(file);
    const importedJob = await api("/api/packages/import-zip", {
      method: "POST",
      body: JSON.stringify({
        fileName: file.name,
        contentBase64
      })
    });
    if (importedJob?.id) {
      setFocusedJob(importedJob.id);
      showView("active-book");
    }
    visualManifestCache.clear();
    codexPromptCache.clear();
    chapterManifestCache.clear();
    aiRequestCache.clear();
    if (packageZipInput) packageZipInput.value = "";
    await Promise.all([loadJobs({ force: true, focusJobId: importedJob?.id }), loadPackages()]);
    setImportStatus(importedJob?.courseCode
      ? `${importedJob.courseCode} ZIP package imported and selected.`
      : "ZIP package imported and selected.");
  } finally {
    importZipButton.disabled = false;
    importButton.disabled = false;
  }
}

function renderCodexStatus(status) {
  codexAssistantAvailable = Boolean(status.available);
  codexConnectionTestedAt = status.connectionTestedAt || "";
  codexConnectionExpiresAt = status.connectionTestedAt ? Date.parse(status.connectionTestedAt) + 10 * 60 * 1000 : 0;
  codexConnectionMessage = status.available ? "The previous connection test expired." : status.connectionMessage || (status.notes || []).slice(-1)[0] || status.loginStatus || "Check the connection before sending.";
  const state = status.available ? "Connection tested" : status.installed ? status.loginStatus : "Optional assistant not installed";
  codexStatus.className = status.available ? "codex-status ready" : "codex-status warning";
  codexStatus.textContent = `${state}${status.version ? ` | ${status.version}` : ""}`;
  if (codexPathInput && status.commandPath) codexPathInput.value = status.commandPath;
  codexLoginCommand.textContent = status.loginCommand || "codex login";
  codexAppCommand.textContent = status.appCommand || "codex app .";

  codexNotes.textContent = "";
  const notes = [];
  if (!status.available) notes.push("Format previews and manual editing work without Codex. AI drafting and chat require a successful Test connection.");
  if (status.discovery) notes.push(`Discovery: ${status.discovery}`);
  if (status.commandPath) notes.push(`Command: ${status.commandPath}`);
  if (status.profilePath) notes.push(`Codex profile: ${status.profilePath}`);
  if (status.connectionTestedAt) notes.push(`Last connection result: ${formatDate(status.connectionTestedAt)}`);
  const recovery = document.getElementById("codexRecoveryCommand");
  if (recovery) recovery.textContent = [status.logoutCommand, status.loginCommand].filter(Boolean).join("\n");
  const testButton = document.getElementById("testCodexConnection");
  if (testButton) testButton.disabled = codexConnectionTestPending;
  if (status.loginOutput) notes.push(status.loginOutput);
  for (const note of status.notes || []) notes.push(note);

  for (const note of notes) {
    const item = makeElement("div", "codex-note", note);
    codexNotes.append(item);
  }
  const connectionDetails = document.getElementById("bookChatConnectionDetails");
  connectionDetails.hidden = !status.connectionLogPreview || status.available;
  connectionDetails.querySelector("pre").textContent = status.connectionLogPreview || "";
  connectionDetails.open = !connectionDetails.hidden;
  renderBookChatJobOptions();
}

async function loadCodexStatus() {
  codexStatus.className = "codex-status";
  codexStatus.textContent = "Checking Codex...";
  codexNotes.textContent = "";
  const status = await api("/api/codex/status");
  renderCodexStatus(status);
}

async function testBookChatConnection() {
  if (codexConnectionTestPending) return false;
  codexConnectionTestPending = true;
  syncBookChatComposer();
  codexStatus.className = "codex-status";
  codexStatus.textContent = "Testing a real Codex response (up to 25 seconds)…";
  try {
    const status = await api("/api/codex/test", {method:"POST", body:"{}"});
    renderCodexStatus(status);
    bookChatStatus.textContent = status.available
      ? `Connection test passed at ${formatDate(status.connectionTestedAt)}. You can send your message now.`
      : `Connection test failed. ${codexConnectionMessage} Your message has not been sent.`;
    return Boolean(status.available);
  } catch (error) {
    codexAssistantAvailable = false;
    codexConnectionMessage = error.message;
    bookChatStatus.textContent = `Connection test failed: ${error.message}. Your message has not been sent.`;
    codexStatus.className = "codex-status warning"; codexStatus.textContent = error.message;
    return false;
  } finally { codexConnectionTestPending = false; syncBookChatComposer(); }
}
document.getElementById("testCodexConnection")?.addEventListener("click", () => testBookChatConnection());
bookChatTestConnection.addEventListener("click", () => testBookChatConnection());
document.getElementById("bookChatConnectionHelp").addEventListener("click", (event) => {
  event.preventDefault();
  showView("settings");
  document.getElementById("codexHeading").scrollIntoView({ behavior: "smooth", block: "start" });
});

async function saveCodexPathOverride(path) {
  if (codexPathStatus) codexPathStatus.textContent = path ? "Saving Codex path..." : "Clearing Codex path...";
  if (saveCodexPath) saveCodexPath.disabled = true;
  if (clearCodexPath) clearCodexPath.disabled = true;
  try {
    await api("/api/codex/path", {
      method: "POST",
      body: JSON.stringify({ path })
    });
    if (!path && codexPathInput) codexPathInput.value = "";
    if (codexPathStatus) codexPathStatus.textContent = path ? "Codex path saved." : "Codex path cleared.";
    await loadCodexStatus();
  } finally {
    if (saveCodexPath) saveCodexPath.disabled = false;
    if (clearCodexPath) clearCodexPath.disabled = false;
  }
}

function setWizardStep(step) {
  wizardStep = Math.max(1, Math.min(3, step));
  document.querySelectorAll("[data-wizard-step]").forEach((panel) => {
    panel.hidden = Number(panel.dataset.wizardStep) !== wizardStep;
  });
  document.querySelectorAll("[data-wizard-indicator]").forEach((indicator) => {
    const number = Number(indicator.dataset.wizardIndicator);
    indicator.classList.toggle("current", number === wizardStep);
    indicator.classList.toggle("complete", number < wizardStep);
  });
  const labels = ["Course details", "Source documents", "Production preferences"];
  wizardStepLabel.textContent = `Step ${wizardStep} of 3 · ${labels[wizardStep - 1]}`;
  newBookBack.hidden = wizardStep === 1;
  newBookNext.hidden = wizardStep === 3;
  generateButton.hidden = wizardStep !== 3;
}

function validateWizardStep() {
  if (wizardStep === 1) {
    const courseCode = form.elements.courseCode;
    const title = form.elements.title;
    if (!courseCode.value.trim()) { courseCode.focus(); setStatus("Enter the course code to continue."); return false; }
    if (!title.value.trim()) { title.focus(); setStatus("Enter a book title to continue."); return false; }
  }
  if (wizardStep === 2) {
    const files = form.elements.files;
    const primary = form.elements.primaryFileIndex;
    if (!files.files?.length) { files.focus(); setStatus("Upload at least one course document to continue."); return false; }
    if (!primary.value) { primary.focus(); setStatus("Choose the authoritative blueprint or objectives file to continue."); return false; }
    const kind = form.elements.courseDocumentKind;
    if (!kind.value) { kind.focus(); setStatus("Say whether that document is a curriculum draft or an ebook-ready course file to continue."); return false; }
  }
  setStatus("");
  return true;
}

function openNewBook() {
  currentView = "new-book";
  setWizardStep(1);
  showView("new-book");
  form.elements.courseCode.focus();
}

function openBooksHome() {
  showView("books");
}

function openImportPanel() {
  openBooksHome();
  const panel = document.querySelector(".library-import");
  if (panel) panel.open = true;
  panel?.scrollIntoView({ behavior: "smooth", block: "nearest" });
}

newBookButton.addEventListener("click", openNewBook);
libraryNewBook.addEventListener("click", openNewBook);
homeNewBook.addEventListener("click", openNewBook);
cancelNewBook.addEventListener("click", openBooksHome);
booksButton.addEventListener("click", openBooksHome);
activeBookBack.addEventListener("click", openBooksHome);
// The cloud half of Settings.
//
// Reaching Book Studio through the web and reaching it on your own PC are the
// same app, so Settings has to answer "which computer is this running on, and
// is it connected?" in the place someone already looks for it. Nothing here
// exists when Book Studio is opened locally: there is no account to show and no
// bridge to test.
const cloudPanel = document.querySelector("#cloudPanel");
const cloudAccount = document.querySelector("#cloudAccount");
const cloudMachines = document.querySelector("#cloudMachines");

function reachedThroughTheCloud() {
  return !["localhost", "127.0.0.1", "::1"].includes(location.hostname);
}

function describeLastSeen(seenAt) {
  const seen = Date.parse(seenAt || "");
  if (!seen) return "";
  const seconds = Math.max(0, Math.round((Date.now() - seen) / 1000));
  if (seconds < 90) return "just now";
  if (seconds < 3600) return Math.round(seconds / 60) + " minutes ago";
  return new Date(seen).toLocaleString();
}

async function loadCloudSettings() {
  if (!cloudPanel || !reachedThroughTheCloud()) return;
  cloudPanel.hidden = false;
  try {
    const identity = await api("/cloud/api/identity");
    cloudAccount.textContent = identity.email
      ? "Signed in as " + identity.email + "."
      : "Signed in.";
  } catch (error) {
    cloudAccount.textContent = "Could not read your account: " + error.message;
  }
  try {
    const status = await api("/cloud/api/runner/status");
    const machines = status.machines || [];
    if (!machines.length) {
      cloudMachines.innerHTML = "<dt>No computer</dt><dd>" + escapeHtml(status.detail || "Nothing of yours is running Book Studio.") + "</dd>";
      return;
    }
    cloudMachines.innerHTML = machines.map((machine) => {
      const codex = machine.codex || {};
      const ready = codex.status === "Connected";
      const state = ready ? "Ready" : (codex.status === "Unknown" ? "Codex not checked yet" : "Codex " + String(codex.status || "unknown").toLowerCase());
      // A computer names itself, and its Codex describes its own state, so
      // both are text here, never markup.
      return "<dt>" + escapeHtml(machine.runnerName || machine.label || "unnamed computer") + "</dt><dd>" +
        escapeHtml(state) + (codex.version ? " - " + escapeHtml(codex.version) : "") +
        " - last heard from " + escapeHtml(describeLastSeen(machine.seenAt)) +
        (machine.version ? "<br>Book Studio " + escapeHtml(machine.version) : "") +
        (ready ? "" : "<br>" + escapeHtml(codex.detail || "")) + "</dd>";
    }).join("");
  } catch (error) {
    cloudMachines.innerHTML = "<dt>Connection</dt><dd>Could not check: " + escapeHtml(error.message) + "</dd>";
  }
}

// The guide lives on the web site, so the link to it appears only when Book
// Studio is reached through the web; opened on the PC itself there is nowhere
// for it to go.
const guideLink = document.querySelector("#guideLink");
if (guideLink && reachedThroughTheCloud()) guideLink.hidden = false;

const refreshCloudButton = document.querySelector("#refreshCloud");
if (refreshCloudButton) {
  refreshCloudButton.addEventListener("click", () => {
    cloudMachines.innerHTML = "<dt>Checking</dt><dd>Asking the cloud which computers are running...</dd>";
    loadCloudSettings();
  });
}
const cloudSignOutButton = document.querySelector("#cloudSignOut");
if (cloudSignOutButton) {
  cloudSignOutButton.addEventListener("click", async () => {
    try { await api("/cloud/api/logout", { method: "POST" }); } catch (error) { /* the cookie goes either way */ }
    location.href = "/cloud/login";
  });
}

settingsButton.addEventListener("click", () => { showView("settings"); loadCloudSettings(); });
settingsBack.addEventListener("click", openBooksHome);
homeImportBook.addEventListener("click", openImportPanel);
newBookNext.addEventListener("click", () => {
  if (validateWizardStep()) setWizardStep(wizardStep + 1);
});
newBookBack.addEventListener("click", () => {
  setStatus("");
  setWizardStep(wizardStep - 1);
});
setWizardStep(1);

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  generateButton.disabled = true;
  setStatus("Uploading source files...");

  try {
    const formData = new FormData(form);
    const selectedFiles = Array.from(form.elements.files.files || []);
    if (!selectedFiles.length) {
      throw new Error("Choose at least one source file.");
    }

    const files = [];
    for (const file of selectedFiles) {
      setStatus(`Reading ${file.name}...`);
      files.push({
        name: file.name,
        size: file.size,
        contentBase64: await readFileAsBase64(file)
      });
    }

    const payload = {
      courseCode: formData.get("courseCode"),
      title: formData.get("title"),
      specialInstructions: formData.get("specialInstructions"),
      primaryFileIndex: Number(formData.get("primaryFileIndex")),
      sourceMode: formData.get("sourceMode") || "Assigned",
      allowAdditionalResearch: formData.get("allowAdditionalResearch") === "on",
      readingLevel: Number(formData.get("readingLevel") || 8),
      courseDocumentKind: formData.get("courseDocumentKind") || "",
      requiredSources: formData.get("requiredSources") || "",
      imageContext: formData.get("imageContext") || "Generic",
      imageInstructions: formData.get("imageInstructions") || "",
      maxResearchPerChapter: Number(formData.get("maxResearchPerChapter") || 3),
      skipResearch: formData.get("skipResearch") === "on",
      skipOpenStaxFetch: formData.get("skipOpenStaxFetch") === "on",
      useCodexDrafting: formData.get("useCodexDrafting") === "on",
      useCodexImages: formData.get("useCodexImages") === "on",
      files
    };

    setStatus("Creating job...");
    const job = await api("/api/jobs", { method: "POST", body: JSON.stringify(payload) });
    showView("active-book");
    setFocusedJob(job.id);
    // A curriculum draft is planned only from outcomes the designer approved,
    // so the format preview waits for that review instead of being built on
    // the draft's delivery objectives and then rebuilt.
    const needsOutcomeReview = payload.courseDocumentKind === "CurriculumDraft";
    if (needsOutcomeReview) {
      setStatus("Reviewing course objectives...");
      await loadJobs({ force: true, focusJobId: job.id });
    } else {
      setStatus("Creating format preview...");
      await runJob(job.id, "Blueprint");
    }
    form.reset();
    form.elements.maxResearchPerChapter.value = 3;
    form.elements.useCodexDrafting.checked = true;
    form.elements.useCodexImages.checked = true;
    refreshSourceChoices();
    setWizardStep(1);
    setStatus(needsOutcomeReview
      ? "Review the course objectives and learning objectives below. The book is planned from what you approve."
      : "Format preview generation started. Review it below when it is ready before generating the book.");
  } catch (error) {
    setStatus(error.message);
  } finally {
    generateButton.disabled = false;
  }
});

function refreshSourceChoices() {
  const select = document.getElementById("primarySourceSelect");
  const files = Array.from(form.elements.files.files || []);
  if (select) {
    select.replaceChildren();
    if (files.length !== 1) select.append(new Option(files.length ? "Select the authoritative blueprint" : "Choose files first", ""));
    files.forEach((file, index) => select.append(new Option(`${index + 1}. ${file.name}`, String(index))));
  }
  const uploadedOnly = form.elements.sourceMode.value !== "Discovery";
  for (const name of ["skipResearch", "skipOpenStaxFetch", "maxResearchPerChapter"]) {
    form.elements[name].disabled = uploadedOnly;
    if (uploadedOnly && form.elements[name].type === "checkbox") form.elements[name].checked = true;
  }
}
form.elements.files.addEventListener("change", refreshSourceChoices);
form.elements.sourceMode.addEventListener("change", () => {
  const uploadedOnly = form.elements.sourceMode.value !== "Discovery";
  for (const name of ["skipResearch", "skipOpenStaxFetch", "maxResearchPerChapter"]) {
    form.elements[name].disabled = uploadedOnly;
    if (form.elements[name].type === "checkbox") form.elements[name].checked = uploadedOnly;
  }
});
refreshSourceChoices();

refreshJobsButton.addEventListener("click", () => {
  loadJobs({ force: true }).catch((error) => setStatus(error.message));
});

refreshPackagesButton.addEventListener("click", () => {
  loadPackages().catch((error) => setImportStatus(error.message));
});

refreshCodexButton.addEventListener("click", () => {
  loadCodexStatus().catch((error) => {
    codexStatus.className = "codex-status warning";
    codexStatus.textContent = error.message;
  });
});

codexPathForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  try {
    await saveCodexPathOverride(codexPathInput.value.trim());
  } catch (error) {
    codexPathStatus.textContent = error.message;
  }
});

clearCodexPath.addEventListener("click", async () => {
  try {
    await saveCodexPathOverride("");
  } catch (error) {
    codexPathStatus.textContent = error.message;
  }
});

packageSelect.addEventListener("change", renderPackageMeta);

bookChatJobSelect.addEventListener("change", async () => {
  chatLoadGeneration++;
  bookChatHasRunningRequests = false;
  selectedBookChatJobId = bookChatJobSelect.value;
  aiRequestCache.clear();
  renderedBookChatThreadSignature = "";
  bookChatStatus.textContent = "";
  await loadBookChat({ refreshScope: true, showLoading: true });
});

bookChatNew.addEventListener("click", async () => {
  if (bookChatResetPending || bookChatSubmissionPending || bookChatHasRunningRequests) return;
  const job = getSelectedBookChatJob();
  if (!window.confirm("Start a new chat? Previous messages will be excluded from the next conversation. The book and diagnostic logs will be kept. Any unsent draft will be cleared.")) return;
  bookChatResetPending = true;
  chatLoadGeneration++; // Ignore late history responses from the old conversation.
  syncBookChatComposer();
  try {
    if (job) {
      const result = await api(`/api/jobs/${job.id}/chat/reset`, {method:"POST", body:JSON.stringify({sessionId:bookChatSessions.get(job.id) || job.chatSessionId || "legacy"})});
      bookChatSessions.set(job.id, result.sessionId);
      job.chatSessionId = result.sessionId;
    }
    chatLoadGeneration++;
    aiRequestCache.clear();
    if (job) aiPostProcessSignatures.delete(job.id);
    renderedBookChatThreadSignature = "";
    bookChatHasRunningRequests = false;
    bookChatMessage.value = "";
    bookChatAllowEdits.checked = false;
    bookChatScopeSelect.value = "";
    renderAiRequestList(bookChatThread, []);
    bookChatStatus.textContent = "New chat started. Previous messages are excluded; the book is unchanged.";
    bookChatMessage.focus();
  } catch (error) { bookChatStatus.textContent = error.message; }
  finally { bookChatResetPending = false; syncBookChatComposer(); }
});

bookChatForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const job = getSelectedBookChatJob();
  const text = bookChatMessage.value.trim();
  if (bookChatSubmissionPending || bookChatResetPending || codexConnectionTestPending || bookChatHasRunningRequests) return;
  if (!job) {
    bookChatStatus.textContent = "Choose a completed package first.";
    return;
  }
  if (!text) {
    bookChatStatus.textContent = "Type a message for Codex.";
    return;
  }

  const allowEdits = bookChatAllowEdits.checked;
  const selectedChapterId = bookChatScopeSelect.value;
  const chatSessionId = bookChatSessions.get(job.id) || job.chatSessionId || "legacy";
  bookChatSubmissionPending = true;
  syncBookChatComposer();
  const modeText = allowEdits ? "edit mode" : "advice-only mode";
  bookChatStatus.textContent = `Starting Codex in ${modeText}...`;
  try {
    if ((!codexAssistantAvailable || Date.now() >= codexConnectionExpiresAt) && !await testBookChatConnection()) {
      bookChatStatus.textContent = `Message not sent. ${codexConnectionMessage} Your draft is still here. See the latest connection-test details above.`;
      return;
    }
    if (getSelectedBookChatJob()?.id !== job.id) throw new Error("The selected book changed. Review your draft and send it again for the intended book.");
    await api(`/api/jobs/${job.id}/ai-requests`, {
      method: "POST",
      body: JSON.stringify({
        instruction: text,
        scope: selectedChapterId ? "Chapter" : "Package",
        chapterId: selectedChapterId,
        allowEdits,
        includeHistory: true,
        chatSessionId
      })
    });
    aiRequestCache.clear();
    if (bookChatMessage.value.trim() === text) bookChatMessage.value = "";
    bookChatStatus.textContent = allowEdits
      ? "Codex request started with package edits allowed."
      : "Codex request started in advice-only mode; package files will not be changed.";
    await loadBookChat({ job, refreshScope: false, showLoading: true, forceScroll: true });
  } catch (error) {
    bookChatStatus.textContent = error.message;
    if (/connection|sign.in|refresh.token/i.test(error.message)) {
      codexAssistantAvailable = false; codexConnectionMessage = error.message;
    }
  } finally {
    bookChatSubmissionPending = false;
    syncBookChatComposer();
  }
});

importForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  try {
    await importSelectedPackage();
  } catch (error) {
    setImportStatus(error.message);
  }
});

importZipButton.addEventListener("click", async () => {
  try {
    await importPackageZip();
  } catch (error) {
    setImportStatus(error.message);
  }
});

for (const quickButton of document.querySelectorAll(".quick-chat-button")) {
  quickButton.addEventListener("click", () => {
    const job = getSelectedBookChatJob();
    if (!job) {
      bookChatStatus.textContent = "Choose a book before using a quick request.";
      return;
    }
    bookChatMessage.value = quickButton.dataset.chatPrompt || "";
    bookChatMessage.focus();
  });
}

showView("books");
loadAppVersion().catch(() => {});
loadUpdateStatus(false).catch(() => {});
loadInstallStatus().catch(() => {});
loadPackages().catch((error) => setImportStatus(error.message));
loadCodexStatus().catch((error) => {
  codexStatus.className = "codex-status warning";
  codexStatus.textContent = error.message;
});
loadJobs({ force: true }).catch((error) => setStatus(error.message));
setInterval(() => {
  if (!shouldAutoRefreshJobs()) return;
  loadJobs().catch(() => {});
}, 5000);
setInterval(() => {
  pollBookChat().catch(() => {});
}, 2500);
