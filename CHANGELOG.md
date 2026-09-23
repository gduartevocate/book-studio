# Book Studio ID Changelog

## v2026.09.23.11 (2026-09-23)

- A book stopped by the Codex usage limit after its chapters were written now says the chapters are saved, and its button reads Finish images: it draws the missing images and rebuilds the Word and HTML files without writing the chapters again.

## v2026.09.23.10 (2026-09-23)

- A book that runs out of Codex quota after its chapters are written keeps its manuscript; finish the images with Generate images for saved setting once the limit resets.

## v2026.09.23.9 (2026-09-23)

- Book Studio says when it has been signed out or cut off, instead of silently stopping.

## v2026.09.23.8 (2026-09-23)

- Security fixes from the audit; a Guide link in Book Studio; chapter links limited to web, email and in-book addresses.

## v2026.09.23.7 (2026-09-23)

- Read the readings from the course document again, for a book whose saved list is out of date.

## v2026.09.23.6 (2026-09-23)

- Change a book's setup without deleting it: rename, replace the document, correct the document kind.

## v2026.09.23.5 (2026-09-23)

- A course document that lists its readings by week again no longer produces duplicate chapters.

## v2026.09.23.4 (2026-09-23)

- A book parked at format review stops reporting itself as generating, and a refusal now says why.

## v2026.09.23.3 (2026-09-23)

- Settings actions work through the web again: the browser's Origin is no longer sent to the local server.

## v2026.09.23.2 (2026-09-23)

- Settings now shows which computer is writing your books, and lets you test it.

## v2026.09.23.1 (2026-09-23)

- One site: Book Studio and the cloud settings live at the same address.

## v2026.09.22.9 (2026-09-22)

- Each computer reports which Book Studio it runs and whether it keeps itself up to date.

## v2026.09.22.8 (2026-09-22)

- Book Studio keeps itself up to date on every connected computer.

## v2026.09.22.7 (2026-09-22)

- The real Book Studio is reachable in a browser: the agent carries requests to the copy on your own PC.

## v2026.09.22.6 (2026-09-22)

- Book Studio starts in its own window, confirms it connected, and refuses to run twice.

## v2026.09.22.5 (2026-09-22)

- A Codex check that times out is reported as unknown rather than broken.

## v2026.09.22.4 (2026-09-22)

- Each computer is listed separately, and the agent says when the cloud has accepted it.

## v2026.09.22.3 (2026-09-22)

- The agent starts on computers that forbid running script files, and the front page shows whose books are whose.

## v2026.09.22.2 (2026-09-22)

- Cloud sign-in with Book Studio accounts, and one command to connect a computer.

## v2026.09.22.1 (2026-09-22)

- New: each book chooses its reading level. Pick it in step 3 of New book, or in Sources and image setting on an existing book. Grade 8 remains the default and stays selected unless you change it.
- The choice reaches everything: the drafting pass is now told the target and that it is measured, and the quality report and output audit enforce that grade instead of a fixed 8.
- The drafting pass was previously never told any reading target at all, which is why books were measured against a standard they had not been asked to write to.
- A missing or out-of-range value falls back to grade 8 rather than removing the check, and raising the reading level does not relax any other gate.

## v2026.09.21.12 (2026-09-21)

- Fix: a book no longer fails objective traceability because the drafting pass turned the Learning Objectives list into bullets. The gate reads that list as a numbered list restarting at 1 in each chapter, but the drafting instruction never said so, and a book whose objectives were word-perfect was refused with "Markdown has 0 rendered objective(s)".
- The instruction now states the format, and the numbering is restored automatically if it drifts. Only the list marker changes; objective wording is never touched.

## v2026.09.21.11 (2026-09-21)

- New: a book can now use its required readings and research additional sources as well. Previously these were mutually exclusive, so a course document's reading list ruled out any wider evidence.
- Tick "Also research additional sources beyond the required readings" in step 2 of New book, or in Sources and image setting on an existing book. It applies only to the required-readings policy.
- Required readings stay locked: every one must still be taught and cited. Researched sources are added on top of them, each cited by its own URL and marked as research rather than an assigned reading.

## v2026.09.21.10 (2026-09-21)

- Fix: generation no longer fails before drafting starts. With required readings assigned, the release gate ran on the scaffold and demanded a numbered source note for every reading, which is what the Codex drafting pass writes. Generation aborted in under a minute with dozens of "required reading needs one numbered source note" errors and Codex never ran.
- The gate now runs after drafting, on the finished manuscript, where it still blocks a book that has not cited its assigned readings.

## v2026.09.21.9 (2026-09-21)

- Fix: PDF readings are now readable without installing anything. Checking sources refused every PDF with "Install the Poppler pdftotext utility", which a designer without administrator rights cannot do. Book Studio now finds pdftotext inside the Git for Windows installation you already have, so CMS and AHIMA PDFs are retrieved as teaching text.

## v2026.09.21.8 (2026-09-21)

- Fix: a curriculum draft that assigns readings per week in its grid now has them read per week. The reading list lives in one grid row with a cell per week; reading it in document order flattened that row and assigned every reading in the course to the last week seen. RB1010 went from 40 readings all in chapter 5 to 40 spread across its five weeks.
- Activity rows that cite the same readings are read per week too, and their prose is no longer turned into readings with no URL.

## v2026.09.21.7 (2026-09-21)

- Fix: the course-outcome analysis was building its Codex prompt without the curriculum draft text. It read the draft through a call that always failed, inside a catch that replaced it with nothing, so the analyzer only ever saw the parsed course structure. It now reads the draft, and says so in the book log when it cannot.
- Adds a repository hygiene check that catches unexported functions called across the module boundary, lost file encodings, and client scripts the server does not serve.

## v2026.09.21.6 (2026-09-21)

- Healthcare revenue cycle and medical coding courses now have their own content domain. Previously they fell back to the business/office-operations templates, which gave every chapter the same focus and proposed office-operations section titles such as "What Are Business and Office Operations?" for a medical coding book.
- Each chapter now gets its own focus (revenue cycle stages, documentation and coding, claim completion and payers, errors and denials, integrated assessment), and section titles come from the course's own learning objectives.
- Detection is narrow: it looks for revenue cycle, coding, billing, claim form, and payer wording in the course and week titles. A general healthcare course is unaffected.

## v2026.09.21.5 (2026-09-21)

- Fix: a book whose runner never started no longer reports "Generation in progress" with no way to continue. The status is now checked against an actual running process, so the button that starts the format preview stays available.
- Books already stuck in that state are repaired automatically when the book list is read.
- Before the first run, the button now reads "Create format preview" instead of "Recreate preview".

## v2026.09.21.4 (2026-09-21)

- The course-outcome analysis now writes learning objectives in the instructional-designer pattern: exactly two per course objective, forming an enabling objective (Identify, Describe, Differentiate) followed by a terminal objective that performs the course objective itself.
- It no longer splits a course objective into parallel same-level objectives by topic or code set.
- The terminal verb is decided per course objective, either holding the course objective's verb or lifting one level where the course genuinely assesses that judgment, and the analysis states which was chosen and why. Change it in the editor if you disagree; no rerun needed.

## v2026.09.21.3 (2026-09-21)

- Fix: a book waiting for its course-outcome review no longer reports "Generation in progress". It was created with a runner status, so the app claimed it was generating, hid the review action, refused to delete the book, and re-rendered the page on every poll. That re-render is what made the page blink, and it discarded anything typed into the outcome editor mid-review.
- Books already stored in that state are repaired automatically when the book list is read.
- The outcome review panel now redraws only when the analysis actually changes, so a background refresh cannot wipe a half-written review.

## v2026.09.21.2 (2026-09-21)

- Fix: approving course outcomes now writes the Word version of the Course Outcomes document. In v2026.09.21.1 the Word export failed silently and only the Markdown files were produced; the approval itself was never at risk.

## v2026.09.21.1 (2026-09-21)

- Curriculum drafts now get a course-objective and learning-objective review before the book is planned.
- New book step 2 asks whether the authoritative document is a curriculum draft or an ebook-ready course file. Ebook-ready files behave exactly as before.
- A curriculum draft stops at Step 1: Course objectives and learning objectives. Analyze with Codex proposes reworked LO1.1-style learning objectives under each course objective, plus a chapter assignment for every outcome. Nothing is applied until you approve it.
- Course objectives are reproduced word for word. Approval is refused if one is reworded, dropped, or invented, and the refusal quotes both the document wording and the suggestion.
- Codex is optional: with no connection the editor still opens, prefilled with the course objectives as the draft states them, and you can write the learning objectives yourself.
- Approving writes a Course Outcomes record (Markdown and Word) and a reusable ebook-ready course file you can upload for a later book to skip the review.

## v2026.09.20.2 (2026-09-20)

- Course learning objectives are kept word for word when prohibited learner sections are removed, so a book whose objective names a knowledge check no longer fails objective traceability. Prohibited labels are matched only where they open a line, so ordinary prose that mentions a chapter summary no longer fails a book.

## v2026.09.20.1 (2026-09-20)

- Generating a book now applies the same publication normalization that Rebuild Package applies, so the export gates judge the manuscript that ships. A finished book no longer fails at export for a heading the rebuild would have cleaned. Stop Codex request is offered after View repair conversation and is covered by the browser tests.

## v2026.09.19.1 (2026-09-19)

- The publication gate now flags only prohibited learner sections, bold labels, and interactive-study links, and names the chapter and the exact text. Ordinary prose that mentions a chapter summary or an interactive study no longer fails a whole book. A stuck Codex request is recovered when you open a job, can be stopped from the request card, and a blocked deletion now names the job holding the book. Chapter cards no longer read Complete while Codex is still drafting.

## v2026.09.18.14 (2026-09-18)

- A reading assigned to all chapters is now treated as a shared resource: available to every chapter and required in none, so a general reading list no longer demands every source be cited in every chapter.
- A reading assigned to a specific week is still required in that chapter, and every chapter must still cite at least one assigned reading from its teaching.

## v2026.09.18.13 (2026-09-18)

- Moving the Book Studio folder no longer strands its books: stored file locations are repointed at the new folder on startup, so previews, outlines and generation keep working after a move out of OneDrive.
- Failed actions now show the reason beside the buttons instead of appearing to do nothing.
- A book whose generation failed gets a Recreate format preview action, so a missing or outdated approval is recoverable.

## v2026.09.18.12 (2026-09-18)

- Fixes generation failing with "Could not find file ... source-readings" right after a reading was skipped.
- The writer's source brief is now built only from readings whose text was retrieved, and Codex is told never to quote or attribute a claim to a reading that could not be read.

## v2026.09.18.11 (2026-09-18)

- Required readings that cannot be retrieved no longer stop generation; they are skipped, listed with the reason in the source report and the Sources panel, and never used as teaching evidence.
- Source retrieval now sends normal browser headers, which recovers public pages that previously answered 403 Forbidden.
- Mark a source (reference only) in the reading list for a video, interactive tool, dataset, or sign-in page so it is cited without being read.
- Every chapter still needs at least one reading whose text was retrieved, and a reading with a missing or wrong URL still blocks.

## v2026.09.18.10 (2026-09-18)

- Sources and image setting is now visible on the active book screen, where the required-readings message points.
- New Remove entries with no URL button clears learning objectives an older version saved as readings, keeping genuine linked readings.
- The blocked-generation message names the exact button to use and the alternative for courses with no assigned reading list.

## v2026.09.18.9 (2026-09-18)

- Deleting a book stored in OneDrive works again; only real shortcuts (junctions and symbolic links) are refused, and the message names the file.
- A book that shares files with a duplicate entry can now be removed from the library while its files are kept.
- Codex is found automatically when installed with npm, so Test connection no longer asks for the native codex.exe on a fresh install.
- The launcher again reports available updates and warns about long or OneDrive install paths.

## v2026.09.18.8 (2026-09-18)

- Recover stale Codex request statuses across all books and archived conversations at startup and before updating. Use recorded exit codes and process identity to distinguish finished/interrupted requests from live work, including recycled Windows process IDs.
- Keep active Codex work protected and explain that stopping the web server does not stop its independent runner. Recovery preserves responses and partial edits; it does not call Codex or automatically rebuild content.
- Include a standalone Repair Book Studio Update helper for older installations trapped behind the stale-status update check. It backs up the book database and leaves installed application files unchanged so normal updates remain available.
- Fix the stop-server fallback assigning to PowerShell's read-only PID variable.

## v2026.09.18.7 (2026-09-18)

- Separate outline readiness, required-source readiness, and manuscript QA. Planning-only packages no longer receive missing-manuscript citation/image findings or inherit stale book QA failures.
- Add Run QA again for saved previews and manuscripts, with a dated result and visible errors. Refresh validation and review reports without rewriting manuscripts, outlines, or exports. Required-source retrieval remains a separate retry action.
- Parse titled Week/Chapter headings as assignment labels, preserving real title-only readings for correction. Previously saved title-only entries remain visible until corrected in Sources and image setting.
- Show Delete book in every book stage, including previews and failures, with typed confirmation. Block deletion during generation/Codex work, restrict cleanup to the book's own managed folders, and surface cleanup errors instead of silently hiding the book.
- Outline saves refresh the HTML preview, Word/Markdown outlines, and planning packets together, with backups and a persistent receipt. Locked files or export errors stop the update before publication.
- Add a separate review-and-confirm workflow for revised CO/LO catalogs and chapter assignments. The original blueprint is preserved; a hash-bound, attributed amendment becomes the effective source for future planning, drafting, and objective traceability. Chat suggestions still do not silently change official outcomes.
- Include writer guidance in preview approval fingerprints, preserve it through drafting, refresh chapter connections, and avoid reintroducing generic default topics into a reviewed outline.
- Decode browser JSON as UTF-8 to preserve curly apostrophes and other non-ASCII text. No manuscript is written by either planning action.

## v2026.09.18.6 (2026-09-18)

- Accept standalone Week 1, Week1, and colon/Markdown week headings in content documents. Preserve numbered objectives and lesson assignments, including a course objective split across weeks. Missing course descriptions no longer invent a critical-thinking subject.
- Separate blueprint source extraction from the designer's explicit reading list. Week headings and objectives are not readings; actual links and explicit reference sections remain supported. Merge repeated URLs without dropping chapter assignments.
- Explain empty reading lists in the UI and reject missing/title-only required readings before launching full generation. Existing saved lists are preserved for review, not silently rewritten. Empty plan lists serialize as arrays rather than null.
- Replace the misleading wrong-file/rename advice with an explanation of the unrecognized structure. Add regression coverage for bare headings, shared objective assignments, source extraction, and the real HTTP preview/approval workflow.

## v2026.09.18.5 (2026-09-18)

- Required-reading mode extracts weekly links from the blueprint, including embedded Word hyperlinks, and accepts additional designer-specified URLs. The blueprint is not a scholarly source. Uploaded-only mode now requires separate teaching evidence.
- New and existing books have source-list and image-setting controls. Save settings explicitly; check required sources in a background task before asking Codex to revise existing teaching and citations. Per-reading reports show retrieved text or the reason a link was blocked.
- Retrieve actual article/PDF text into hashed source snapshots before drafting. Reject private-network URLs, title-only assignments, unavailable content, and OpenStax landing pages that need chapter links. PDF retrieval requires Poppler pdftotext; missing dependencies are reported, not silently bypassed.
- Required-source QA checks chapter assignments, retrieved-text hashes, exact bibliography URLs, and linked body citations. It rejects blueprint bibliography entries and unassigned sources. Human review still verifies claim accuracy and permissions.
- Choose Generic, Healthcare, Business, or Custom image settings and additional instructions. Explicitly generate missing/changed images for the saved setting without redrafting chapters. Old images are backed up; old-setting receipts cannot count as newly generated artwork.
- QA now shows remaining findings, corrects false failures for supported Scholarly Sources headings, and excludes bibliography prose from readability checks. Rebuild completion no longer leaves a stale Full generation failed workflow label; genuine failures remain visible.

## v2026.09.18.4 (2026-09-18)

- Normalize equivalent section headings, Business Case labels, modeled-artifact/toolbox labels, and immediate synthesis wrappers without replacing manuscript prose. Back up the original before saving normalized text.
- Safely normalize matching standalone/inline citation anchors, including escaped forms. Preserve source details; still reject wrong chapter/note IDs, broken links, invalid numbering, and unsupported markup.
- Validate manuscripts before fresh or resumed image generation. Remaining structure/citation findings get one targeted repair and a recheck; failed repairs stop before images and retain separate logs and backups.
- Failed books with a saved manuscript now offer Rebuild Package, avoiding another AI generation for recoverable export failures. Existing content and source-integrity checks remain enforced.
- Introduction checks recognize both supported heading levels and no longer count learning objectives as introduction prose.

## v2026.09.18.3 (2026-09-18)

- Preserve the original generator error and repair-log location. Automatic QA repair now requires a confirmed QA failure and current evidence of completed drafting; interrupted, empty-response, and stale runs do not start another edit pass.
- Drafting rejects missing or stale exit results and final responses. Drafting and repair prompts spell out the exact Opening Scenario/Business Case format required by publication checks.
- Format-review suggestions can be applied directly to the outline and regenerate the preview, alongside the existing load-and-review option.
- Double-click Install Book Studio.cmd to create desktop shortcuts for starting and stopping Book Studio.

## v2026.09.18.2 (2026-09-18)

- Outline editor gains Guidance for the writer per chapter, carried into the outline and Codex drafting. Review with Codex at format review knows the planned outline and can hand back suggested title, focus, and guidance changes that load into the editor with one click.

## v2026.09.18.1 (2026-09-18)

- Book packages now stay under Windows' 260-character path limit (capped folder names, shorter request files) and Codex chats on long install paths no longer fail; Settings shows an Install location check with a warning for long or OneDrive paths.

## v2026.09.17.6 (2026-09-17)

- Spec sheets that use Word automatic numbering for course objectives now parse; lessons are matched to their course objective even when its number is missing, and the error names the week to fix. Spec files still open in Word can be read.

## v2026.09.17.5 (2026-09-17)

- Fix the update-progress endpoint pinning the server after a self-update restart.

## v2026.09.17.4 (2026-09-17)

- Release publisher hardening: tolerate git warnings, first-publish detection, no duplicate changelog entries.

## v2026.09.17.3 (2026-09-17)

- First release from the distribution repository; install with git clone and update from Settings > Updates.
- Course Blueprint (week-per-column) documents are accepted as the course spec alongside spec sheets.
- Codex runs in its non-admin sandbox so drafting, images, and repairs work on locked-down PCs; Test connection verifies write access.
- Fixed the startup crash that hid the book list, stale QA repair panels, and rebuilds that discarded chapter edits.
- Course-neutral Chapter 1 context gate, domain detection from titles, and claim-submission wording no longer flagged as residue.

