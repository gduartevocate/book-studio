// Outcome replacement is a separate, explicit review. Chat advice alone never applies it.
function appendOutcomeReplacement(container, job, outline) {
  const panel = makeElement("details", "advanced-options outcome-replacement");
  panel.append(makeElement("summary", "", "Replace official outcomes (review required)"));
  panel.append(makeElement("p", "hint", "Save any outline edits first. Paste the complete revised CO/LO list, assign outcomes to every chapter, then review and confirm. The original upload is preserved; a dated amendment controls future generation and traceability. This does not write a manuscript."));
  const field = (caption, control) => { const label = makeElement("label", ""); label.append(makeElement("span", "", caption), control); panel.append(label); return control; };
  const text = field("Complete revised outcomes", document.createElement("textarea"));
  text.rows = 10; text.maxLength = 60000; text.placeholder = "CO1: Describe the process.\nLO1.1: Identify its stages.\nLO1.2: Explain its handoffs.";
  const assignments = (outline.chapters || []).map(chapter => {
    const input = field(`Chapter ${chapter.number}: ${chapter.title} — assigned IDs`, document.createElement("input"));
    input.placeholder = "CO1, CO2 or specific lessons: LO1.1, LO2.2";
    input.maxLength = 3000;
    const suggested = /^Align to\s+(CO\d+(?:(?:\s*[,/]\s*|\s+and\s+)CO\d+)*)/i.exec(chapter.guidance || "");
    input.value = suggested ? (suggested[1].match(/CO\d+/gi) || []).join(", ") : "";
    return { number: chapter.number, input };
  });
  panel.append(makeElement("p", "hint", "Assignments prefilled from ‘Align to CO…’ guidance are suggestions, not approval. CO1 selects its lesson objectives; use LO1.1 to split a course objective across chapters. An outcome may appear in multiple chapters, but none may be omitted."));
  const reviewer = field("Reviewed by", document.createElement("input")); reviewer.maxLength = 150;
  const reason = field("Source / reason for the replacement", document.createElement("input")); reason.maxLength = 1000;
  const actions = makeElement("div", "actions");
  const preview = makeElement("button", "secondary", "Preview outcome replacement"); preview.type = "button";
  const apply = makeElement("button", "", "Confirm replacement & refresh all review files"); apply.type = "button"; apply.disabled = true;
  const confirm = field("I reviewed the old/new outcomes and their chapter assignments and approve this replacement.", document.createElement("input")); confirm.type = "checkbox";
  const status = makeElement("p", "hint"); status.setAttribute("role", "status");
  const diff = makeElement("div", "outcome-diff");
  let pending = null, busy = false;
  const inputs = [text, reviewer, reason, ...assignments.map(item => item.input)];
  const reset = () => { pending = null; confirm.checked = false; apply.disabled = true; diff.textContent = ""; status.textContent = "Changed. Preview again before applying."; };
  [text, ...assignments.map(item => item.input)].forEach(input => input.addEventListener("input", reset));
  confirm.addEventListener("change", () => { apply.disabled = busy || !pending || !confirm.checked; });
  const lock = value => { busy = value; preview.disabled = value; confirm.disabled = value; inputs.forEach(input => { input.readOnly = value; }); apply.disabled = value || !pending || !confirm.checked; };
  preview.addEventListener("click", async () => {
    if (busy) return;
    reset(); lock(true); status.textContent = "Checking outcome coverage and chapter assignments…";
    const body = { text: text.value, assignments: assignments.map(item => ({ number: item.number, ids: item.input.value })) };
    try {
      const result = await api(`/api/jobs/${job.id}/outcomes/preview`, { method: "POST", body: JSON.stringify(body) });
      pending = { ...body, planHash: result.planHash };
      diff.append(makeElement("p", "", `${result.previousCount} old chapter assignments → ${result.newCount} new assignments (${result.uniqueOutcomes} unique outcomes).`));
      for (const chapter of result.chapters) {
        diff.append(makeElement("h4", "", `Chapter ${chapter.number}: ${chapter.title}`));
        for (const [label, records] of [["Before", chapter.previous], ["After", chapter.records]]) {
          diff.append(makeElement("strong", "", label)); const list = makeElement("ul", "");
          for (const record of records || []) list.append(makeElement("li", "", `${record.objectiveId}: ${record.objective}`));
          diff.append(list);
        }
      }
      status.textContent = "Nothing saved yet. Review the comparison, enter your name and revision source, and confirm.";
    } catch (error) { status.textContent = error.message; } finally { lock(false); }
  });
  apply.addEventListener("click", async () => {
    if (busy || !pending || !confirm.checked) return;
    if (!reviewer.value.trim() || !reason.value.trim()) { status.textContent = "Enter your name and the revision source/reason, then preview again."; return; }
    lock(true); status.textContent = "Saving the reviewed amendment and rebuilding all review files…";
    try {
      await api(`/api/jobs/${job.id}/outcomes/apply`, { method: "POST", body: JSON.stringify({ ...pending, confirm: true, reviewedBy: reviewer.value.trim(), reason: reason.value.trim() }) });
      await loadJobs({ force: true, focusJobId: job.id });
    } catch (error) { status.textContent = error.message; } finally { lock(false); }
  });
  actions.append(preview, apply); panel.append(actions, status, diff); container.append(panel);
  return { openWithText(value) {
    if (text.value && text.value !== value && !window.confirm("Replace the unsaved outcome list in the review form?")) return;
    text.value = value; reset(); panel.open = true; panel.scrollIntoView({ behavior: "smooth", block: "start" });
  } };
}
