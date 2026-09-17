# Book Studio pilot checklist — v2026.09.17.1

This is a pilot candidate, not broad-rollout certification. Each instructional designer uses their own Codex sign-in. Do not distribute credentials or an existing `.bookstudio` folder.

## Restart this development copy

1. Wait for all generation and chat requests to finish. Close the Book Studio browser tab.
2. Run `Stop Book Studio.cmd`, then `Start Book Studio.cmd` in this project folder. Avoid starting a second server against the same database.
3. Confirm the header shows **v2026.09.17.1**. Hard-refresh the page if needed.
4. Click **Test connection**. A version number or cached sign-in alone is not a passing test.
5. If the app reports the refresh-token error, use the sign-out/sign-in instructions in the connection panel for its displayed executable and profile. Do not delete credential files or copy credentials from another account. Refresh status and test again.

The Account-A workspace connection test passed during development. That does not establish that a server launched under another Codex profile has a valid session. The app displays the actual profile it uses.

## First user journey

1. Use non-sensitive pilot materials. Upload a readable course blueprint and its teaching/reference documents. Select the authoritative blueprint from the list.
2. Leave **Uploaded documents only** selected. This skips external reading discovery, not Codex's network connection. Upload substantive teaching material; an objectives-only blueprint is not a complete textbook source.
3. Confirm intake counts, selected blueprint, and the exact weekly objectives in the preview. PDFs/scans must first be converted to readable DOCX/TXT. Limits: 50 uploaded files, less than 5 MB each, 40 MB total, 1 million extracted characters including notes.
4. Review the standard 12-point preview. If desired, select the larger 14-point layout and click **Apply layout & update preview**. Reopen and inspect it. Additional notes are recorded requests, not automatic formatting changes.
5. Resolve or withdraw additional requests, confirm the review checkbox, and approve the current preview. An outdated approval must be rejected.
6. Leave AI drafting and **Generate real chapter images** enabled (the defaults). Every chapter needs a distinct generated banner with a matching production receipt. Disabled, failed, or partial image generation must leave the job incomplete; no drawing fallback is allowed. Read every QA finding. A run ending is not a claim of quality or publication approval.
7. Open the actual Word output. Check chapter objectives against the blueprint, source coverage, punctuation, list restarts, links, tables, page breaks, and forbidden activities/labels. Use Word or a supported office renderer for PDF/page review; it is not bundled.
8. In chat, first send a harmless advice-only message. Then request one focused chapter revision with edits enabled. Verify the requested chapter changes, unrelated chapters remain intact, reports refresh, and the exported Word file reflects the revision.
9. Confirm missing/expired sign-in is shown as an actionable failure, and prior chat history remains readable. Review partial output before retrying a failed edit.

## Installation pilot on a second Windows account/computer

- Extract the new ZIP to a local writable folder outside OneDrive/network sync, not over an existing installation. Keep the previous installation and books.
- Prerequisites: Windows PowerShell 5.1, browser, permission to run the launcher, native `codex.exe`, and the user's own signed-in Codex account. Optional PDF rendering needs an installed office renderer.
- Run the complete journey above. Record version, Windows/Codex versions, source files, exact Word hash, results, and unresolved issues.
- Do not enable external publishing or configure Cloudflare credentials merely to test local generation.
- Development scripts and source documents are not academic or permissions approval. Those reviews remain required for publication.

## Verified here / still outstanding

Verified locally: upload validation, duplicate preservation, explicit blueprint selection, strict extraction, uploaded-only resolution, hash checks, real HTTP blueprint/format workflow, local full scaffold/Word export, stale-approval blocking, concurrent database access, and existing editorial/export regressions. The intentionally inadequate scaffold remains blocked by quality gates.

Outstanding: a full AI-authored book plus focused AI revision in the restarted user-launched app; visual review of that generated Word/PDF; second-machine installation and complete user journey. Do not call the app rollout-ready until those pass.
