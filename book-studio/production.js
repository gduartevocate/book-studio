// Lazy-loaded so normal job polling does not overwrite unsaved form edits.
function appendProductionPreferences(container, job) {
  const panel = makeElement("details", "advanced-options");
  panel.append(makeElement("summary", "", "Sources and image setting"));
  const content = makeElement("div", "");
  panel.append(content);
  let loaded = false;
  panel.addEventListener("toggle", async () => {
    if (!panel.open || loaded) return;
    loaded = true;
    content.textContent = "Loading production settings…";
    try {
      const saved = await api(`/api/jobs/${job.id}/production-settings`);
      content.textContent = "";
      const addField = (caption, field) => {
        const label = makeElement("label", "");
        label.append(makeElement("span", "", caption), field);
        content.append(label);
        return field;
      };
      const mode = addField("Sources to use", document.createElement("select"));
      for (const [value, label] of [["Assigned", "Required readings below"], ["UploadedOnly", "Uploaded teaching documents only"], ["Discovery", "Discover additional sources"]]) mode.append(new Option(label, value));
      mode.value = saved.sourceMode || "UploadedOnly";
      // Assigned readings stay locked, taught and cited; this permits sources
      // on top of them, so it is only meaningful for that policy.
      const research = addField("Also research additional sources beyond the required readings", document.createElement("input"));
      research.type = "checkbox";
      research.checked = Boolean(saved.allowAdditionalResearch);
      const syncResearch = () => {
        research.disabled = mode.value !== "Assigned";
        if (research.disabled) research.checked = false;
      };
      mode.addEventListener("change", syncResearch);
      syncResearch();
      const readings = addField("Required reading list (review links extracted from the blueprint)", document.createElement("textarea"));
      readings.rows = 10; readings.maxLength = 40000; readings.value = saved.requiredSources || "";
      readings.placeholder = "Week 1:\n[Title](https://example.org/article)\n[Orientation video](https://example.org/video) (reference only)\nAll chapters:\nhttps://example.org/shared-reading";
      const context = addField("Image setting", document.createElement("select"));
      for (const [value, label] of [["Generic", "Generic / everyday (nonclinical)"], ["Healthcare", "Healthcare"], ["Business", "Business (nonclinical)"], ["Custom", "Custom"]]) context.append(new Option(label, value));
      context.value = saved.imageSettings?.context || "Generic";
      const instructions = addField("Image instructions", document.createElement("textarea"));
      instructions.maxLength = 4000; instructions.value = saved.imageSettings?.instructions || "";
      content.append(makeElement("p", "hint", "Save → Check required sources → Fix QA with Codex to revise existing teaching and citations. Rebuild only refreshes exports. The blueprint is not a scholarly source. Use accessible article/chapter URLs; PDF extraction requires Poppler pdftotext. Saving an image setting does not replace existing images or spend AI usage."));
      content.append(makeElement("p", "hint", "End a line with (reference only) for a source the app cannot read, such as a video, an interactive tool, a dataset, or a sign-in page. It may then be cited but is never used as teaching evidence, so every chapter still needs at least one reading whose text can be retrieved."));
      const actions = makeElement("div", "actions");
      const status = makeElement("p", "hint"); status.setAttribute("role", "status");
      const report = makeElement("div", "");
      let dirty = false;
      const buttons = [];
      const renderReport = (preferences) => {
        report.textContent = "";
        if (preferences.sourceMode === "Assigned" && !(preferences.readings || []).length) {
          report.append(makeElement("p", "hint", "No required readings found. A course outline with objectives is not a reading list. Add the article/chapter URLs to use, save, and check required sources before generating."));
        }
        if (preferences.sourceReport?.skippedCount) {
          report.append(makeElement("p", "hint", `${preferences.sourceReport.skippedCount} reading(s) could not be read and were skipped, so the book does not teach from them. They may still be cited. Replace a link with the exact article or chapter page to teach from one.`));
        }
        const list = makeElement("ul", "");
        for (const reading of preferences.readings || []) {
          const evidence = preferences.sourceReport?.readings?.find((item) => item.id === reading.id && item.url === reading.url);
          const assignment = reading.chapters.includes(0) ? "All chapters" : `Chapter ${reading.chapters.join(", ")}`;
          list.append(makeElement("li", "", `${assignment} — ${reading.title}: ${evidence?.status || "Not checked"}${evidence?.detail ? ` — ${evidence.detail}` : ""}`));
        }
        report.append(makeElement("p", "hint", "Read = source text retrieved, not claim accuracy or permissions approved. Check report details for blocked links."), list);
      };
      const addAction = (label, action) => {
        const button = makeElement("button", "secondary", label); button.type = "button"; buttons.push(button);
        button.addEventListener("click", async () => {
          buttons.forEach((item) => { item.disabled = true; });
          try { await action(); } catch (error) { status.textContent = error.message; }
          finally { buttons.forEach((item) => { item.disabled = false; }); }
        });
        actions.append(button);
      };
      for (const field of [mode, readings, context, instructions]) field.addEventListener("input", () => { dirty = true; status.textContent = "Unsaved settings. Save before checking sources or generating images."; });
      addAction("Save settings", async () => {
        const updated = await api(`/api/jobs/${job.id}/production-settings`, { method: "POST", body: JSON.stringify({ sourceMode: mode.value, allowAdditionalResearch: research.checked, requiredSources: readings.value, imageContext: context.value, imageInstructions: instructions.value }) });
        dirty = false; renderReport(updated); status.textContent = "Saved. Existing manuscript and images are unchanged. Check sources before requesting a revision.";
      });
      addAction("Remove entries with no URL", async () => {
        // An older version extracted learning objectives into this list. They
        // carry no link, so generation stays blocked until they are removed.
        const hasLink = (text) => text.indexOf("http://") >= 0 || text.indexOf("https://") >= 0;
        const isHeading = (text) => text.endsWith(":") && !hasLink(text);
        const lines = readings.value.replace(/\r/g, "").split("\n");
        const withLinks = lines.filter((line) => {
          const text = line.trim();
          return !text || isHeading(text) || hasLink(text);
        });
        const kept = withLinks.filter((line, index) => {
          if (!isHeading(line.trim())) return true;
          // Drop a week heading whose readings were all removed.
          const next = withLinks.slice(index + 1).find((value) => value.trim());
          return Boolean(next) && !isHeading(next.trim());
        });
        const removed = lines.filter((line) => line.trim()).length - kept.filter((line) => line.trim()).length;
        if (!removed) { status.textContent = "Every entry already has a URL."; return; }
        readings.value = kept.join("\n").replace(/\n{3,}/g, "\n\n").trim();
        dirty = true;
        status.textContent = `${removed} entr${removed === 1 ? "y" : "ies"} without a URL removed. Review the list, then Save settings.`;
      });
      addAction("Check required sources", async () => {
        if (dirty) throw new Error("Save your settings first.");
        if (mode.value !== "Assigned") throw new Error("Select Required readings and save first.");
        const result = await api(`/api/jobs/${job.id}/check-sources`, { method: "POST", body: "{}" });
        status.textContent = result.message;
        await loadJobs();
      });
      addAction("Refresh source results", async () => { renderReport(await api(`/api/jobs/${job.id}/production-settings`)); status.textContent = "Source results refreshed."; });
      if (job.artifacts?.some((item) => item.fileName?.endsWith(" - E-Book.md"))) addAction("Generate images for saved setting", async () => {
        if (dirty) throw new Error("Save your settings first.");
        if (!window.confirm("Generate missing or changed chapter images using Codex? This uses AI usage. Existing images are backed up; the chapter text is preserved.")) return;
        await api(`/api/jobs/${job.id}/generate-images`, { method: "POST", body: "{}" });
        await loadJobs();
      });
      content.append(actions, status, report); renderReport(saved);
    } catch (error) { loaded = false; content.textContent = error.message; }
  });
  container.append(panel);
}
