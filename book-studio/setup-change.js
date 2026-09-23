// Changing the setup of a book that already exists.
//
// A designer who uploaded the wrong document, typed the title wrongly, or chose
// the wrong kind of course file used to have one option: delete the book and
// start again. They were deleting real work to fix a typo, and re-uploading
// documents they had already uploaded. This panel changes those decisions on
// the book that is already there, keeping its id and its history.
function appendSetupChange(container, job, api, reload) {
  const panel = document.createElement("details");
  panel.className = "setup-change";
  const summary = document.createElement("summary");
  summary.textContent = "Change setup";
  panel.append(summary);

  const body = document.createElement("div");
  body.className = "setup-change-body";
  body.textContent = "Loading the current setup...";
  panel.append(body);
  container.append(panel);

  let loaded = false;
  panel.addEventListener("toggle", async () => {
    // Loaded when it is opened, not on every book in the list: a designer
    // opening one book should not make the app read the setup of all of them.
    if (!panel.open || loaded) return;
    loaded = true;
    try {
      render(await api(`/api/jobs/${job.id}/setup`));
    } catch (error) {
      body.textContent = `Could not read the setup: ${error.message}`;
      loaded = false;
    }
  });

  function field(labelText, control, hint) {
    const label = document.createElement("label");
    label.className = "setup-field";
    const caption = document.createElement("span");
    caption.textContent = labelText;
    label.append(caption, control);
    if (hint) {
      const note = document.createElement("small");
      note.textContent = hint;
      label.append(note);
    }
    return label;
  }

  function render(setup) {
    body.textContent = "";

    const title = document.createElement("input");
    title.type = "text";
    title.value = setup.title || "";
    const courseCode = document.createElement("input");
    courseCode.type = "text";
    courseCode.value = setup.courseCode || "";

    const kind = document.createElement("select");
    for (const [value, label] of [
      ["EbookReady", "Ebook-ready course file (outcomes are final)"],
      ["CurriculumDraft", "Curriculum draft (objectives to be reviewed first)"]
    ]) kind.append(new Option(label, value));
    kind.value = setup.courseDocumentKind || "EbookReady";

    const documents = document.createElement("input");
    documents.type = "file";
    documents.multiple = true;
    documents.accept = ".docx,.txt,.md,.json,.html,.htm";

    const current = document.createElement("p");
    current.className = "setup-current";
    current.textContent = setup.documents && setup.documents.length
      ? `Now using: ${setup.documents.map((file) => file.name).join(", ")}`
      : "No course document is attached to this book.";

    const status = document.createElement("p");
    status.className = "setup-status";
    status.setAttribute("role", "status");

    const save = document.createElement("button");
    save.type = "button";
    save.textContent = "Save setup";

    body.append(
      field("Book name", title),
      field("Course code", courseCode),
      field("Kind of course document", kind, "Changing this decides whether the course objectives are reviewed before planning."),
      field("Replace the course document", documents, "Leave empty to keep the document this book already has."),
      current,
      save,
      status
    );

    save.addEventListener("click", async () => {
      save.disabled = true;
      status.className = "setup-status";
      status.textContent = "Saving...";
      try {
        const payload = {
          title: title.value.trim(),
          courseCode: courseCode.value.trim(),
          courseDocumentKind: kind.value
        };
        const chosen = Array.from(documents.files || []);
        if (chosen.length) {
          // Sent the way intake sends them, so the same rules apply to a
          // replacement as to the first upload.
          payload.files = [];
          for (const file of chosen) {
            payload.files.push({ name: file.name, contentBase64: await readAsBase64(file) });
          }
          payload.primaryFileIndex = 0;
          payload.sourceMode = "UploadedOnly";
          payload.readingLevel = 8;
        }
        await api(`/api/jobs/${job.id}/setup`, { method: "POST", body: JSON.stringify(payload) });
        status.textContent = chosen.length
          ? "Saved. The document was replaced, so the format preview has to be built again."
          : "Saved.";
        if (typeof reload === "function") await reload();
      } catch (error) {
        status.className = "setup-status bad";
        status.textContent = error.message;
      } finally {
        save.disabled = false;
      }
    });
  }

  function readAsBase64(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onerror = () => reject(new Error(`Could not read ${file.name}.`));
      reader.onload = () => {
        const result = String(reader.result || "");
        resolve(result.slice(result.indexOf(",") + 1));
      };
      reader.readAsDataURL(file);
    });
  }
}
