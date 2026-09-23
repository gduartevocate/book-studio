function Get-BookStudioFormatPlanSignature {
    param([string]$Path)
    $plan=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    @($plan.chapters | Sort-Object number | Select-Object number,title,focus,guidance,learningTargetRecords) | ConvertTo-Json -Depth 12 -Compress
}

function Get-BookStudioFormatState {
    param([object]$Job)
    if (-not $Job.outputFolder) { return $null }
    $preview = Join-Path $Job.outputFolder 'book-format-preview.html'
    $plan = Join-Path $Job.outputFolder 'ebook-plan.json'
    if (-not (Test-Path -LiteralPath $preview) -or -not (Test-Path -LiteralPath $plan)) { return $null }
    $settings = Join-Path $Job.outputFolder 'book-format-settings.json'
    $layout = 'standard'
    if (Test-Path -LiteralPath $settings) { $layout = (Get-Content -LiteralPath $settings -Raw -Encoding UTF8 | ConvertFrom-Json).layout }
    $planSignature=Get-BookStudioFormatPlanSignature $plan
    $templateHash=(Get-FileHash -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'config/book-publication-template.json')).Hash
    $parts = @((Get-FileHash -LiteralPath $preview).Hash, $planSignature, $layout, $templateHash)
    $manifestPath=Join-Path $Job.outputFolder 'book-format-preview.json'
    $manifest=if(Test-Path -LiteralPath $manifestPath){Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json}
    $needsRefresh=-not $manifest -or $manifest.planSignature -cne $planSignature -or $manifest.templateHash -ne $templateHash -or $manifest.layout -ne $layout -or $manifest.previewSha256 -ne $parts[0]
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $fingerprint = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts -join '|')))).Replace('-','') }
    finally { $sha.Dispose() }
    [pscustomobject]@{ layout=$layout; fingerprint=$fingerprint; previewSha256=$parts[0]; needsRefresh=$needsRefresh }
}

function Assert-BookStudioGenerationReady {
    param([object]$Job, [string]$ProjectRoot)
    if ($Job.status -in @('Running','Queued') -and $Job.runnerProcessId -and (Get-Process -Id $Job.runnerProcessId -ErrorAction SilentlyContinue)) {
        throw 'This book already has an active generation process.'
    }
    if ($Job.formatReview.required -or $Job.workflowStage -eq 'format-review') {
        $state = Get-BookStudioFormatState $Job
        if (-not $state -or $state.needsRefresh -or $Job.formatReview.status -ne 'Approved' -or $Job.formatReview.fingerprint -ne $state.fingerprint) {
            throw 'Review and approve the current format preview. A missing or outdated approval cannot start full generation.'
        }
    }
    if ($Job.options.sourceMode -eq 'Assigned') {
        $readings = @($Job.options.requiredReadings | Where-Object { $_ })
        if (-not $readings.Count) { throw 'No required readings are assigned. Open Sources and image setting, add the article/chapter URLs to use, and save before generating. Course objectives are not scholarly sources.' }
        if (@($readings | Where-Object { -not $_.url }).Count) { throw "$(@($readings | Where-Object { -not $_.url }).Count) required reading(s) have no URL. Open Sources and image setting on this book, click Remove entries with no URL to drop objectives an older version extracted by mistake, add the exact article or chapter URL for any genuine reading, then Save settings. If this course has no assigned reading list, set Sources to use to Uploaded teaching documents only and save." }
    }
    $drafting = $null -eq $Job.options.useCodexDrafting -or [bool]$Job.options.useCodexDrafting
    if ($drafting -or $Job.options.useCodexImages) {
        $command = Resolve-BookStudioCodexCommand -ProjectRoot $ProjectRoot
        if (-not $command) { throw 'Codex is not installed on this computer, or Book Studio cannot find codex.exe. Set the path in Settings, then try again.' }
        $connection = Get-BookStudioWorkingConnection -ProjectRoot $ProjectRoot -CommandPath $command.Source
        if (-not $connection -or $connection.status -ne 'PASS') { throw (Get-BookStudioConnectionRefusal -Connection $connection -Action 'AI generation') }
    }
}
