const APP_NAME = "Book Studio SME Review";

function jsonResponse(body, init = {}) {
  return new Response(JSON.stringify(body, null, 2), {
    ...init,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      ...(init.headers || {})
    }
  });
}

function textResponse(body, init = {}) {
  return new Response(body, {
    ...init,
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "no-store",
      ...(init.headers || {})
    }
  });
}

function htmlResponse(body, init = {}) {
  return new Response(body, {
    ...init,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "public, max-age=60",
      ...(init.headers || {})
    }
  });
}

function nowIso() {
  return new Date().toISOString();
}

function normalizeCode(value) {
  return String(value || "").trim().toUpperCase().replace(/[^A-Z0-9-]/g, "");
}

function escapeHtml(value) {
  return String(value || "").replace(/[&<>"']/g, (ch) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "\"": "&quot;",
    "'": "&#39;"
  }[ch]));
}

async function getAssignment(env, code) {
  return await env.REVIEW_KV.get("access:" + normalizeCode(code), "json");
}

async function getPackage(env, packageId) {
  return await env.REVIEW_KV.get("package:" + packageId, "json");
}

async function getFeedback(env, packageId, code) {
  return (await env.REVIEW_KV.get("feedback:" + packageId + ":" + normalizeCode(code), "json")) || {
    packageId,
    accessCode: normalizeCode(code),
    reviewerName: "",
    savedAt: "",
    chapterFeedback: {}
  };
}

async function saveFeedback(env, packageId, code, payload) {
  const current = await getFeedback(env, packageId, code);
  const incoming = payload || {};
  const hasReviewerName = Object.prototype.hasOwnProperty.call(incoming, "reviewerName");
  const feedback = {
    ...current,
    reviewerName: hasReviewerName ? String(incoming.reviewerName || "") : String(current.reviewerName || ""),
    status: incoming.status || current.status || "In review",
    submittedAt: incoming.submittedAt || current.submittedAt || "",
    savedAt: nowIso(),
    chapterFeedback: {
      ...(current.chapterFeedback || {}),
      ...(incoming.chapterFeedback || {})
    }
  };
  await env.REVIEW_KV.put("feedback:" + packageId + ":" + normalizeCode(code), JSON.stringify(feedback));
  return feedback;
}

function shellHtml() {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${APP_NAME}</title>
  <style>
    :root {
      color-scheme: light;
      --ink: #17324d;
      --muted: #5f6b7a;
      --line: #d9e0e7;
      --panel: #ffffff;
      --soft: #f5f7fa;
      --accent: #1769aa;
      --good: #11683d;
      --warn: #935b00;
      --bad: #a12828;
    }
    * { box-sizing: border-box; }
    body { margin: 0; color: var(--ink); background: var(--soft); font-family: Arial, Helvetica, sans-serif; line-height: 1.5; }
    button, input, textarea, select { font: inherit; }
    button { border: 1px solid var(--accent); border-radius: 6px; padding: 9px 12px; color: #fff; background: var(--accent); cursor: pointer; }
    button.secondary { color: var(--accent); background: #fff; }
    button:disabled { opacity: .6; cursor: wait; }
    .topbar { position: sticky; top: 0; z-index: 4; display: flex; justify-content: space-between; align-items: center; gap: 16px; padding: 14px 20px; background: #fff; border-bottom: 1px solid var(--line); }
    .brand h1 { margin: 0; font-size: 20px; }
    .brand p { margin: 2px 0 0; color: var(--muted); font-size: 13px; }
    .layout { display: grid; grid-template-columns: 300px minmax(0, 1fr) 360px; gap: 14px; padding: 14px; }
    .panel, .chapter, .login { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; }
    .panel { align-self: start; position: sticky; top: 76px; padding: 12px; }
    .panel h2, .review h2 { margin: 0 0 10px; font-size: 16px; }
    .course-meta { display: grid; gap: 4px; color: var(--muted); font-size: 13px; }
    .toc { display: grid; gap: 6px; margin-top: 12px; }
    .toc a { display: block; padding: 8px; border-radius: 6px; color: var(--accent); text-decoration: none; font-weight: 700; }
    .toc a:hover { background: #edf5fb; }
    .chapter { margin-bottom: 14px; padding: 18px; }
    .chapter h2 { margin: 0 0 4px; font-size: 22px; }
    .chapter .meta { color: var(--muted); font-size: 13px; margin-bottom: 14px; }
    .content h1 { font-size: 25px; margin: 22px 0 10px; }
    .content h2 { color: var(--accent); font-size: 20px; margin: 22px 0 8px; }
    .content h3 { font-size: 17px; margin: 18px 0 6px; }
    .content p { margin: 0 0 12px; }
    .content ul, .content ol { padding-left: 24px; }
    .content figure { margin: 16px 0; }
    .content img { display: block; max-width: 100%; max-height: 540px; object-fit: contain; border: 1px solid var(--line); border-radius: 6px; background: #fff; }
    .content figcaption { margin-top: 6px; color: var(--muted); font-size: 12px; }
    .table-wrap { margin: 14px 0 18px; overflow-x: auto; }
    .content table { width: 100%; border-collapse: collapse; font-size: 14px; line-height: 1.45; }
    .content th, .content td { border: 1px solid var(--line); padding: 8px 10px; text-align: left; vertical-align: top; }
    .content th { background: #f4f8fb; color: var(--ink); font-weight: 700; }
    .editor-toolbar { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
    .editable-content { border: 1px solid transparent; border-radius: 6px; padding: 6px; }
    .editable-content:focus { border-color: var(--accent); outline: 2px solid #d8ecfa; }
    .inline-comment-highlight { background: #fff1a8; border-bottom: 2px solid #c79100; cursor: help; }
    .review { display: grid; gap: 12px; }
    label span { display: block; margin-bottom: 4px; color: var(--muted); font-size: 12px; font-weight: 700; }
    input, select, textarea { width: 100%; border: 1px solid var(--line); border-radius: 6px; padding: 8px; background: #fff; color: var(--ink); }
    textarea { min-height: 130px; resize: vertical; }
    .chapter-card { display: grid; gap: 8px; padding: 10px; border: 1px solid var(--line); border-radius: 8px; background: #fff; }
    .chapter-card strong { font-size: 13px; }
    .status-row { display: flex; align-items: center; justify-content: space-between; gap: 10px; color: var(--muted); font-size: 12px; }
    .pill { border: 1px solid var(--line); border-radius: 999px; padding: 2px 8px; background: #f9fafb; }
    .save-state { min-height: 18px; color: var(--good); font-size: 12px; }
    .inline-comments { display: grid; gap: 6px; margin: 0; padding: 0; list-style: none; }
    .inline-comments li { border-left: 3px solid #c79100; padding-left: 8px; }
    .inline-comments mark { background: #fff1a8; color: inherit; }
    .login { max-width: 460px; margin: 80px auto; padding: 22px; }
    .login h1 { margin: 0 0 8px; font-size: 24px; }
    .login p { color: var(--muted); }
    .login form { display: grid; gap: 10px; }
    .error { color: var(--bad); }
    .empty { color: var(--muted); padding: 20px; }
    @media (max-width: 1120px) { .layout { grid-template-columns: 260px minmax(0, 1fr); } .review.panel { position: static; grid-column: 1 / -1; } }
    @media (max-width: 780px) { .layout { grid-template-columns: 1fr; } .panel { position: static; } .topbar { align-items: start; flex-direction: column; } }
  </style>
</head>
<body>
  <div id="app"></div>
  <script>
    const state = { code: "", data: null, feedback: null, saveTimer: null };

    function escapeHtml(value) {
      return String(value || "").replace(/[&<>"']/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
    }

    function inlineMarkdown(value) {
      return escapeHtml(value)
        .replace(/\\*\\*([^*]+)\\*\\*/g, "<strong>$1</strong>")
        .replace(/\\[([^\\]]+)\\]\\(([^)]+)\\)/g, '<a href="$2" target="_blank" rel="noreferrer">$1</a>');
    }

    function parseMarkdownTableRow(value) {
      const trimmed = String(value || "").trim();
      if (!trimmed.includes("|")) return null;
      const cells = trimmed.replace(/^\\|/, "").replace(/\\|$/, "").split("|").map(cell => cell.trim());
      return cells.length > 1 ? cells : null;
    }

    function isMarkdownTableSeparator(value) {
      const cells = parseMarkdownTableRow(value);
      return Boolean(cells && cells.length) && cells.every(cell => /^:?-{3,}:?$/.test(cell));
    }

    function markdownTableToHtml(rows) {
      if (!rows.length) return "";
      const header = rows[0];
      const bodyRows = rows.slice(2);
      const head = "<thead><tr>" + header.map(cell => "<th>" + inlineMarkdown(cell) + "</th>").join("") + "</tr></thead>";
      const body = bodyRows.length
        ? "<tbody>" + bodyRows.map(row => "<tr>" + row.map(cell => "<td>" + inlineMarkdown(cell) + "</td>").join("") + "</tr>").join("") + "</tbody>"
        : "";
      return '<div class="table-wrap"><table>' + head + body + "</table></div>";
    }

    function markdownToHtml(markdown) {
      const lines = String(markdown || "").split(/\\r?\\n/);
      const html = [];
      let list = null;
      for (let lineIndex = 0; lineIndex < lines.length; lineIndex++) {
        const line = lines[lineIndex];
        const trimmed = line.trim();
        if (!trimmed) {
          if (list) { html.push("</" + list + ">"); list = null; }
          continue;
        }
        const image = trimmed.match(/^!\\[([^\\]]*)\\]\\(([^)]+)\\)$/);
        if (image) {
          if (list) { html.push("</" + list + ">"); list = null; }
          html.push('<figure><img src="' + escapeHtml(image[2]) + '" alt="' + escapeHtml(image[1]) + '"><figcaption>' + escapeHtml(image[1]) + '</figcaption></figure>');
          continue;
        }
        const tableHeader = parseMarkdownTableRow(trimmed);
        const nextLine = lines[lineIndex + 1] || "";
        if (tableHeader && isMarkdownTableSeparator(nextLine)) {
          if (list) { html.push("</" + list + ">"); list = null; }
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
          html.push(markdownTableToHtml(tableRows));
          continue;
        }
        const heading = trimmed.match(/^(#{1,4})\\s+(.+)$/);
        if (heading) {
          if (list) { html.push("</" + list + ">"); list = null; }
          const level = Math.min(4, heading[1].length);
          html.push("<h" + level + ">" + inlineMarkdown(heading[2]) + "</h" + level + ">");
          continue;
        }
        const bullet = trimmed.match(/^[-*]\\s+(.+)$/);
        if (bullet) {
          if (list !== "ul") { if (list) html.push("</" + list + ">"); html.push("<ul>"); list = "ul"; }
          html.push("<li>" + inlineMarkdown(bullet[1]) + "</li>");
          continue;
        }
        const numbered = trimmed.match(/^\\d+\\.\\s+(.+)$/);
        if (numbered) {
          if (list !== "ol") { if (list) html.push("</" + list + ">"); html.push("<ol>"); list = "ol"; }
          html.push("<li>" + inlineMarkdown(numbered[1]) + "</li>");
          continue;
        }
        if (list) { html.push("</" + list + ">"); list = null; }
        html.push("<p>" + inlineMarkdown(trimmed) + "</p>");
      }
      if (list) html.push("</" + list + ">");
      return html.join("\\n");
    }

    function routeCode() {
      const match = location.pathname.match(/^\\/review\\/([^/]+)/);
      return match ? decodeURIComponent(match[1]) : "";
    }

    function renderLogin(message = "") {
      document.querySelector("#app").innerHTML = \`
        <section class="login">
          <h1>SME Review</h1>
          <p>Enter the access code provided by the course development team.</p>
          <form id="loginForm">
            <label><span>Access code</span><input id="accessCode" autocomplete="one-time-code" required></label>
            <button type="submit">Open Review</button>
            <div class="error">\${escapeHtml(message)}</div>
          </form>
        </section>\`;
      document.querySelector("#loginForm").addEventListener("submit", event => {
        event.preventDefault();
        const code = document.querySelector("#accessCode").value.trim();
        if (code) location.href = "/review/" + encodeURIComponent(code);
      });
    }

    function getChapterFeedback(chapterId) {
      state.feedback.chapterFeedback = state.feedback.chapterFeedback || {};
      state.feedback.chapterFeedback[chapterId] = state.feedback.chapterFeedback[chapterId] || { decision: "Not reviewed", comments: "", editedHtml: "", editedText: "", inlineComments: [] };
      return state.feedback.chapterFeedback[chapterId];
    }

    function getEditableForSelection() {
      const selection = window.getSelection();
      if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return null;
      let node = selection.anchorNode;
      if (node && node.nodeType === Node.TEXT_NODE) node = node.parentElement;
      return node ? node.closest(".editable-content") : null;
    }

    function syncChapterEdit(chapterId) {
      const editable = document.querySelector('.editable-content[data-chapter="' + CSS.escape(chapterId) + '"]');
      if (!editable) return;
      const item = getChapterFeedback(chapterId);
      item.editedHtml = editable.innerHTML;
      item.editedText = editable.innerText;
    }

    function addInlineComment() {
      const editable = getEditableForSelection();
      if (!editable) {
        const saveState = document.querySelector("#saveState");
        if (saveState) saveState.textContent = "Select text in a chapter first.";
        return;
      }
      const selection = window.getSelection();
      const selectedText = selection.toString().trim();
      if (!selectedText) return;
      const note = prompt("Comment on selected text");
      if (note === null || !note.trim()) return;

      const chapterId = editable.dataset.chapter;
      const commentId = "c-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 7);
      const range = selection.getRangeAt(0);
      const span = document.createElement("span");
      span.className = "inline-comment-highlight";
      span.dataset.commentId = commentId;
      span.title = note.trim();
      try {
        range.surroundContents(span);
      } catch {
        span.append(range.extractContents());
        range.insertNode(span);
      }
      selection.removeAllRanges();

      const item = getChapterFeedback(chapterId);
      item.inlineComments = item.inlineComments || [];
      item.inlineComments.push({
        id: commentId,
        selectedText,
        note: note.trim(),
        createdAt: new Date().toISOString()
      });
      syncChapterEdit(chapterId);
      renderCommentCardsOnly();
      scheduleSave();
    }

    async function saveFeedback() {
      const saveState = document.querySelector("#saveState");
      if (saveState) saveState.textContent = "Saving...";
      const response = await fetch("/api/review/" + encodeURIComponent(state.code) + "/feedback", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(state.feedback)
      });
      if (!response.ok) throw new Error(await response.text());
      state.feedback = await response.json();
      if (saveState) saveState.textContent = "Saved " + new Date(state.feedback.savedAt).toLocaleTimeString();
    }

    function scheduleSave() {
      clearTimeout(state.saveTimer);
      const saveState = document.querySelector("#saveState");
      if (saveState) saveState.textContent = "Unsaved changes...";
      state.saveTimer = setTimeout(() => saveFeedback().catch(error => {
        const target = document.querySelector("#saveState");
        if (target) target.textContent = error.message;
      }), 500);
    }

    function renderReview() {
      const pkg = state.data.package;
      const chapters = pkg.chapters || [];
      const feedback = state.feedback;
      const cards = chapters.map(chapter => {
        const item = getChapterFeedback(chapter.id);
        return \`
          <div class="chapter-card" data-chapter-card="\${escapeHtml(chapter.id)}">
            <div class="status-row"><strong>Chapter \${chapter.chapterNumber}</strong><span class="pill">\${escapeHtml(item.decision || "Not reviewed")}</span></div>
            <select data-field="decision" data-chapter="\${escapeHtml(chapter.id)}">
              \${["Not reviewed", "Approved", "Approved with edits", "Needs revision"].map(value => \`<option value="\${value}" \${value === item.decision ? "selected" : ""}>\${value}</option>\`).join("")}
            </select>
            <textarea data-field="comments" data-chapter="\${escapeHtml(chapter.id)}" placeholder="Accuracy, missing topics, terminology, visual concerns, or citation/source concerns">\${escapeHtml(item.comments || "")}</textarea>
            \${(item.inlineComments || []).length ? '<ul class="inline-comments">' + item.inlineComments.map(comment => '<li><mark>' + escapeHtml(comment.selectedText || "Selection") + '</mark><div>' + escapeHtml(comment.note || "") + '</div></li>').join("") + '</ul>' : ''}
            \${item.editedHtml || item.editedText ? '<div class="status-row"><span class="pill">Edited text saved</span></div>' : ''}
          </div>\`;
      }).join("");

      document.querySelector("#app").innerHTML = \`
        <header class="topbar">
          <div class="brand">
            <h1>\${escapeHtml(pkg.courseCode)}: \${escapeHtml(pkg.title)}</h1>
            <p>Subject matter expert review\${feedback.status ? " | " + escapeHtml(feedback.status) : ""}</p>
          </div>
          <div class="editor-toolbar">
            <button id="addComment" class="secondary" type="button">Comment</button>
            <button id="markDone" class="secondary" type="button">Mark Done</button>
            <span id="saveState" class="save-state">\${feedback.savedAt ? "Saved " + new Date(feedback.savedAt).toLocaleTimeString() : ""}</span>
            <button id="saveNow" class="secondary" type="button">Save</button>
          </div>
        </header>
        <main class="layout">
          <aside class="panel">
            <h2>Assigned Course</h2>
            <div class="course-meta">
              <span>\${escapeHtml(pkg.courseCode)}</span>
              <span>\${chapters.length} chapters</span>
              <span>Published \${new Date(pkg.publishedAt || pkg.generatedAt || Date.now()).toLocaleString()}</span>
            </div>
            <label style="margin-top:12px"><span>Reviewer name</span><input id="reviewerName" value="\${escapeHtml(feedback.reviewerName || "")}"></label>
            <nav class="toc">\${chapters.map(chapter => \`<a href="#\${escapeHtml(chapter.id)}">Chapter \${chapter.chapterNumber}</a>\`).join("")}</nav>
          </aside>
          <section>
            \${chapters.map(chapter => \`
              <article class="chapter" id="\${escapeHtml(chapter.id)}">
                <h2>Chapter \${chapter.chapterNumber}: \${escapeHtml(chapter.title)}</h2>
                <div class="meta">\${chapter.wordCount || 0} words</div>
                <div class="content editable-content" contenteditable="true" spellcheck="true" data-chapter="\${escapeHtml(chapter.id)}" aria-label="Editable Chapter \${chapter.chapterNumber}">\${getChapterFeedback(chapter.id).editedHtml || markdownToHtml(chapter.markdown || "")}</div>
              </article>\`).join("")}
          </section>
          <aside class="panel review">
            <h2>Review Notes</h2>
            \${cards || '<div class="empty">No chapters are available.</div>'}
          </aside>
        </main>\`;

      document.querySelector("#saveNow").addEventListener("click", () => saveFeedback().catch(error => document.querySelector("#saveState").textContent = error.message));
      document.querySelector("#addComment").addEventListener("click", addInlineComment);
      document.querySelector("#markDone").addEventListener("click", () => {
        state.feedback.status = "Submitted";
        state.feedback.submittedAt = new Date().toISOString();
        saveFeedback().catch(error => document.querySelector("#saveState").textContent = error.message);
        renderReview();
      });
      document.querySelector("#reviewerName").addEventListener("input", event => {
        state.feedback.reviewerName = event.target.value;
        scheduleSave();
      });
      for (const editable of document.querySelectorAll(".editable-content[data-chapter]")) {
        editable.addEventListener("input", event => {
          syncChapterEdit(event.currentTarget.dataset.chapter);
          scheduleSave();
        });
      }
      for (const control of document.querySelectorAll("[data-field][data-chapter]")) {
        control.addEventListener("input", event => {
          const chapterFeedback = getChapterFeedback(event.target.dataset.chapter);
          chapterFeedback[event.target.dataset.field] = event.target.value;
          const card = event.target.closest(".chapter-card");
          const pill = card && card.querySelector(".pill");
          if (pill && event.target.dataset.field === "decision") pill.textContent = event.target.value;
          scheduleSave();
        });
      }
    }

    function renderCommentCardsOnly() {
      const scrollY = window.scrollY;
      renderReview();
      window.scrollTo(0, scrollY);
    }

    async function loadReview(code) {
      state.code = code;
      document.querySelector("#app").innerHTML = '<div class="empty">Loading review...</div>';
      const response = await fetch("/api/review/" + encodeURIComponent(code));
      if (!response.ok) {
        renderLogin(await response.text());
        return;
      }
      state.data = await response.json();
      state.feedback = state.data.feedback || { chapterFeedback: {} };
      renderReview();
    }

    const code = routeCode();
    if (code) loadReview(code).catch(error => renderLogin(error.message));
    else renderLogin();
  </script>
</body>
</html>`;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const pathname = url.pathname.replace(/\/+$/, "") || "/";

    try {
      if (request.method === "GET" && pathname === "/api/health") {
        return jsonResponse({ ok: true, app: "sme-review" });
      }

      const reviewMatch = pathname.match(/^\/api\/review\/([^/]+)$/);
      if (request.method === "GET" && reviewMatch) {
        const code = normalizeCode(reviewMatch[1]);
        const assignment = await getAssignment(env, code);
        if (!assignment || !assignment.packageIds || assignment.packageIds.length === 0) {
          return textResponse("That access code was not found.", { status: 404 });
        }
        const packageId = assignment.packageIds[0];
        const pkg = await getPackage(env, packageId);
        if (!pkg) return textResponse("The assigned review package was not found.", { status: 404 });
        const feedback = await getFeedback(env, packageId, code);
        return jsonResponse({ assignment, package: pkg, feedback });
      }

      const feedbackMatch = pathname.match(/^\/api\/review\/([^/]+)\/feedback$/);
      if (request.method === "POST" && feedbackMatch) {
        const code = normalizeCode(feedbackMatch[1]);
        const assignment = await getAssignment(env, code);
        if (!assignment || !assignment.packageIds || assignment.packageIds.length === 0) {
          return textResponse("That access code was not found.", { status: 404 });
        }
        const packageId = assignment.packageIds[0];
        const payload = await request.json();
        const feedback = await saveFeedback(env, packageId, code, payload);
        return jsonResponse(feedback);
      }

      if (request.method === "GET" && (pathname === "/" || pathname.startsWith("/review/"))) {
        return htmlResponse(shellHtml());
      }

      return textResponse("Not found", { status: 404 });
    } catch (error) {
      return textResponse(error && error.message ? error.message : "Unexpected error", { status: 500 });
    }
  }
};
