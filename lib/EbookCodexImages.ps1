. (Join-Path $PSScriptRoot 'EbookImages.ps1')
. (Join-Path $PSScriptRoot 'EbookCodexSandbox.ps1')

function Find-EbookRolloutImageEvidence {
    param([string]$SessionPath, [string]$SourcePath, [string]$ThreadId)
    $name = [IO.Path]::GetFileName($SourcePath)
    $imageCalls = @{}
    $imageCells = @{}
    foreach ($line in [IO.File]::ReadLines($SessionPath)) {
        try { $event = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($event.type -ne 'response_item') { continue }
        $p = $event.payload
        if ($p.type -in @('custom_tool_call','function_call')) {
            if ($p.name -match 'image_gen.*imagegen|^imagegen$' -or ($p.name -eq 'exec' -and $p.input -match 'tools\.image_gen__imagegen\s*\(')) { $imageCalls[$p.call_id] = $p.call_id }
            elseif ($p.name -eq 'wait') {
                try { $args = $p.arguments | ConvertFrom-Json; if ($imageCells.ContainsKey([string]$args.cell_id)) { $imageCalls[$p.call_id] = $imageCells[[string]$args.cell_id] } } catch {}
            }
        }
        elseif ($p.type -in @('custom_tool_call_output','function_call_output') -and $imageCalls.ContainsKey([string]$p.call_id)) {
            $text = if ($p.output -is [string]) { $p.output } else { (@($p.output | Where-Object { $_.type -in @('text','input_text') } | ForEach-Object text) -join "`n") }
            if ($text -match 'Script running with cell ID ([a-zA-Z0-9-]+)') { $imageCells[$Matches[1]] = $imageCalls[$p.call_id] }
            if ($text.Contains($name) -and $text.Contains('Generated images are saved to')) {
                # Keep the receipt locator, not the base64 image or unrelated session content.
                return ([pscustomobject]@{threadId=$ThreadId;imageCallId=$imageCalls[$p.call_id];resultCallId=$p.call_id;tool='image_gen__imagegen';sourcePath=$SourcePath;result='Generated images are saved to the original tool output path.'} | ConvertTo-Json -Compress)
            }
        }
    }
    return ''
}

function Find-EbookImageToolEvidence {
    param([string]$EventsPath, [string]$SourcePath)
    # An assistant claim or a shell command that writes a PNG is not image-tool evidence.
    $name = [IO.Path]::GetFileName($SourcePath)
    $threadId = ''
    foreach ($line in @(Get-Content -LiteralPath $EventsPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        try { $event = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($event.type -eq 'thread.started') { $threadId = [string]$event.thread_id }
        $item = $event.item
        if ($event.type -ne 'item.completed' -or $item.status -in @('failed','in_progress')) { continue }
        $imageTool = $item.type -in @('image_generation','image_generation_call') -or
            ($item.type -eq 'mcp_tool_call' -and ([string]$item.tool -match 'imagegen|image_gen|image_generation'))
        if ($imageTool -and $line.Contains($name)) { return $line }
    }
    # Codex CLI 0.144 hides code-mode image calls from exec --json. The local
    # rollout contains the actual paired tool call/result, including wait cells.
    # Read only the session launched by this run, never unrelated conversations.
    if ($threadId -match '^[a-f0-9-]{36}$' -and ($SourcePath -replace '\\','/').Contains("/generated_images/$threadId/")) {
        $codexProfile = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex' }
        $sessions = Join-Path $codexProfile 'sessions'
        $files = @(Get-ChildItem -LiteralPath $sessions -Recurse -File -Filter "*$threadId.jsonl" -ErrorAction SilentlyContinue)
        if ($files.Count -eq 1) { return Find-EbookRolloutImageEvidence $files[0].FullName $SourcePath $threadId }
    }
    return ''
}

function Invoke-EbookCodexImagePass {
    param([Parameter(Mandatory)][string]$CodexCommand, [Parameter(Mandatory)][object]$Course, [Parameter(Mandatory)][object]$Result, [int]$TimeoutSeconds=1800)
    $outputFolder = $Result.outputFolder
    $items = @(Get-EbookImagePlan $outputFolder)
    # Recover a completed tool result after a crash or a receipt-parser upgrade,
    # without paying to generate an already completed image a second time.
    $runsFolder = Join-Path $outputFolder 'image-runs'
    foreach ($run in @(Get-ChildItem -LiteralPath $runsFolder -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)) {
        $resultsFile = Join-Path $run.FullName 'results.json'
        if (-not (Test-Path -LiteralPath $resultsFile)) { continue }
        try {
            $prior = Get-Content -LiteralPath $resultsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $directionsPath=Join-Path $run.FullName 'directions.json'
            $priorDirections=if(Test-Path -LiteralPath $directionsPath){@(Get-Content -LiteralPath $directionsPath -Raw -Encoding UTF8 | ConvertFrom-Json)}else{@()}
            foreach ($entry in @($prior.images)) {
                $planned=@($items | Where-Object chapterNumber -eq $entry.chapterNumber)[0]
                $oldDirection=@($priorDirections | Where-Object chapterNumber -eq $entry.chapterNumber)[0]
                if (-not $planned -or ($planned.imageDirectionHash -and $planned.imageDirectionHash -ne $oldDirection.imageDirectionHash)) { continue }
                $current = Get-EbookImageProductionReview $outputFolder
                if ($entry.chapterNumber -in @($current.chapters | Where-Object status -eq 'PASS' | ForEach-Object chapterNumber)) { continue }
                $evidence = Find-EbookImageToolEvidence (Join-Path $run.FullName 'events.jsonl') $entry.sourcePath
                if ($evidence) { $null = Register-EbookGeneratedImage -OutputFolder $outputFolder -ChapterNumber $entry.chapterNumber -SourcePath $entry.sourcePath -Prompt $entry.prompt -Evidence $evidence }
            }
        } catch { Write-EbookProgress -Phase 'Image recovery' -Detail "Previous image result could not be verified; it remains pending. $($_.Exception.Message)" }
    }
    $before = Get-EbookImageProductionReview $outputFolder
    $pending = @($items | Where-Object { $_.chapterNumber -notin @($before.chapters | Where-Object status -eq 'PASS' | ForEach-Object chapterNumber) })
    if (-not $pending.Count -and $before.status -eq 'PASS') {
        Add-EbookGeneratedOpeners $outputFolder $Result.markdownPath
        [pscustomobject]@{status='Complete';generatedCount=$before.generatedCount;expectedCount=$items.Count;failure='';updatedAt=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputFolder 'image-production-run.json') -Encoding UTF8
        return [pscustomobject]@{changedCount=0;reportPath=(Join-Path $outputFolder 'image-production.json')}
    }
    $runId = [guid]::NewGuid().ToString('N')
    $runFolder = Join-Path $outputFolder "image-runs/$runId"
    New-Item -ItemType Directory -Path $runFolder -Force | Out-Null
    $pending | Select-Object chapterNumber,imageDirectionHash | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runFolder 'directions.json') -Encoding UTF8
    $eventsPath = Join-Path $runFolder 'events.jsonl'
    $errorPath = Join-Path $runFolder 'error.log'
    $responsePath = Join-Path $runFolder 'response.md'
    $exitPath = Join-Path $runFolder 'exit.txt'
    $resultsPath = Join-Path $runFolder 'results.json'
    $promptPath = Join-Path $runFolder 'prompt.md'
    $scriptPath = Join-Path $runFolder 'run.ps1'
    $targets = $pending | Select-Object chapterNumber,chapterTitle,openerImageFile,openerImagePrompt | ConvertTo-Json -Depth 8
    $prompt = @"
Use the installed `$imagegen skill and the built-in Codex image-generation tool to generate real chapter banner PNGs for $($Course.courseCode): $($Course.courseName).
Read $([IO.Path]::GetFileName($Result.markdownPath)), ebook-plan.json and engagement-plan.json. Match each scene to that chapter's actual objectives and content, not a generic course guess.
The pending chapter prompts below incorporate the saved image setting. Follow that scene setting even if older engagement-plan prompts or the course blueprint suggest another industry.
Generate each pending asset separately; do not create a collage. Use professional photographic/editorial imagery, wide landscape, at least 1200x450. No readable text, logos, watermarks, diagrams, clip-art, or drawn substitutes.
Pending chapters:
$targets

Do not use PowerShell, Python, System.Drawing, SVG, screenshots, web downloads, or any locally drawn fallback to create these images. Do not use an API-key fallback. If the image tool is unavailable or usage-limited, stop and state that clearly; never claim success.
Keep the original PNG paths returned by the image tool in generated_images. Do not modify the manuscript, target PNGs, production receipts, or other package files; the host will install and validate the assets.
When calling the image tool through code mode, display it with generatedImage(result). Never print or JSON-stringify result.image_url or dump raw base64 images. Do not read session logs to reconstruct the image response; use the tool's output_hint directly.
After EACH successful image, update $resultsPath as a JSON object with an images array. Each entry must contain chapterNumber, sourcePath (the original absolute generated_images PNG path), and prompt (the exact prompt used). Preserve previous successful entries if a later image fails.
Your final response must identify any missing chapters and why. File existence alone is not evidence of image generation; the host also checks completed image-tool events.
"@
    Set-Content -LiteralPath $promptPath -Value $prompt -Encoding UTF8
    $script = @"
`$ErrorActionPreference = 'Continue'
`$prompt = Get-Content -LiteralPath '$($promptPath.Replace("'","''"))' -Raw -Encoding UTF8
`$prompt | & '$($CodexCommand.Replace("'","''"))' exec -C '$($outputFolder.Replace("'","''"))' --skip-git-repo-check --sandbox workspace-write $(Get-EbookCodexSandboxConfigArgument) --json --output-last-message '$($responsePath.Replace("'","''"))' - 1> '$($eventsPath.Replace("'","''"))' 2> '$($errorPath.Replace("'","''"))'
`$LASTEXITCODE | Set-Content -LiteralPath '$($exitPath.Replace("'","''"))' -Encoding UTF8
"@
    Set-Content -LiteralPath $scriptPath -Value $script -Encoding UTF8
    $changed = 0
    $failure = ''
    try {
        $process = Start-Process -FilePath powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$scriptPath`"") -WindowStyle Hidden -PassThru
        $deadline = (Get-Date).AddSeconds([Math]::Max(10,$TimeoutSeconds))
        $heartbeat = (Get-Date).AddSeconds(30)
        while (-not $process.HasExited -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            $process.Refresh()
            if ((Get-Date) -ge $heartbeat) {
                Write-EbookProgress -Phase 'Generating real chapter images' -Detail 'Waiting for image-tool completion. Drawings and partial batches cannot pass this stage.'
                $heartbeat = (Get-Date).AddSeconds(30)
            }
        }
        if (-not $process.HasExited) {
            & taskkill.exe /PID $process.Id /T /F | Out-Null
            $failure = "Image generation timed out after $TimeoutSeconds seconds."
        }
        elseif (-not (Test-Path -LiteralPath $exitPath) -or [int]((Get-Content -LiteralPath $exitPath -Raw).Trim()) -ne 0) {
            $failure = 'Codex image generation failed. Check this run for authentication, image-tool availability, or usage-limit errors.'
        }
        # Preserve verified partial results even if the CLI failed or timed out.
        if (Test-Path -LiteralPath $resultsPath) {
            $results = Get-Content -LiteralPath $resultsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($entry in @($results.images)) {
                if ($entry.chapterNumber -notin @($pending.chapterNumber)) { throw 'Image response contains an unrequested chapter.' }
                $evidence = Find-EbookImageToolEvidence $eventsPath $entry.sourcePath
                if (-not $evidence) { throw "Chapter $($entry.chapterNumber) has no completed image-tool event. This Codex session may not expose image generation; no substitute will be accepted. See $runFolder" }
                $null = Register-EbookGeneratedImage -OutputFolder $outputFolder -ChapterNumber $entry.chapterNumber -SourcePath $entry.sourcePath -Prompt $entry.prompt -Evidence $evidence
                $changed++
            }
        }
        $response = if (Test-Path -LiteralPath $responsePath) { Get-Content -LiteralPath $responsePath -Raw -Encoding UTF8 } else { '' }
        $diagnostic = $response + "`n" + $(if(Test-Path -LiteralPath $errorPath){Get-Content -LiteralPath $errorPath -Raw}else{''})
        $sandboxProblem = Get-EbookCodexSandboxFailure -Text $diagnostic -ExpectedSandbox 'workspace-write'
        if ($sandboxProblem) { throw "Image generation could not save files. $sandboxProblem See $runFolder" }
        if ($diagnostic -match '(?i)usage limit reached|hit your usage limit|quota (?:exceeded|exhausted)') { throw "Image-generation usage limit reached. Verified images and chapter text are preserved. Retry when access is restored. See $runFolder" }
        if ($diagnostic -match '(?i)refresh token|refresh_token|not logged in|authentication failed') { throw "Codex sign-in failed during image generation. Reconnect using the app's Codex connection panel and retry; completed work is preserved. See $runFolder" }
        if ($failure) { throw "$failure See $runFolder" }
        if ([string]::IsNullOrWhiteSpace($response)) { throw "Codex exited without a final image response. See $runFolder" }
        $review = Get-EbookImageProductionReview $outputFolder
        if ($review.status -ne 'PASS') {
            $responsePreview = ($response -replace '\s+',' ').Trim()
            if ($responsePreview.Length -gt 600) { $responsePreview = $responsePreview.Substring(0,600) }
            throw "Image generation incomplete: $($review.generatedCount)/$($items.Count) verified chapter banners. Codex reported: $responsePreview See $runFolder"
        }
        Add-EbookGeneratedOpeners $outputFolder $Result.markdownPath
    } catch {
        $failure = $_.Exception.Message
        throw
    } finally {
        $review = Get-EbookImageProductionReview $outputFolder
        [pscustomobject]@{status=$(if($failure){'Incomplete'}else{'Complete'});generatedCount=$review.generatedCount;expectedCount=$items.Count;failure=$failure;runFolder=$runFolder;updatedAt=(Get-Date).ToString('o')} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $outputFolder 'image-production-run.json') -Encoding UTF8
    }
    return [pscustomobject]@{changedCount=$changed;reportPath=(Join-Path $outputFolder 'image-production.json')}
}
