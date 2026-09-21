# Ebook Generator

Dependency-light PowerShell generator for education-based ebooks. It reads a course spec, ingests provided source/book context, builds a cohesive chapter plan from weekly learning objectives, attaches OpenStax grounding pages, discovers research candidates, and exports student-ready Markdown/HTML/Word ebook files.

The generator also loads the UMA brand implementation profile in `config/uma-brand-profile.json`, derived from `2023_UMA_Full_Brand_Guide_V3.pdf`, so content tone, typography, colors, visual prompts, HTML styling, Word styling, and engagement assets follow UMA brand direction.

Before changing any code, read `AGENTS.md`. It holds the contributor rules for this repository, including the private development repository versus public distribution repository split, how the gates and manuscript cleaners must agree, how to run the regression suites, and the Windows and PowerShell traps that have broken real books. It applies to everyone working on this project, human or AI.

## Quick Start

```powershell
.\ebook-generator.ps1
```

If Windows blocks local scripts, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ebook-generator.ps1
```

Outputs are written to `dist/<course-code-course-name>/`:

- `<course> - E-Book.md` - student-facing ebook aligned to learning objectives.
- `<course> - E-Book.html` - browser-friendly review copy with clickable source links.
- `ebook-worker.js` - HTML-only Cloudflare Worker payload for serving the ebook at `/ebook`.
- `<course> - E-Book.docx` - Word document containing the full ebook with embedded visuals and clickable OER/research hyperlinks.
- `images/*.png` - AI-generated chapter opener artwork used inside the ebook.
- `visuals/*.svg` - generated chapter study-aid graphics and quick visual check cards.
- `interactive-study.html` - lightweight interactive review page linked from the chapters, with opener art and visual study assets.
- `ebook-planning-packet.json` / `ebook-planning-packet.md` / `<course> - E-Book Planning Packet.docx` - intake checklist, course concept arc, key concept introduction/reinforcement map, recommended student performance thread, planning gates, approval status, and next steps for the human-in-the-loop workflow.
- `ebook-outline.md` / `<course> - E-Book Outline.docx` - proposed academic-review outline generated before full drafting approval.
- `ebook-plan.json` - chapter-to-chapter plan.
- `source-brief.json` - OpenStax and research source metadata.
- `brand-profile.json` / `brand-profile.md` - UMA brand style profile used by the generated package.
- `sources.json` / `sources.md` - consolidated source registry and source IDs for the package.
- `source-context-index.json` - indexed chunks from the provided source/book context.
- `engagement-plan.json` / `engagement-plan.md` - generated visuals, infographics, and lightweight interaction ideas by chapter.
- `quality-report.json` / `quality-report.md` - objective/source/research alignment checks.
- `publishing-editor-report.json` / `publishing-editor-report.md` - higher education publishing-editor analysis of content, visuals, pedagogy, sources, brand fit, and production readiness.
- `agent-report.json` / `agent-report.md` - multi-agent production review results.
- `export-validation.json` / `export-validation.md` - Word package validation for real text, headings, numbered-list integrity, image references, and zero-sized image placeholders.
- `ebook-output-audit.json` / `ebook-output-audit.md` - final output audit that verifies the generated package meets the hardened feedback gates and output requirements.

Run the final output audit after generation:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\audit-ebook-output.ps1 -OutputFolder ".\dist\GM1000-Introduction-to-Business-Office-Operations" -FailOnFinding
```

## Book Studio

Book Studio is a local browser interface for instructional designers who should not need to run commands. It stores jobs, uploads, status, logs, workflow decisions, and artifact links in `.bookstudio/book-studio-db.json`, then starts a local runner for each queued book.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\book-studio.ps1
```

Designers install Book Studio from the distribution repository (`git clone https://github.com/gduartevocate/book-studio`) and update it from **Settings > Updates**, which fast-forwards the clone and restarts the server. Publish a release from this repository with `.\Publish-BookStudioRelease.ps1 -Version YYYY.MM.DD.N -Notes "..."`; it builds the package, mirrors only the staged files into the sibling `book-studio` folder, commits, tags, and pushes. This repository stays private. See `tests/book-studio-update-regressions.ps1`.

Open `http://localhost:8790/` and use **My books** as the starting point. Select a book to continue its current stage, choose **New book** to move through the guided course-details, source-document, and production-preference steps, or import an existing package. Book Studio first creates a blueprint-only format preview. Review and approve that preview before the full manuscript is generated. The active book workspace then exposes chapter review, artifacts, QA evidence, SME handoff, and delivery actions as they become relevant.

Step 2 of **New book** asks what kind of document the authoritative course file is, and the answer decides whether the book gets an outcome review first.

- **Ebook-ready course file** — the document already states the final course and learning objectives per week (the RB1000-style spec sheet). Book Studio goes straight to the format preview, exactly as before.
- **Curriculum draft** — the document is what the academic team hands over, with course objectives that are approved and weekly learning objectives written for course delivery. The book stops at a new **Course objectives and learning objectives** review before anything is planned.

In that review, **Analyze with Codex** reads the draft and proposes a reworked outcome set: every course objective reproduced character for character, two to four measurable `LO<n>.<m>` learning objectives beneath each one, a chapter assignment for every outcome, and notes on what was wrong with the draft. Nothing is applied. The designer edits the proposal, assigns outcomes to chapters, enters their name and reason, and approves; only then does the format preview run. Codex is optional here: with no connection the editor still opens, prefilled with the course objectives as the draft states them, and the designer can write the learning objectives by hand.

Course objectives are the academic team's words, so approval is refused while any of them is reworded, dropped, or invented. The refusal names the objective and quotes both the document's wording and the suggestion. Whitespace differences from a Word table cell are not a rewrite; casing and punctuation are. Chapters stay as the draft's weeks: the analysis renumbers objectives, never chapters.

Approval writes the same `book-studio-outcomes.json` amendment the post-preview outcome replacement writes, so one code path reads outcomes whichever review produced them. It also writes two documents into the job's upload folder: a `<CODE> - Course Outcomes.md/.docx` record of what was approved and why, and a `<CODE> - Ebook Course File.md` in the ebook-ready layout, which can be uploaded as the authoritative document for a later book to skip the analysis. `tests/outcome-analysis-regressions.ps1` proves that file reads back as the same chapters and objectives; `tests/book-studio-outcome-analysis-ui.ps1` covers the review panel.

Two course-document layouts are accepted as the spec: the line-based spec sheet (titled `Week N` headings with objective tables, as in the GM1000 spec sheet) and the week-per-column Course Blueprint grid (a `Week 1`..`Week N` header row with Weekly Topics, Course Objectives, and Learning Objectives rows, as in the RB1010 curriculum draft). Blueprint weeks become chapters titled from Weekly Topics, with `LO#` identifiers kept for traceability; a week without learning objectives falls back to its mapped `CO#` objectives. `tests/course-blueprint-regressions.ps1` covers both layouts.

The uploaded syllabus, learning-objective file, Word document, and production notes are private build context. They are used to shape the book and validate alignment, but they are not cited in the student-facing ebook. Learner-facing citations should come from OpenStax, other open education resources, peer-reviewed research, library sources, or reviewed academic resources.

At format review the outline editor exposes what the designer can shape before drafting: each chapter's title, focus, and **guidance for the writer** (direction Codex follows while drafting; never printed in the book). Objectives stay locked to the course source and the section standard below is fixed. **Review with Codex** at that stage sees the planned outline and ends its reply with a `SUGGESTED OUTLINE CHANGES` block that one click loads into the editor for review before saving.

The publication standard is now the reviewed GM1000 layout, with the learner-facing label **Business Case**. Its shared contract is in `config/book-publication-template.json`: Introduction and Learning Objectives precede four numbered sections for context, development, application, and integration. Required supports and exclusions are enforced at export. This is a format-only standard; objectives, sources, examples, and topics must remain specific to each course. The app preview uses the real first-chapter objectives and the same typography as the HTML export. See [the instructional-designer UX plan](docs/book-studio-id-ux-plan-20260916.md) for the Books-to-delivery workflow and visibility rules.

Completed packages can also be split into chapter-level source files under `chapters/`. The active book workspace's Chapter Review panel lets instructional designers edit chapter Markdown, save review status/notes, and optionally rebuild the Word/HTML outputs from the updated chapter source. **Review with Codex** appears after full generation and stays bound to the active book; it supports whole-book or chapter-scoped questions and revisions using the designer's local sign-in. Each request is saved with its prompt, response, and log. Book Studio runs every Codex call with Codex's non-admin Windows sandbox (`windows.sandbox = "unelevated"`), so no administrator rights or one-time elevated sandbox setup are needed on locked-down PCs. **Test connection** verifies that Codex can actually edit files (`sandbox: workspace-write`); a Codex that silently falls back to read-only is reported as a sandbox failure instead of surfacing later as "Codex did not modify the manuscript". See `tests/codex-sandbox-regressions.ps1`. Use `Prepare SME Review` to create a no-install reviewer package under `sme-review/` and `sme-review-package.zip`; SMEs can review in a browser and download structured feedback JSON without installing this repository, Codex, VS Code, or PowerShell scripts.

New development should target the canonical package format: course-named `* - E-Book.md/html/docx` exports, `chapters/manifest.json`, per-chapter `chapters/chapter-##-<slug>.md/.json`, production reports, and SME review outputs. Legacy `ebook.md/html/docx` files are supported for importing older packages only.

## Current Course

The default input is:

```text
Source\GM1000 Introduction to Business & Office Operations Spec Sheet.docx
```

## Source Grounding

The source file or source folder controls the book scope. OpenStax sources are configured in `config/openstax-map.json`. Research discovery uses OpenAlex metadata. All facts, definitions, statistics, frameworks, and examples should be traceable to source context, OER, or reviewed research.

### GM1025 assigned-reading rebuild

Use the course-specific rebuild for the September 2026 GM1025 reading assignment:

```powershell
.\rebuild-gm1025-assigned-sources.ps1
```

It reads `content/GM1025/manuscript.md` and `assigned-reading-list.json`, locks each chapter to the GM1025 spec objectives and assigned sections, and defaults to `dist/GM1025-src-v6/`. It also checks exact objectives against the original source Word document. It uses the existing GM1025 format-review package for planning/brand configuration and the original Downloads draft for provenance; these inputs must be present. The full run executes regression tests, live-link checks, Word-to-PDF rendering, independent output checks, contact-sheet generation, and the package audit. It requires Microsoft Word and the Poppler command-line tools. `-BuildOnly` skips that final verification sequence and must not be treated as a reviewed delivery.

The current review copy is `releases/GM1025 Front-Line Supervision and Team Leadership - Review Draft v6.docx`; v5 is preserved but superseded. See [the corrected book and gate evidence](docs/GM1025-editorial-gates-review-20260915.md). This workflow does not rebuild GM1000 or HU2000. Academic approval and permissions are human decisions; a successful script run does not grant either.

### Delivery gates

Shared editorial policy in `lib/EbookReadiness.ps1` requires Flesch-Kincaid grade <= 8.0 and possible passive phrases <= 4.0 per 1,000 words. Invalid measurements fail. Revise the prose; do not raise the thresholds to clear a book. Audit recalculates metrics from current prose, and the independent reviewer checks visible Word text. Quality and publishing reports must match the current manuscript; the audit must match the current Word file and policy. Missing reports or technical/editorial warnings block draft readiness in the runner, rebuild paths, and app.

For assigned-source packages, use the guarded delivery script after inspecting the current contact sheets (listed in `visual-review/contact-sheet-index.json`) and enlarged page samples. Record the real inspection in `visual-review.json`; rendering or running tests must never auto-create this approval.

```powershell
.\deliver-reviewed-book.ps1 -OutputFolder dist/GM1025-src-v6 -CourseCode GM1025 -ReviewDraft -DestinationPath 'releases/GM1025 Front-Line Supervision and Team Leadership - Review Draft v6.docx' -CheckOnly
# Remove -CheckOnly to copy the exact reviewed Word file after all checks pass.
```

Delivery reruns the audit and independent artifact review. It requires current Word/PDF hashes, all required whole-book/chapter checks, recorded inspection of every page plus at least eight enlarged pages (or every page for a shorter book), and successful checks of every assigned URL within seven days. It preserves existing releases with different hashes. `-ReviewDraft` never grants publication approval. Publication delivery without that switch additionally requires named, dated human academic and permissions approvals in `publication-approvals.json`, both bound to the exact Word SHA256. See the review document for schemas and limitations. These local records are workflow evidence, not authenticated signatures.

Point `-SourceContextPath` to the specific source file or course/book folder. Avoid pointing it at an entire multi-course repository unless you want the generator to sample from that broader tree.

The learner-facing book keeps clean OpenStax and DOI/landing-page links. API query/provenance details stay in `source-brief.json` so the book does not read like an API log.

The source registry is the source of truth for display IDs such as `OS1` and `R1`. Learner-facing chapter references use those IDs, while internal source files remain in the build manifest and source-context index instead of the student bibliography.

## Brand Style

The default UMA brand profile is `config/uma-brand-profile.json`. It captures the brand guide's practical implementation rules: care-centered and future-facing voice, Merriweather/Roboto/Arial typography, primary UMA blues, Journey Green call-to-action usage, accessible contrast, clean visual hierarchy, friendly realistic imagery, and icon/illustration guidance.

Use `-BrandProfilePath` to point to a different extracted brand profile. Use `-BrandGuidePath` to keep the generated package traceable to the source PDF. Use `-WritingStyleGuidePath` to keep the generated package traceable to the UMA AI writing style guide; by default this points to `Source\UMA Writing Style Guide for AI.docx`.

## Production Gates

Real chapter images are required for a complete book. The app defaults image generation on, never substitutes locally drawn opener artwork, verifies every chapter's production receipt, and checks the actual Word/HTML exports. Failed or partial runs remain incomplete and resume images without rewriting the manuscript. See [the image-production contract](docs/image-production-contract.md) for checks, retries, and deployment verification.

The quality report enforces chapter depth and structure. Current production draft targets include:

- at least 1,800 words per chapter
- source-context grounding for each chapter
- OpenStax/OER grounding for each chapter
- research candidates for each chapter
- cohesion bridge across chapters
- case study, evidence-use, and applied-practice sections
- clean student copy with no generator instructions, source-management notes, or raw citation clusters
- multiple engagement moments in each chapter: opener image, quick visual check, visual study aid, and interactive study activity
- descriptive image alt text and figure descriptions in generated HTML, interactive HTML, and Word image metadata
- loaded UMA brand profile for content style, visual prompts, HTML styling, Word styling, and accessible presentation
- UMA AI writing style guide compliance: active learner-facing voice, plain language, job-connected examples, a named business case, concise lists, and approved terminology
- publishing-editor analysis for higher-ed fit, chapter depth, learner experience, visual support, source integrity, and revision priorities

The agent report runs named review passes: curriculum alignment, source fidelity, OpenStax/OER, research integration, cohesion, humanization, engagement assets, image accessibility, brand style, UMA writing style, publishing editor, depth, and export.

## Commands

```powershell
.\ebook-generator.ps1 -SkipResearch
.\ebook-generator.ps1 -BlueprintOnly
.\ebook-generator.ps1 -ApproveOutline -ApprovedBy "Testing Approval"
.\ebook-generator.ps1 -SkipOpenStaxFetch
.\ebook-generator.ps1 -MaxResearchPerChapter 5
.\ebook-generator.ps1 -SourceContextPath "C:\Path\To\BookOrSourceFolder"
.\ebook-generator.ps1 -BrandProfilePath ".\config\uma-brand-profile.json" -BrandGuidePath "C:\Path\To\2023_UMA_Full_Brand_Guide_V3.pdf"
.\ebook-generator.ps1 -WritingStyleGuidePath ".\Source\UMA Writing Style Guide for AI.docx"
```

Use `-BlueprintOnly` to create the intake blueprint and academic-review outline packet before full manuscript generation. Use `-ApproveOutline` to mark the outline approved for a test or reviewed production run. Use `-SkipResearch` for faster local plan generation. Use `-SkipOpenStaxFetch` when offline; the generator will still attach configured OpenStax URLs.
