# Book Studio Architecture

Book Studio is the first local interface layer for the ebook generator. It is designed for instructional designers who should be able to create a book job from a browser without running generator commands directly.

## Current Local Flow

1. The user opens `http://localhost:8790/`.
2. The user enters a course code, title, production notes, and uploads source files.
3. The local PowerShell server stores the job in `.bookstudio/book-studio-db.json`.
4. Uploaded source files are copied into `.bookstudio/uploads/<job-id>/`.
5. The runner first starts `ebook-generator.ps1 -BlueprintOnly` in a background PowerShell process.
6. The runner writes a `book-format-preview.html` format contract showing the proposed cover, chapter hierarchy, objectives treatment, visual treatment, and course structure.
7. The instructional designer reviews the preview and either records requested changes or approves the format. Full generation cannot start until approval is recorded.
8. After approval, the runner starts the full generator and writes outputs into `.bookstudio/outputs/<job-id>/`.
9. The UI refreshes job status and exposes links to the Word, HTML, Markdown, reports, and source registry artifacts.
10. Completed packages can be split into chapter-level source files under `chapters/`.
11. The instructional designer can edit chapter Markdown/JSON locally, use Ask Codex for scoped review/revision, then rebuild the package exports.
12. Book Studio can prepare a no-install SME review package under `sme-review/` plus `sme-review-package.zip`.

## Database

The first implementation uses a dependency-free local JSON database because this workstation does not currently have Node, Python, dotnet, sqlite3, or a SQLite provider installed. The database is still structured as tables-in-document form:

- `jobs`: one record per book generation request
- `uploadedFiles`: files attached to the job
- `options`: generator options
- `artifacts`: generated files exposed to the UI
- `log`: status events and runner messages
- `workflowStage`: `format-review`, `generating`, `id-review`, or `sme-review`
- `formatReview`: approval status, notes, reviewer, and timestamp for the format gate

This can later be migrated to SQLite or Cloudflare D1 without changing the job model.

## Chapter Source Model

Chapter-level files are now the editable source layer for production review:

- `chapters/manifest.json`: package-level chapter manifest, preface Markdown, and chapter metadata.
- `chapters/chapter-##-<slug>.md`: editable chapter Markdown.
- `chapters/chapter-##-<slug>.json`: structured chapter record with title, status, notes, section headings, word count, and Markdown content.

The course-named Markdown, HTML, Word, and reviewer packages should be treated as generated exports. If an instructional designer edits a chapter in Book Studio, Book Studio updates the chapter files, rebuilds the combined ebook Markdown, and can rerun the package rebuild/export validation flow.

## Canonical Package Contract

All new development should target the canonical package format. Legacy package support exists only so older `dist/` folders can be imported, reviewed, and migrated.

Canonical package requirements:

- Course-named ebook exports:
  - `<course> - E-Book.md`
  - `<course> - E-Book.html`
  - `<course> - E-Book.docx`
- Chapter source files:
  - `chapters/manifest.json`
  - `chapters/chapter-##-<slug>.md`
  - `chapters/chapter-##-<slug>.json`
- Review package outputs:
  - `sme-review/index.html`
  - `sme-review-package.zip`
- Production reports and registries:
  - `quality-report.json/.md`
  - `publishing-editor-report.json/.md`
  - `agent-report.json/.md`
  - `export-validation.json/.md`
  - `ebook-output-audit.json/.md`
  - `sources.json/.md`
  - `engagement-plan.json/.md`

Legacy compatibility:

- `ebook.md`, `ebook.html`, and `ebook.docx` may be imported from old packages.
- Book Studio may split legacy `ebook.md` into chapter source files.
- New generator, rebuild, review, SME export, and AI-assist work should not introduce new dependencies on legacy names.

## Source Privacy Rule

Uploaded syllabi, learning-objective files, Word documents, and production notes are private build context. They can shape the plan and support alignment checks, but they must not appear as student-facing citations or source links.

Student-facing references should include only academic, open education, library-quality, or reviewed research sources such as OpenStax pages and scholarly research records.

## Next Architecture Step

For shared team use, the same model can move to a hybrid architecture:

- Cloudflare hosts the shared intake UI and job database.
- A local Book Runner polls for queued jobs.
- The local runner performs ebook generation using the authenticated local AI/Codex environment.
- The runner uploads finished DOCX/HTML/report artifacts back to Cloudflare.

That keeps API keys out of the instructional designer workflow while still giving colleagues a shared interface.

## Codex Connection Model

Book Studio intentionally runs on `localhost` and invokes the Codex CLI installed on the instructional designer's machine. Each Ask Codex request is a bounded local process with a package- or chapter-scoped prompt, recent conversation history, and a saved response/log folder. The browser is not given an API key and the local server is not exposed as a public listener.

The current chat experience is conversation-like rather than a persistent Codex app-server session: Book Studio injects recent turns into the next request. This keeps setup simple and makes each revision auditable. A persistent Codex session can be added later without changing the workflow gate or chapter source-of-truth model.

## External Reviewer Rule

Subject matter experts, copy editors, and other external reviewers should not need a local copy of this repository, PowerShell scripts, Codex CLI, VS Code, or a local Book Studio server.

The local Book Studio workflow is for instructional designers and production users who generate, revise, rebuild, and approve packages. External reviewers should receive a browser-based review experience or exported review artifact:

- A hosted HTML review package with chapter text, visuals, source notes, and comment/approval controls.
- A Word export when the review role truly needs Word-based editing or copyediting.
- A structured comment file or cloud database record that can be reconciled back into chapter-level JSON/Markdown.

This means chapter-level files should become the source of truth before the shared review workflow is built. Word and hosted HTML should be generated from those chapter records, not treated as the canonical editable source.

## No-Install SME Review Package

Until the hosted reviewer portal exists, Book Studio can generate a portable review package:

- `sme-review/index.html`: browser-based chapter review interface.
- `sme-review/images/` and `sme-review/visuals/`: copied package assets for reviewer display.
- `sme-review/feedback-template.json`: empty structured feedback shape.
- `sme-review-package.zip`: shareable zip of the review interface and assets.

The reviewer opens the HTML file, reviews chapters in the browser, records chapter decisions/comments, and downloads feedback JSON. That feedback is designed to map back to chapter IDs and chapter-level source files.
