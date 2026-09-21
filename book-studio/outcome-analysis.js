// Step 0 for a book built from a curriculum draft: review the course
// objectives and learning objectives before anything is planned.
//
// The course objectives belong to the academic team and are shown read-only
// alongside the editor. The learning objectives are what the designer and
// Codex rework. Nothing here writes a manuscript, and nothing is applied until
// the designer approves it.

const outcomeAnalysisPollTimers = new Map();

function stopOutcomeAnalysisPolling(jobId) {
  const timer = outcomeAnalysisPollTimers.get(jobId);
  if (timer) {
    window.clearTimeout(timer);
    outcomeAnalysisPollTimers.delete(jobId);
  }
}

function outcomeAnalysisNeedsReview(job) {
  return String(job?.workflowStage || "") === "outcomes-analysis";
}

function buildOutcomeCatalogFallback(analysis) {
  // With no suggestion yet, start from the course objectives exactly as the
  // curriculum draft states them. Learning objectives are deliberately left
  // empty: Book Studio does not invent them, and the draft's own weekly
  // objectives are shown beside the editor to work from.
  return (analysis.courseObjectives || []).map((record) => `${record.objectiveId}: ${record.objective}`).join("\n");
}

function buildOutcomeAssignmentDefaults(analysis) {
  const suggested = new Map((analysis.assignments || []).map((item) => [Number(item.number), String(item.ids || "")]));
  return (analysis.chapters || []).map((chapter) => ({
    number: Number(chapter.number),
    title: String(chapter.title || ""),
    draftObjectives: chapter.draftObjectives || [],
    ids: suggested.has(Number(chapter.number))
      ? suggested.get(Number(chapter.number))
      : (chapter.courseObjectiveIds || []).join(", ")
  }));
}

function drawApprovedOutcomeReceipt(job, panel) {
  // The approved outcomes are what the whole book is built on, and the
  // reusable course file is the deliverable. Neither may become unreachable
  // once the book moves on to its format preview.
  const state = job.outcomeAnalysis || {};
  const receipt = makeElement("details", "advanced-options");
  receipt.append(makeElement("summary", "", "Approved course objectives and learning objectives"));
  receipt.append(makeElement("p", "hint", `${state.statusDetail || "Approved."}${state.reason ? ` Reason: ${state.reason}` : ""}`));
  const list = makeElement("ul", "");
  for (const record of state.documents || []) {
    const item = makeElement("li", "");
    if (record.fileName) {
      const link = document.createElement("a");
      link.href = `/api/jobs/${job.id}/outcome-analysis/file?name=${encodeURIComponent(record.fileName)}`;
      link.textContent = record.name;
      item.append(link);
    } else {
      item.textContent = record.name;
    }
    list.append(item);
  }
  if (!(state.documents || []).length) list.append(makeElement("li", "", "No outcome documents were recorded for this book."));
  receipt.append(list);
  receipt.append(makeElement("p", "hint", "Upload the ebook-ready course file as the authoritative document for a later book to skip this review."));
  panel.append(receipt);
}

function renderOutcomeAnalysisPanel(job, panel) {
  if (!outcomeAnalysisNeedsReview(job)) {
    stopOutcomeAnalysisPolling(job.id);
    panel.textContent = "";
    delete panel.dataset.loaded;
    delete panel.dataset.analysisFingerprint;
    if (String(job?.outcomeAnalysis?.status || "") !== "Approved") {
      panel.hidden = true;
      return;
    }
    panel.hidden = false;
    drawApprovedOutcomeReceipt(job, panel);
    return;
  }
  panel.hidden = false;
  if (!panel.dataset.loaded) {
    panel.textContent = "";
    panel.append(makeElement("p", "panel-intro", "Loading the course objectives…"));
  }
  refreshOutcomeAnalysisPanel(job, panel).catch((error) => {
    panel.textContent = "";
    panel.append(makeElement("h3", "", "Step 1 · Course objectives and learning objectives"));
    panel.append(makeElement("p", "hint", error.message));
  });
}

function outcomeAnalysisFingerprint(analysis) {
  return [analysis.status, analysis.completedAt, analysis.approvedAt, analysis.errorDetail,
    String(analysis.catalogText || "").length, (analysis.findings || []).length].join("|");
}

async function refreshOutcomeAnalysisPanel(job, panel) {
  const analysis = await api(`/api/jobs/${job.id}/outcome-analysis`);
  // Redraw only when the analysis actually changed. This panel is re-rendered
  // on every poll, and rebuilding it discards whatever the designer has typed
  // into the outcome editor mid-review.
  const fingerprint = outcomeAnalysisFingerprint(analysis);
  if (panel.dataset.loaded !== "true" || panel.dataset.analysisFingerprint !== fingerprint) {
    drawOutcomeAnalysisPanel(job, panel, analysis);
    panel.dataset.analysisFingerprint = fingerprint;
  }
  panel.dataset.loaded = "true";
  stopOutcomeAnalysisPolling(job.id);
  if (analysis.status === "Analyzing") {
    outcomeAnalysisPollTimers.set(job.id, window.setTimeout(() => {
      if (!panel.isConnected) {
        stopOutcomeAnalysisPolling(job.id);
        return;
      }
      refreshOutcomeAnalysisPanel(job, panel).catch(() => {});
    }, 5000));
  }
}

function drawOutcomeAnalysisPanel(job, panel, analysis) {
  panel.textContent = "";

  const heading = makeElement("div", "format-review-heading");
  const headingText = makeElement("div");
  headingText.append(makeElement("h3", "", "Step 1 · Course objectives and learning objectives"));
  headingText.append(makeElement("p", "panel-intro", "This book was created from a curriculum draft. Its course objectives are final and are reproduced word for word. Rework the learning objectives beneath them, assign every outcome to a chapter, and approve. The book is planned from what you approve here."));
  heading.append(headingText, makeElement("span", analysis.status === "Failed" ? "visual-status warning" : "visual-status", analysis.status || "Not analyzed"));
  panel.append(heading);
  if (analysis.statusDetail) panel.append(makeElement("p", "hint", analysis.statusDetail));

  appendOutcomeAnalysisRunner(panel, job, analysis);
  appendOutcomeAnalysisFindings(panel, analysis);
  appendOutcomeAnalysisReference(panel, analysis);
  appendOutcomeAnalysisEditor(panel, job, analysis);
}

function appendOutcomeAnalysisRunner(panel, job, analysis) {
  const runner = makeElement("div", "format-review-guidance");
  runner.append(makeElement("strong", "", analysis.status === "Analyzing" ? "Codex is analyzing the curriculum draft" : "Analyze the curriculum draft"));
  runner.append(makeElement("span", "", "Codex reads the draft, keeps every course objective word for word, rewrites the learning objectives beneath them as measurable LO1.1-style outcomes, and assigns them to chapters. It does not change anything until you approve it. You can also skip the analysis and write the outcomes yourself."));

  const notes = document.createElement("textarea");
  notes.rows = 2;
  notes.maxLength = 4000;
  notes.placeholder = "Optional notes for the analysis: emphasis, audience, anything the draft leaves unclear.";
  const notesLabel = makeElement("label", "");
  notesLabel.append(makeElement("span", "", "Notes for the analysis"), notes);
  runner.append(notesLabel);

  const actions = makeElement("div", "actions");
  const run = makeElement("button", "secondary", analysis.status === "Analyzing" ? "Analysis running…" : analysis.catalogText ? "Analyze again" : "Analyze with Codex");
  run.type = "button";
  run.disabled = analysis.status === "Analyzing";
  const status = makeElement("span", "hint", "");
  status.setAttribute("role", "status");
  run.addEventListener("click", async () => {
    run.disabled = true;
    status.textContent = "Starting the analysis…";
    try {
      await api(`/api/jobs/${job.id}/outcome-analysis/run`, { method: "POST", body: JSON.stringify({ notes: notes.value }) });
      await refreshOutcomeAnalysisPanel(job, panel);
    } catch (error) {
      status.textContent = error.message;
      run.disabled = false;
    }
  });
  actions.append(run, status);
  runner.append(actions);

  if (analysis.promptUrl) {
    const links = makeElement("p", "hint", "");
    for (const [label, url] of [["Analysis prompt", analysis.promptUrl], ["Analysis reply", analysis.responseUrl], ["Analysis log", analysis.errorUrl]]) {
      if (!url) continue;
      const link = document.createElement("a");
      link.href = url;
      link.textContent = label;
      links.append(link, document.createTextNode(" "));
    }
    runner.append(links);
  }
  if (analysis.errorDetail) runner.append(makeElement("p", "hint", analysis.errorDetail));
  panel.append(runner);
}

function appendOutcomeAnalysisFindings(panel, analysis) {
  if (!(analysis.findings || []).length) return;
  const findings = makeElement("details", "advanced-options");
  findings.open = true;
  findings.append(makeElement("summary", "", `Analysis (${analysis.findings.length} note${analysis.findings.length === 1 ? "" : "s"})`));
  const list = makeElement("ul", "");
  for (const finding of analysis.findings) list.append(makeElement("li", "", finding));
  findings.append(list);
  findings.append(makeElement("p", "hint", "These are the analyzer's notes, not applied changes. Nothing below is saved until you approve it."));
  panel.append(findings);
}

function appendOutcomeAnalysisReference(panel, analysis) {
  const reference = makeElement("details", "advanced-options");
  reference.append(makeElement("summary", "", "What the curriculum draft says (read-only)"));
  reference.append(makeElement("p", "hint", "Course objectives are the academic team's wording and cannot be changed here. The weekly objectives below are the draft's own; they are what the analysis reworks."));
  const objectives = makeElement("ul", "");
  for (const record of analysis.courseObjectives || []) objectives.append(makeElement("li", "", `${record.objectiveId}: ${record.objective}`));
  reference.append(makeElement("strong", "", "Course objectives"), objectives);
  for (const chapter of analysis.chapters || []) {
    reference.append(makeElement("strong", "", `Chapter ${chapter.number}: ${chapter.title}`));
    const mapped = makeElement("p", "hint", `Course objectives the draft maps to this week: ${(chapter.courseObjectiveIds || []).join(", ") || "none stated"}`);
    reference.append(mapped);
    const list = makeElement("ul", "");
    for (const record of chapter.draftObjectives || []) {
      list.append(makeElement("li", "", `${record.objectiveId ? `${record.objectiveId}: ` : ""}${record.objective}`));
    }
    if (!(chapter.draftObjectives || []).length) list.append(makeElement("li", "", "No learning objectives stated for this week."));
    reference.append(list);
  }
  panel.append(reference);
}

function appendOutcomeAnalysisEditor(panel, job, analysis) {
  const editor = makeElement("section", "outline-editor-panel");
  editor.setAttribute("aria-label", "Review course objectives and learning objectives");
  editor.append(makeElement("h4", "", "Review and approve"));
  editor.append(makeElement("p", "hint", "Every course objective must appear exactly as the curriculum draft states it. Give each one its learning objectives as LO1.1, LO1.2, and so on. Then assign outcomes to every chapter: naming CO1 assigns all of its learning objectives; name LO1.2 to split one course objective across chapters."));

  if ((analysis.objectiveFidelity || []).length) {
    const warning = makeElement("div", "format-review-guidance");
    warning.append(makeElement("strong", "", "Course objectives do not match the curriculum draft"));
    const list = makeElement("ul", "");
    for (const problem of analysis.objectiveFidelity) list.append(makeElement("li", "", problem.message));
    warning.append(list);
    warning.append(makeElement("span", "", "Fix these lines in the editor below. Approval is refused while a course objective is reworded, missing, or invented."));
    editor.append(warning);
  }
  if (analysis.catalogError) editor.append(makeElement("p", "hint", analysis.catalogError));

  const field = (caption, control) => {
    const label = makeElement("label", "");
    label.append(makeElement("span", "", caption), control);
    editor.append(label);
    return control;
  };

  const text = field("Course objectives and learning objectives", document.createElement("textarea"));
  text.rows = 16;
  text.maxLength = 60000;
  text.placeholder = "CO1: Describe the end-to-end healthcare revenue cycle from registration through collections.\nLO1.1: Describe the major stages of the revenue cycle from patient scheduling through final payment.\nLO1.2: Explain how each revenue cycle department contributes to revenue integrity.";
  text.value = analysis.catalogText || buildOutcomeCatalogFallback(analysis);

  const assignments = buildOutcomeAssignmentDefaults(analysis).map((chapter) => {
    const input = field(`Chapter ${chapter.number}: ${chapter.title} — assigned IDs`, document.createElement("input"));
    input.placeholder = "CO1, CO7 or specific lessons: LO1.1, LO7.2";
    input.maxLength = 3000;
    input.value = chapter.ids;
    return { number: chapter.number, input };
  });

  const reviewer = field("Reviewed by", document.createElement("input"));
  reviewer.maxLength = 150;
  reviewer.value = analysis.reviewedBy || "";
  const reason = field("Source / reason for these outcomes", document.createElement("input"));
  reason.maxLength = 1000;
  reason.value = analysis.reason || "";

  const actions = makeElement("div", "actions");
  const check = makeElement("button", "secondary", "Check outcomes and chapter coverage");
  check.type = "button";
  const approve = makeElement("button", "", "Approve outcomes & plan the book");
  approve.type = "button";
  approve.disabled = true;
  const confirm = field("I reviewed these course objectives and learning objectives and approve them for this book.", document.createElement("input"));
  confirm.type = "checkbox";
  const status = makeElement("p", "hint", "");
  status.setAttribute("role", "status");
  const summary = makeElement("div", "outcome-diff");

  let checked = false;
  let busy = false;
  const inputs = [text, reviewer, reason, ...assignments.map((item) => item.input)];
  const reset = () => {
    checked = false;
    confirm.checked = false;
    approve.disabled = true;
    summary.textContent = "";
    status.textContent = "Changed. Check the outcomes again before approving.";
  };
  [text, ...assignments.map((item) => item.input)].forEach((input) => input.addEventListener("input", reset));
  confirm.addEventListener("change", () => { approve.disabled = busy || !checked || !confirm.checked; });
  const lock = (value) => {
    busy = value;
    check.disabled = value;
    confirm.disabled = value;
    inputs.forEach((input) => { input.readOnly = value; });
    approve.disabled = value || !checked || !confirm.checked;
  };

  const payload = () => ({
    text: text.value,
    assignments: assignments.map((item) => ({ number: item.number, ids: item.input.value }))
  });

  check.addEventListener("click", async () => {
    if (busy) return;
    reset();
    lock(true);
    status.textContent = "Checking the course objectives and chapter coverage…";
    try {
      const result = await api(`/api/jobs/${job.id}/outcome-analysis/preview`, { method: "POST", body: JSON.stringify(payload()) });
      checked = true;
      summary.append(makeElement("p", "", `${result.previousCount} objective(s) in the curriculum draft → ${result.newCount} chapter assignment(s) across ${result.uniqueOutcomes} unique outcome(s).`));
      for (const chapter of result.chapters || []) {
        summary.append(makeElement("h4", "", `Chapter ${chapter.number}: ${chapter.title}`));
        for (const [label, records] of [["Curriculum draft", chapter.previous], ["Approving this", chapter.records]]) {
          summary.append(makeElement("strong", "", label));
          const list = makeElement("ul", "");
          for (const record of records || []) list.append(makeElement("li", "", `${record.objectiveId ? `${record.objectiveId}: ` : ""}${record.objective}`));
          if (!(records || []).length) list.append(makeElement("li", "", "None."));
          summary.append(list);
        }
      }
      status.textContent = "Nothing is saved yet. Review the comparison, enter your name and the reason, then approve.";
    } catch (error) {
      status.textContent = error.message;
    } finally {
      lock(false);
    }
  });

  approve.addEventListener("click", async () => {
    if (busy || !checked || !confirm.checked) return;
    if (!reviewer.value.trim() || !reason.value.trim()) {
      status.textContent = "Enter your name and the source or reason for these outcomes, then check again.";
      return;
    }
    lock(true);
    status.textContent = "Approving the outcomes and starting the format preview…";
    try {
      await api(`/api/jobs/${job.id}/outcome-analysis/apply`, {
        method: "POST",
        body: JSON.stringify({ ...payload(), confirm: true, reviewedBy: reviewer.value.trim(), reason: reason.value.trim() })
      });
      stopOutcomeAnalysisPolling(job.id);
      await runJob(job.id, "Blueprint");
      await loadJobs({ force: true, focusJobId: job.id });
    } catch (error) {
      status.textContent = error.message;
      lock(false);
    }
  });

  actions.append(check, approve);
  editor.append(actions, status, summary);
  panel.append(editor);
}
