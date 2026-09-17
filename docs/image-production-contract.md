# Real chapter images: production contract

Book Studio v2026.09.17.1 enables real chapter-image generation by default in the browser, form reset, and server-side job creation. CLI generation already defaults on. Existing saved options are not silently rewritten.

The scaffold no longer creates PowerShell-drawn PNGs or SVG opener fallbacks. Teaching diagrams are separate assets and never count as generated chapter banners. Disabling generation saves an incomplete text scaffold, not a finished book.

## Required checks

1. The image plan must cover all planned chapters with unique, package-local PNG paths.
2. The background Codex image pass explicitly invokes the installed imagegen skill and built-in tool. No API-key, downloaded-image, or locally drawn fallback is allowed.
3. Each original output must have a matching image-tool result from this run. Ordinary assistant messages, shell output, file changes, dimensions, and byte size alone do not prove generation.
4. Codex CLI code-mode calls can be absent from `exec --json`. The adapter reads only the exact launched session's local rollout, links image calls through any wait cells, and records the matching result. Unsupported receipt formats fail closed. Never dump base64 image results to logs or prompts.
5. `image-production.json` and per-image receipts bind chapter, path, original source, prompt, and SHA256. All chapters must pass. Changed files, missing receipts, duplicate artwork, invalid PNGs, or images below 1200 x 450 pixels block completion.
6. The final audit checks every generated image's Markdown/HTML reference and exact bytes in Word. The app recomputes this check rather than trusting an old PASS report. HTML preserves original image proportions.
7. A normal completed process and final response are required. The host never kills a still-running process and calls that success just because files changed.

These local records provide production traceability, not authenticated signatures or academic approval. They do not replace human review of relevance, anatomy, artifacts, accessibility, composition, and final page layout.

## Failure and retry

Authentication errors, unavailable image tools, service limits, timeouts, and partial batches leave image production incomplete. Successfully verified images are kept. A retry of an incomplete image stage resumes images and exports only; it does not rewrite the manuscript or regenerate verified chapters. Original artwork is backed up before replacement.

Manual diagnostic/recovery command:

```powershell
.\ebook-generator.ps1 -ResumeImageOutputFolder 'C:\path\to\book-package' -CodexCommandPath 'C:\path\to\codex.exe'
```

This uses the existing book's identity and content. Never point recovery at an example book or another course's folder.

## Regression and deployment checks

Run `powershell -NoProfile -File tests/image-production-regressions.ps1`. The distribution packager now runs this gate before producing a ZIP. The suite uses isolated synthetic test assets, never production artwork.

Before deployment, also perform one real background image generation on the target machine/profile, verify the receipt and actual exports, and review the output. A text-only connection test is not proof that image generation works. Availability and quota cannot be guaranteed by code; the guarantee enforced here is that a failure cannot silently become substitute artwork or a completed book.

After updating this development copy, wait for active jobs/chat to finish, use **Stop Book Studio.cmd**, then **Start Book Studio.cmd**, and hard-refresh. Confirm **v2026.09.17.1** before starting the next book.
