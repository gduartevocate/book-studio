const JOB_INDEX_KEY = "jobs:index";
const RUNNER_TOKEN_KEY = "runner:token";
const MAX_FILE_BYTES = 10 * 1024 * 1024;
const MAX_TOTAL_UPLOAD_BYTES = 20 * 1024 * 1024;

const APP_HTML = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Ebook Generator</title>
  <style>
    :root {
      --legend-blue: #0d3553;
      --hero-blue: #1d6ba6;
      --horizon-blue: #0095c8;
      --journey-green: #15eac4;
      --gracious-gray: #f9f9f9;
      --medium-gray: #dbdbdb;
      --integrity-gray: #444444;
      --white: #ffffff;
      --danger: #b42318;
      --warning: #a15c00;
      --success: #067647;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      color: var(--legend-blue);
      background: var(--gracious-gray);
      font-family: Arial, Helvetica, sans-serif;
      line-height: 1.45;
    }
    button, input, textarea { font: inherit; }
    .topbar {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 24px;
      padding: 20px 28px;
      background: var(--white);
      border-bottom: 1px solid var(--medium-gray);
    }
    .topbar h1 { margin: 0; font-size: 24px; line-height: 1.1; }
    .topbar p { margin: 4px 0 0; color: var(--integrity-gray); }
    .workspace {
      display: grid;
      grid-template-columns: minmax(320px, 430px) minmax(0, 1fr);
      gap: 22px;
      padding: 22px;
    }
    .panel {
      background: var(--white);
      border: 1px solid var(--medium-gray);
      border-radius: 8px;
      padding: 18px;
    }
    .notice {
      margin: 0 22px;
      padding: 12px 14px;
      border: 1px solid var(--horizon-blue);
      border-radius: 8px;
      background: #f4fbff;
      color: var(--integrity-gray);
    }
    h2 { margin: 0 0 16px; font-size: 18px; }
    label { display: block; }
    label span {
      display: block;
      margin-bottom: 6px;
      color: var(--integrity-gray);
      font-size: 13px;
      font-weight: 700;
    }
    input[type="text"], input[type="number"], input:not([type]), textarea {
      width: 100%;
      border: 1px solid var(--medium-gray);
      border-radius: 6px;
      padding: 10px 11px;
      color: var(--legend-blue);
      background: var(--white);
    }
    input[type="file"] {
      width: 100%;
      border: 1px dashed var(--horizon-blue);
      border-radius: 6px;
      padding: 12px;
      background: #f4fbff;
    }
    textarea { min-height: 108px; resize: vertical; }
    form { display: grid; gap: 14px; }
    .field-grid { display: grid; grid-template-columns: 1fr; gap: 12px; }
    .controls-row {
      display: grid;
      grid-template-columns: minmax(130px, 1fr) 1fr 1fr;
      gap: 12px;
      align-items: end;
    }
    .check-field {
      display: flex;
      align-items: center;
      min-height: 42px;
      gap: 8px;
      border: 1px solid var(--medium-gray);
      border-radius: 6px;
      padding: 8px 10px;
    }
    .check-field input { width: 18px; height: 18px; }
    .check-field span { margin: 0; }
    .actions { display: flex; align-items: center; gap: 12px; }
    button {
      border: 1px solid var(--hero-blue);
      border-radius: 6px;
      padding: 10px 14px;
      color: var(--white);
      background: var(--hero-blue);
      cursor: pointer;
    }
    button.secondary { color: var(--legend-blue); background: var(--white); }
    button:disabled { cursor: wait; opacity: 0.65; }
    #formStatus, #jobCount { color: var(--integrity-gray); font-size: 13px; }
    .section-heading { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
    .jobs-list { display: grid; gap: 10px; }
    .job-row {
      display: grid;
      grid-template-columns: minmax(0, 1fr) 120px;
      gap: 14px;
      align-items: start;
      border: 1px solid var(--medium-gray);
      border-radius: 8px;
      padding: 14px;
    }
    .job-title { font-weight: 700; }
    .job-meta, .job-log { color: var(--integrity-gray); font-size: 13px; }
    .job-status {
      justify-self: start;
      min-width: 92px;
      border-radius: 999px;
      padding: 5px 9px;
      text-align: center;
      font-size: 12px;
      font-weight: 700;
      background: var(--gracious-gray);
      border: 1px solid var(--medium-gray);
    }
    .job-status.completed { color: var(--success); border-color: var(--success); background: #ecfdf3; }
    .job-status.failed { color: var(--danger); border-color: var(--danger); background: #fef3f2; }
    .job-status.queued, .job-status.running { color: var(--warning); border-color: var(--warning); background: #fff7e8; }
    .job-log, .file-list, .artifact-list { grid-column: 1 / -1; }
    .file-list { display: flex; flex-wrap: wrap; gap: 8px; }
    .artifact-list { display: flex; flex-wrap: wrap; gap: 8px; }
    .file-chip {
      display: inline-flex;
      align-items: center;
      min-height: 30px;
      border: 1px solid var(--horizon-blue);
      border-radius: 6px;
      padding: 5px 8px;
      color: var(--legend-blue);
      background: #f4fbff;
      font-size: 13px;
    }
    .artifact-list a {
      display: inline-flex;
      align-items: center;
      min-height: 34px;
      border: 1px solid var(--horizon-blue);
      border-radius: 6px;
      padding: 7px 10px;
      color: var(--legend-blue);
      text-decoration: none;
      background: #f4fbff;
    }
    .empty-state {
      border: 1px dashed var(--medium-gray);
      border-radius: 8px;
      padding: 24px;
      color: var(--integrity-gray);
    }
    @media (max-width: 900px) {
      .workspace { grid-template-columns: 1fr; }
      .job-row { grid-template-columns: 1fr; }
    }
    @media (max-width: 620px) {
      .topbar { align-items: flex-start; flex-direction: column; }
      .workspace { padding: 14px; }
      .notice { margin: 0 14px; }
      .controls-row { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <header class="topbar">
    <div>
      <h1>Ebook Generator</h1>
      <p>Cloud intake queue for Book Studio</p>
    </div>
    <button id="refreshJobs" class="secondary" type="button">Refresh</button>
  </header>
  <p class="notice">This app stores new book requests in Cloudflare. An authorized local Book Runner can pick up queued jobs, use the connected workstation to generate the ebook, and upload finished Word/HTML artifacts back here.</p>
  <main class="workspace">
    <section class="panel">
      <h2>Create Book</h2>
      <form id="bookForm">
        <div class="field-grid">
          <label>
            <span>Course code</span>
            <input name="courseCode" autocomplete="off" placeholder="HU2000">
          </label>
          <label>
            <span>Book title</span>
            <input name="title" autocomplete="off" placeholder="Critical Thinking and Problem Solving">
          </label>
        </div>
        <label>
          <span>Source files</span>
          <input name="files" type="file" multiple required>
        </label>
        <label>
          <span>Production notes</span>
          <textarea name="specialInstructions" placeholder="Audience, tone, special requirements, chapter emphasis, or exclusions"></textarea>
        </label>
        <div class="controls-row">
          <label>
            <span>Research per chapter</span>
            <input name="maxResearchPerChapter" type="number" min="1" max="8" value="3">
          </label>
          <label class="check-field">
            <input name="skipResearch" type="checkbox">
            <span>Skip research</span>
          </label>
          <label class="check-field">
            <input name="skipOpenStaxFetch" type="checkbox">
            <span>Offline OpenStax</span>
          </label>
        </div>
        <div class="actions">
          <button id="generateButton" type="submit">Create Job</button>
          <span id="formStatus" role="status" aria-live="polite"></span>
        </div>
      </form>
    </section>
    <section class="panel">
      <div class="section-heading">
        <h2>Production Jobs</h2>
        <span id="jobCount"></span>
      </div>
      <div id="jobsList" class="jobs-list"></div>
    </section>
  </main>
  <template id="jobTemplate">
    <article class="job-row">
      <div>
        <div class="job-title"></div>
        <div class="job-meta"></div>
      </div>
      <div class="job-status"></div>
      <div class="job-log"></div>
      <div class="file-list"></div>
      <div class="artifact-list"></div>
    </article>
  </template>
  <script>
    var form = document.querySelector("#bookForm");
    var formStatus = document.querySelector("#formStatus");
    var generateButton = document.querySelector("#generateButton");
    var refreshJobsButton = document.querySelector("#refreshJobs");
    var jobsList = document.querySelector("#jobsList");
    var jobCount = document.querySelector("#jobCount");
    var jobTemplate = document.querySelector("#jobTemplate");

    function setStatus(message) { formStatus.textContent = message || ""; }
    function readFileAsBase64(file) {
      return new Promise(function(resolve, reject) {
        var reader = new FileReader();
        reader.onload = function() {
          var result = String(reader.result || "");
          var commaIndex = result.indexOf(",");
          resolve(commaIndex >= 0 ? result.slice(commaIndex + 1) : result);
        };
        reader.onerror = function() { reject(reader.error); };
        reader.readAsDataURL(file);
      });
    }
    async function api(path, options) {
      var response = await fetch(path, Object.assign({ headers: { "content-type": "application/json" } }, options || {}));
      if (!response.ok) {
        var message = await response.text();
        throw new Error(message || "Request failed: " + response.status);
      }
      var text = await response.text();
      return text ? JSON.parse(text) : null;
    }
    function formatDate(value) {
      if (!value) return "";
      var date = new Date(value);
      if (Number.isNaN(date.getTime())) return value;
      return date.toLocaleString();
    }
    function formatBytes(value) {
      var bytes = Number(value || 0);
      if (bytes < 1024) return bytes + " B";
      if (bytes < 1024 * 1024) return Math.round(bytes / 1024) + " KB";
      return (bytes / 1024 / 1024).toFixed(1) + " MB";
    }
    function lastLogLine(job) {
      var entries = Array.isArray(job.log) ? job.log : [];
      if (!entries.length) return "";
      var last = entries[entries.length - 1];
      return formatDate(last.at) + " - " + last.message;
    }
    function renderJobs(jobs) {
      jobsList.textContent = "";
      jobCount.textContent = jobs.length + " job" + (jobs.length === 1 ? "" : "s");
      if (!jobs.length) {
        var empty = document.createElement("div");
        empty.className = "empty-state";
        empty.textContent = "No book jobs yet.";
        jobsList.append(empty);
        return;
      }
      jobs.forEach(function(job) {
        var node = jobTemplate.content.firstElementChild.cloneNode(true);
        var title = node.querySelector(".job-title");
        var meta = node.querySelector(".job-meta");
        var status = node.querySelector(".job-status");
        var log = node.querySelector(".job-log");
        var fileList = node.querySelector(".file-list");
        var artifactList = node.querySelector(".artifact-list");
        title.textContent = (job.courseCode ? job.courseCode + ": " : "") + (job.title || "Untitled Book");
        meta.textContent = "Created " + formatDate(job.createdAt) + " | " + ((job.uploadedFiles || []).length) + " source file(s)";
        status.textContent = job.status || "Unknown";
        status.classList.add(String(job.status || "").toLowerCase());
        log.textContent = job.error ? job.error : lastLogLine(job);
        (job.uploadedFiles || []).forEach(function(file) {
          var chip = document.createElement("span");
          chip.className = "file-chip";
          chip.textContent = file.name + " (" + formatBytes(file.size) + ")";
          fileList.append(chip);
        });
        (job.artifacts || []).forEach(function(artifact) {
          var link = document.createElement("a");
          link.href = artifact.url;
          link.textContent = artifact.name + " (" + formatBytes(artifact.size) + ")";
          artifactList.append(link);
        });
        jobsList.append(node);
      });
    }
    async function loadJobs() {
      var data = await api("/api/jobs");
      renderJobs(data.jobs || []);
    }
    form.addEventListener("submit", async function(event) {
      event.preventDefault();
      generateButton.disabled = true;
      try {
        var formData = new FormData(form);
        var selectedFiles = Array.from(form.elements.files.files || []);
        if (!selectedFiles.length) throw new Error("Choose at least one source file.");
        var files = [];
        for (var i = 0; i < selectedFiles.length; i++) {
          var file = selectedFiles[i];
          setStatus("Reading " + file.name + "...");
          files.push({ name: file.name, size: file.size, type: file.type, contentBase64: await readFileAsBase64(file) });
        }
        var payload = {
          courseCode: formData.get("courseCode"),
          title: formData.get("title"),
          specialInstructions: formData.get("specialInstructions"),
          maxResearchPerChapter: Number(formData.get("maxResearchPerChapter") || 3),
          skipResearch: formData.get("skipResearch") === "on",
          skipOpenStaxFetch: formData.get("skipOpenStaxFetch") === "on",
          files: files
        };
        setStatus("Creating Cloudflare job...");
        await api("/api/jobs", { method: "POST", body: JSON.stringify(payload) });
        form.reset();
        form.elements.maxResearchPerChapter.value = 3;
        setStatus("Job queued.");
        await loadJobs();
      } catch (error) {
        setStatus(error.message);
      } finally {
        generateButton.disabled = false;
      }
    });
    refreshJobsButton.addEventListener("click", function() { loadJobs().catch(function(error) { setStatus(error.message); }); });
    loadJobs().catch(function(error) { setStatus(error.message); });
    setInterval(function() { loadJobs().catch(function() {}); }, 5000);
  </script>
</body>
</html>`;

function jsonResponse(value, init = {}) {
  return new Response(JSON.stringify(value, null, 2), {
    ...init,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      ...(init.headers || {})
    }
  });
}

function textResponse(value, init = {}) {
  return new Response(value, {
    ...init,
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "no-store",
      ...(init.headers || {})
    }
  });
}

function nowIso() {
  return new Date().toISOString();
}

function makeJobId() {
  return crypto.randomUUID().replace(/-/g, "").slice(0, 12);
}

function estimateBase64Bytes(value) {
  const text = String(value || "");
  const padding = text.endsWith("==") ? 2 : text.endsWith("=") ? 1 : 0;
  return Math.max(0, Math.floor((text.length * 3) / 4) - padding);
}

async function readIndex(env) {
  return (await env.BOOK_STUDIO_KV.get(JOB_INDEX_KEY, "json")) || [];
}

async function writeIndex(env, ids) {
  await env.BOOK_STUDIO_KV.put(JOB_INDEX_KEY, JSON.stringify(ids.slice(0, 100)));
}

async function readJob(env, id) {
  return await env.BOOK_STUDIO_KV.get("job:" + id, "json");
}

async function writeJob(env, job) {
  job.updatedAt = nowIso();
  await env.BOOK_STUDIO_KV.put("job:" + job.id, JSON.stringify(job));
}

async function listJobs(env) {
  const ids = await readIndex(env);
  const jobs = [];
  for (const id of ids) {
    const job = await readJob(env, id);
    if (job) jobs.push(job);
  }
  return jobs;
}

function getRouteId(pathname, suffix = "") {
  const escapedSuffix = suffix.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = pathname.match(new RegExp("^/api/jobs/([^/]+)" + escapedSuffix + "$"));
  return match ? match[1] : "";
}

function getRunnerRouteId(pathname, suffix = "") {
  const escapedSuffix = suffix.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = pathname.match(new RegExp("^/api/runner/jobs/([^/]+)" + escapedSuffix + "$"));
  return match ? match[1] : "";
}

async function isRunnerAuthorized(request, env) {
  const expected = await env.BOOK_STUDIO_KV.get(RUNNER_TOKEN_KEY);
  if (!expected) return false;
  const actual = request.headers.get("x-book-runner-token") || "";
  return actual.length > 0 && actual === expected;
}

async function requireRunner(request, env) {
  if (!(await isRunnerAuthorized(request, env))) {
    return textResponse("Unauthorized", { status: 401 });
  }
  return null;
}

function publicJob(job) {
  if (!job) return null;
  return {
    ...job,
    uploadedFiles: (job.uploadedFiles || []).map((file) => ({
      name: file.name,
      type: file.type || "",
      size: file.size || 0,
      role: file.role || "context"
    }))
  };
}

async function listPublicJobs(env) {
  const jobs = await listJobs(env);
  return jobs.map(publicJob);
}

function appendJobLog(job, message) {
  const entries = Array.isArray(job.log) ? job.log : [];
  entries.push({ at: nowIso(), message: String(message || "") });
  job.log = entries.slice(-80);
}

async function getJobFiles(env, job) {
  const files = [];
  for (const file of job.uploadedFiles || []) {
    const record = await env.BOOK_STUDIO_KV.get(file.key, "json");
    if (record) {
      files.push({
        name: record.name || file.name || "uploaded-source",
        type: record.type || file.type || "",
        size: record.size || file.size || 0,
        role: file.role || "context",
        contentBase64: record.contentBase64 || ""
      });
    }
  }
  return files;
}

async function getArtifact(env, job, name) {
  const artifact = (job.artifacts || []).find((item) => item.fileName === name || item.name === name);
  if (!artifact) return null;
  const record = await env.BOOK_STUDIO_KV.get(artifact.key, "json");
  if (!record) return null;
  return { artifact, record };
}

function base64ToBytes(base64) {
  const binary = atob(base64 || "");
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

async function createJob(request, env) {
  const payload = await request.json();
  const files = Array.isArray(payload.files) ? payload.files : [];
  if (files.length === 0) {
    return textResponse("Upload at least one source file.", { status: 400 });
  }

  let totalBytes = 0;
  for (const file of files) {
    const size = Number(file.size || estimateBase64Bytes(file.contentBase64));
    if (size > MAX_FILE_BYTES) {
      return textResponse("File is too large for this tester: " + file.name, { status: 413 });
    }
    totalBytes += size;
  }
  if (totalBytes > MAX_TOTAL_UPLOAD_BYTES) {
    return textResponse("Total upload is too large for this tester.", { status: 413 });
  }

  const id = makeJobId();
  const createdAt = nowIso();
  const uploadedFiles = [];
  for (let i = 0; i < files.length; i++) {
    const file = files[i];
    const fileKey = "job:" + id + ":file:" + i;
    await env.BOOK_STUDIO_KV.put(fileKey, JSON.stringify({
      name: file.name || "uploaded-source",
      type: file.type || "",
      size: Number(file.size || estimateBase64Bytes(file.contentBase64)),
      contentBase64: file.contentBase64 || ""
    }));
    uploadedFiles.push({
      name: file.name || "uploaded-source",
      type: file.type || "",
      size: Number(file.size || estimateBase64Bytes(file.contentBase64)),
      key: fileKey,
      role: i === 0 ? "spec" : "context"
    });
  }

  const job = {
    id,
    status: "Queued",
    createdAt,
    updatedAt: createdAt,
    title: payload.title || "Untitled Book",
    courseCode: payload.courseCode || "",
    specialInstructions: payload.specialInstructions || "",
    sourceContextPath: "cloudflare-kv",
    outputFolder: "",
    uploadedFiles,
    options: {
      maxResearchPerChapter: Number(payload.maxResearchPerChapter || 3),
      skipResearch: Boolean(payload.skipResearch),
      skipOpenStaxFetch: Boolean(payload.skipOpenStaxFetch)
    },
    artifacts: [],
    log: [
      { at: createdAt, message: "Cloudflare intake job created." },
      { at: createdAt, message: "Waiting for a local Book Runner connection." }
    ],
    error: ""
  };

  await writeJob(env, job);
  const index = await readIndex(env);
  await writeIndex(env, [id, ...index.filter((existing) => existing !== id)]);
  return jsonResponse(job, { status: 201 });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const pathname = url.pathname.replace(/\/+$/, "") || "/";

    try {
      if (request.method === "GET" && (pathname === "/" || pathname === "/index.html")) {
        return new Response(APP_HTML, {
          headers: {
            "content-type": "text/html; charset=utf-8",
            "cache-control": "public, max-age=120"
          }
        });
      }

      if (request.method === "GET" && pathname === "/api/health") {
        return jsonResponse({ ok: true, app: "ebook-generator", storage: "kv" });
      }

      if (request.method === "GET" && pathname === "/api/jobs") {
        return jsonResponse({ jobs: await listPublicJobs(env) });
      }

      if (request.method === "POST" && pathname === "/api/jobs") {
        return await createJob(request, env);
      }

      if (request.method === "GET" && pathname === "/api/runner/jobs") {
        const unauthorized = await requireRunner(request, env);
        if (unauthorized) return unauthorized;
        const jobs = await listJobs(env);
        return jsonResponse({ jobs: jobs.filter((job) => job.status === "Queued") });
      }

      let runnerJobId = getRunnerRouteId(pathname, "/claim");
      if (request.method === "POST" && runnerJobId) {
        const unauthorized = await requireRunner(request, env);
        if (unauthorized) return unauthorized;
        const job = await readJob(env, runnerJobId);
        if (!job) return textResponse("Job not found", { status: 404 });
        if (job.status !== "Queued") return jsonResponse(job);
        const payload = await request.json().catch(() => ({}));
        job.status = "Running";
        job.error = "";
        job.runner = {
          name: payload.runnerName || "Local Book Runner",
          claimedAt: nowIso()
        };
        appendJobLog(job, "Claimed by " + job.runner.name + ".");
        await writeJob(env, job);
        return jsonResponse(job);
      }

      runnerJobId = getRunnerRouteId(pathname, "/files");
      if (request.method === "GET" && runnerJobId) {
        const unauthorized = await requireRunner(request, env);
        if (unauthorized) return unauthorized;
        const job = await readJob(env, runnerJobId);
        if (!job) return textResponse("Job not found", { status: 404 });
        return jsonResponse({ job, files: await getJobFiles(env, job) });
      }

      runnerJobId = getRunnerRouteId(pathname, "/log");
      if (request.method === "POST" && runnerJobId) {
        const unauthorized = await requireRunner(request, env);
        if (unauthorized) return unauthorized;
        const job = await readJob(env, runnerJobId);
        if (!job) return textResponse("Job not found", { status: 404 });
        const payload = await request.json().catch(() => ({}));
        appendJobLog(job, payload.message || "");
        await writeJob(env, job);
        return jsonResponse(job);
      }

      runnerJobId = getRunnerRouteId(pathname, "/artifacts");
      if (request.method === "POST" && runnerJobId) {
        const unauthorized = await requireRunner(request, env);
        if (unauthorized) return unauthorized;
        const job = await readJob(env, runnerJobId);
        if (!job) return textResponse("Job not found", { status: 404 });
        const payload = await request.json();
        const artifacts = Array.isArray(job.artifacts) ? job.artifacts : [];
        const fileName = payload.fileName || payload.name || "artifact.bin";
        const artifactKey = "job:" + runnerJobId + ":artifact:" + crypto.randomUUID().replace(/-/g, "");
        const size = Number(payload.size || estimateBase64Bytes(payload.contentBase64));
        await env.BOOK_STUDIO_KV.put(artifactKey, JSON.stringify({
          name: payload.name || fileName,
          fileName,
          contentType: payload.contentType || "application/octet-stream",
          size,
          contentBase64: payload.contentBase64 || ""
        }));
        artifacts.push({
          name: payload.name || fileName,
          fileName,
          contentType: payload.contentType || "application/octet-stream",
          size,
          key: artifactKey,
          url: "/api/jobs/" + runnerJobId + "/artifact?name=" + encodeURIComponent(fileName)
        });
        job.artifacts = artifacts;
        appendJobLog(job, "Uploaded artifact: " + fileName + ".");
        await writeJob(env, job);
        return jsonResponse(job);
      }

      runnerJobId = getRunnerRouteId(pathname, "/complete");
      if (request.method === "POST" && runnerJobId) {
        const unauthorized = await requireRunner(request, env);
        if (unauthorized) return unauthorized;
        const job = await readJob(env, runnerJobId);
        if (!job) return textResponse("Job not found", { status: 404 });
        const payload = await request.json().catch(() => ({}));
        job.status = "Completed";
        job.outputSummary = payload.outputSummary || "";
        appendJobLog(job, "Completed by local Book Runner.");
        await writeJob(env, job);
        return jsonResponse(job);
      }

      runnerJobId = getRunnerRouteId(pathname, "/fail");
      if (request.method === "POST" && runnerJobId) {
        const unauthorized = await requireRunner(request, env);
        if (unauthorized) return unauthorized;
        const job = await readJob(env, runnerJobId);
        if (!job) return textResponse("Job not found", { status: 404 });
        const payload = await request.json().catch(() => ({}));
        job.status = "Failed";
        job.error = payload.error || "Runner failed.";
        appendJobLog(job, "Failed: " + job.error);
        await writeJob(env, job);
        return jsonResponse(job);
      }

      runnerJobId = getRunnerRouteId(pathname, "/cancel");
      if (request.method === "POST" && runnerJobId) {
        const unauthorized = await requireRunner(request, env);
        if (unauthorized) return unauthorized;
        const job = await readJob(env, runnerJobId);
        if (!job) return textResponse("Job not found", { status: 404 });
        const payload = await request.json().catch(() => ({}));
        job.status = "Canceled";
        job.error = "";
        appendJobLog(job, payload.reason || "Canceled by local Book Runner.");
        await writeJob(env, job);
        return jsonResponse(job);
      }

      runnerJobId = getRunnerRouteId(pathname, "/requeue");
      if (request.method === "POST" && runnerJobId) {
        const unauthorized = await requireRunner(request, env);
        if (unauthorized) return unauthorized;
        const job = await readJob(env, runnerJobId);
        if (!job) return textResponse("Job not found", { status: 404 });
        const payload = await request.json().catch(() => ({}));
        job.status = "Queued";
        job.error = "";
        job.runner = null;
        appendJobLog(job, payload.reason || "Requeued for local Book Runner.");
        await writeJob(env, job);
        return jsonResponse(job);
      }

      const artifactJobId = getRouteId(pathname, "/artifact");
      if (request.method === "GET" && artifactJobId) {
        const job = await readJob(env, artifactJobId);
        if (!job) return textResponse("Job not found", { status: 404 });
        const name = url.searchParams.get("name") || "";
        const found = await getArtifact(env, job, name);
        if (!found) return textResponse("Artifact not found", { status: 404 });
        const bytes = base64ToBytes(found.record.contentBase64);
        return new Response(bytes, {
          headers: {
            "content-type": found.record.contentType || found.artifact.contentType || "application/octet-stream",
            "content-disposition": "attachment; filename=\"" + (found.record.fileName || found.artifact.fileName || "artifact.bin") + "\"",
            "cache-control": "no-store"
          }
        });
      }

      const jobId = getRouteId(pathname);
      if (request.method === "GET" && jobId) {
        const job = await readJob(env, jobId);
        if (!job) return textResponse("Job not found", { status: 404 });
        return jsonResponse(publicJob(job));
      }

      return textResponse("Not found", { status: 404 });
    } catch (error) {
      return textResponse(error && error.message ? error.message : "Unexpected error", { status: 500 });
    }
  }
};
