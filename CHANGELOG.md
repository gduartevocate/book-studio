# Book Studio ID Changelog

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

