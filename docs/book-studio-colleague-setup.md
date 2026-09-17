# Book Studio Colleague Setup

For v2026.09.17.1, start with [the pilot checklist](book-studio-pilot-checklist.md) and [image-production checks](image-production-contract.md). This is a pilot candidate; clean-machine AI generation and revision still need validation. Use a local writable folder outside OneDrive/network sync.

## What Runs Where

Book Studio is a local browser interface. It runs on the user's own Windows computer and reads files from that computer.

Book Studio includes a local `Ask Codex` panel backed by Codex CLI. It can discuss the whole package or a selected chapter, and it can optionally edit package files when the user enables edits. Codex still uses the user's own local Codex/ChatGPT sign-in.

## What Each Computer Needs

Each user needs:

- A local copy of this ebook generator folder.
- Windows PowerShell.
- Permission to run local PowerShell scripts.
- Codex installed on that computer if they want Codex-assisted review.
- Their own ChatGPT/Codex sign-in through `codex login`.

No shared OpenAI API key is required.

## Install and Update

Install once with git, into a local writable folder outside OneDrive or other sync folders:

```powershell
git clone https://github.com/gduartevocate/book-studio
```

Then double-click `Start Book Studio.cmd` in that folder. Git for Windows and Codex CLI are the only prerequisites; no administrator rights are needed.

To update, open **Settings** in Book Studio and click **Check for updates**, then **Get latest updates**. Book Studio downloads the new release and restarts itself; books, uploads, and settings stay in place. The header shows an **Update available** badge when a newer release exists, and the launcher prints the same notice. Updates wait until no book is generating and no Codex request is running. Do not edit files inside the Book Studio folder; local edits block updates until they are discarded.

If you received Book Studio as a ZIP instead, it cannot update itself. Replace the folder with the new ZIP, keeping your `.bookstudio` folder.

## Start Book Studio

From the ebook generator folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-BookStudioCompanion.ps1
```

The launcher checks installation and cached sign-in, starts Book Studio, and opens the browser. Click **Test connection** to verify a real response before AI generation or chat.

To also open the Codex desktop app:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-BookStudioCompanion.ps1 -OpenCodexApp
```

## Codex Setup

If Book Studio says Codex is not installed or not signed in, use:

```powershell
codex login
```

Then refresh status and click **Test connection**. If the app uses a configured executable or profile, follow the commands and profile shown in its connection panel. Never share or copy sign-in credentials.

No administrator rights are needed. Book Studio asks Codex for its non-admin sandbox on every request, and **Test connection** passes only when Codex confirms it can edit files (`workspace-write`). If the test reports a sandbox problem, update Codex with `codex update` and test again.

If you open Codex yourself in a terminal, start it from the ebook generator folder, not from your user profile folder. Codex treats the folder it starts in as the workspace it may write to.

## Ask Codex Behavior

Ask Codex runs Codex locally from the package output folder.

That means:

- Whole-package questions can inspect the package files and reports.
- Chapter questions include the selected chapter Markdown in the prompt.
- Follow-up questions include recent Ask Codex history.
- If `Allow Codex to edit package files` is unchecked, Codex should answer without editing.
- If edits are allowed, Codex is pointed at the package folder and should not modify Book Studio application files.
- Raw prompt, response, and log files are saved under `dist/<package>/codex-requests/`.

## Import Package Behavior

The Import Package panel scans the local `dist/` folder on the same computer that is running Book Studio.

That means:

- If a package was generated on the user's computer, it appears in Import Package.
- If a package was generated on another computer, it will not appear automatically.
- To review a package from another computer, copy that output folder into this computer's `dist/` folder first.

Example:

```text
dist/
  GM1000-Introduction-to-Business-Office-Operations/
    engagement-plan.json
    images/
    visuals/
    GM1000 Introduction to Business & Office Operations - E-Book.docx
```

After the package folder exists locally under `dist/`, select it in Book Studio and choose Import.

## Current Workflow

1. Start Book Studio.
2. Confirm Codex Readiness.
3. Create a new book. Book Studio first creates a format preview; it does not start the full manuscript yet.
4. Review the `Step 1 · Review the book format` preview. Record any layout changes in the notes field or ask Codex for a format review.
5. Choose `Approve format & generate book` when the layout is correct.
6. Review artifacts, reports, and visual assets in the generated job card.
7. Use the Chapter Review panel to open chapter Markdown/JSON, edit chapter Markdown, save review notes, and optionally rebuild exports.
8. Use Ask Codex for package questions or selected-chapter revisions. Recent conversation history is included automatically; enable package edits only when you want Codex to change editable chapter source files.
9. Use the visual review controls to approve images or mark chapters that need revision.
10. Choose `Prepare SME Review` in the Chapter Review panel when the package is ready for external review.
11. Share `sme-review-package.zip` with the SME, or host the `sme-review/` folder through the later shared review workflow.
12. To replace a chapter opener image, use the `Replacement opener PNG` control in that chapter's Visual Assets card. If replacement image files are changed outside Book Studio, choose `Rebuild Package`.
13. Download/review the refreshed Word document, export validation report, and output audit report.

## Chapter Review Behavior

Completed packages can now create chapter-level source files:

```text
dist/<package>/
  chapters/
    manifest.json
    chapter-01-<title>.md
    chapter-01-<title>.json
```

These files are the production editing layer. Book Studio can save chapter Markdown changes back to the chapter files and rebuild the combined ebook Markdown, Word document, export validation report, and output audit when requested.

## Package Format Rule

New packages should use the canonical package format:

```text
dist/<course-package>/
  <course> - E-Book.md
  <course> - E-Book.html
  <course> - E-Book.docx
  chapters/
    manifest.json
    chapter-01-<title>.md
    chapter-01-<title>.json
```

Older packages may still contain `ebook.md`, `ebook.html`, or `ebook.docx`. Book Studio can import those as legacy packages, but new work should not depend on those legacy names.

## SME Review Behavior

SMEs should not need Book Studio, Codex, PowerShell, VS Code, or this repository.

Use `Prepare SME Review` to generate:

```text
dist/<package>/
  sme-review/
    index.html
    images/
    visuals/
    feedback-template.json
  sme-review-package.zip
```

The SME opens `index.html`, reviews chapters, adds comments/decisions, and downloads feedback JSON. A later workflow should import that feedback JSON into Book Studio for instructional designer review and application.

## After Changing Images

Book Studio shows the generated opener PNGs and SVG study visuals, but the Word document embeds image files at the time it is created.

For chapter opener PNGs, use the `Replacement opener PNG` control in the Visual Assets panel. Leave `Rebuild after upload` selected when the revised image should be embedded into the Word document immediately.

After replacing any image under a package folder outside Book Studio, use `Rebuild Package`. This regenerates the Word document from the existing Markdown and current image files, reruns export validation, reruns the output audit, and refreshes the job's artifact links.

## What Is Not Built Yet

- Shared cloud package storage.
- Automatic syncing between different users' computers.
- One-click visual regeneration from inside Book Studio.
- SVG study-aid replacement uploads.
- SME feedback JSON import and accept/reject/apply controls.

Those are later phases. The current version is local-first and avoids shared API keys.
