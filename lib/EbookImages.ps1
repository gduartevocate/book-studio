# Chapter artwork is a produced asset, not a side effect of drawing a scaffold.
# Receipts provide production traceability; they are not a substitute for visual review.
function Get-EbookImageNativePath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -match '^[A-Za-z]:\\') { return '\\?\' + $full }
    return $full
}

function Get-EbookImageHash {
    param([string]$Path)
    $stream = [IO.File]::OpenRead((Get-EbookImageNativePath $Path))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return -join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('X2') }) }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Assert-EbookImageRaster {
    param([string]$Path)
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $stream = [IO.File]::OpenRead((Get-EbookImageNativePath $Path))
    try {
        $raster = [Drawing.Image]::FromStream($stream)
        try {
            if ($raster.RawFormat.Guid -ne [Drawing.Imaging.ImageFormat]::Png.Guid -or $raster.Width -lt 1200 -or $raster.Height -lt 450) { throw 'Image must be a valid PNG at least 1200 x 450 pixels.' }
        } finally { $raster.Dispose() }
    } finally { $stream.Dispose() }
}

function Resolve-EbookImagePath {
    param([string]$OutputFolder, [string]$RelativePath)
    if ($RelativePath -notmatch '^images/chapter-\d+-[a-z0-9-]+opener\.png$') { throw "Invalid chapter image path: $RelativePath" }
    return Join-Path $OutputFolder $RelativePath
}

function Get-EbookImageDirection {
    param([object]$Settings)
    if (-not $Settings) { return [pscustomobject]@{instruction='';hash=''} }
    $scene=switch ($Settings.context) {
        'Healthcare' { 'Use a healthcare setting, with appropriate clinical or healthcare-administration context.' }
        'Business' { 'Use a nonclinical business setting: offices, retail, customer service, or business teams. Avoid hospitals, scrubs, stethoscopes, patients, and clinical imagery.' }
        'Custom' { 'Use the custom scene instructions below.' }
        default { 'Use a neutral, everyday, nonclinical setting. Do not default to healthcare, hospitals, scrubs, stethoscopes, or patients.' }
    }
    $instruction="$scene Preserve the chapter learning concept; this setting controls the visual scene, not the course subject. Additional image instructions: $($Settings.instructions)"
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($instruction))).Replace('-','') } finally { $sha.Dispose() }
    [pscustomobject]@{instruction=$instruction;hash=$hash}
}

function Get-EbookImagePlan {
    param([string]$OutputFolder)
    $plan = Get-Content -LiteralPath (Join-Path $OutputFolder 'engagement-plan.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    $items = @($plan.items)
    if (-not $items.Count) { throw 'The chapter image plan is empty.' }
    if (@($items.chapterNumber | Sort-Object -Unique).Count -ne $items.Count -or @($items.openerImageFile | Sort-Object -Unique).Count -ne $items.Count) { throw 'Duplicate chapter image assignments.' }
    foreach ($item in $items) { $null = Resolve-EbookImagePath $OutputFolder $item.openerImageFile }
    $bookPlanPath = Join-Path $OutputFolder 'ebook-plan.json'
    if (Test-Path -LiteralPath $bookPlanPath) {
        $bookPlan = Get-Content -LiteralPath $bookPlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ((@($bookPlan.chapters.number | Sort-Object) -join ',') -ne (@($items.chapterNumber | Sort-Object) -join ',')) { throw 'Image plan does not cover every book chapter.' }
        $direction=Get-EbookImageDirection $bookPlan.imageSettings
        foreach ($item in $items) {
            $item | Add-Member -NotePropertyName imageDirectionHash -NotePropertyValue $direction.hash -Force
            if ($direction.instruction) {
                $chapter=@($bookPlan.chapters | Where-Object number -eq $item.chapterNumber)[0]
                $item | Add-Member -NotePropertyName openerImagePrompt -NotePropertyValue "Create a professional photographic/editorial chapter banner for '$($item.chapterTitle)'. Learning objectives: $($chapter.learningTargets -join '; '). $($direction.instruction) Wide landscape; no text, logos, watermarks, diagrams, or clip-art." -Force
            }
        }
    }
    return $items
}

function Get-EbookImageProductionReview {
    param([Parameter(Mandatory)][string]$OutputFolder)
    $issues = New-Object System.Collections.ArrayList
    $chapters = New-Object System.Collections.ArrayList
    try {
        $items = @(Get-EbookImagePlan $OutputFolder)
        $manifest = $null
        $manifestPath = Join-Path $OutputFolder 'image-production.json'
        if (Test-Path -LiteralPath $manifestPath) { $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        foreach ($item in $items) {
            $detail = ''
            try {
                $path = Resolve-EbookImagePath $OutputFolder $item.openerImageFile
                $records = @($manifest.images | Where-Object { $_.chapterNumber -eq $item.chapterNumber })
                if (-not $manifest -or $manifest.schemaVersion -ne 1 -or $records.Count -ne 1) { throw 'No unique image-generation receipt. Existing drawings are unverified, not finished artwork.' }
                $entry = $records[0]
                if ($item.imageDirectionHash -and $entry.imageDirectionHash -ne $item.imageDirectionHash) { throw 'Saved image setting changed. Generate images for the saved setting; rebuilding alone does not change artwork.' }
                if ($entry.status -ne 'Generated' -or $entry.provider -ne 'codex-imagegen' -or $entry.relativePath -cne $item.openerImageFile -or $entry.chapterTitle -cne $item.chapterTitle) { throw 'Image production is pending, failed, or assigned to another chapter.' }
                if (-not [IO.File]::Exists((Get-EbookImageNativePath $path))) { throw 'Generated image file is missing.' }
                if ($entry.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or (Get-EbookImageHash $path) -ne $entry.sha256) { throw 'Image changed since its generation receipt; regenerate or review it again.' }
                if ($entry.sourceSha256 -ne $entry.sha256 -or $entry.sourcePath -notmatch '[\\/]generated_images[\\/].+\.png$') { throw 'Missing original Codex generated-image provenance.' }
                if ($entry.receiptFile -notmatch '^image-receipts/[a-zA-Z0-9-]+\.json$') { throw 'Invalid image receipt path.' }
                $receiptPath = Join-Path $OutputFolder $entry.receiptFile
                if (-not (Test-Path -LiteralPath $receiptPath) -or (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash -ne $entry.receiptSha256) { throw 'Image-generation receipt is missing or changed.' }
                $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($item.imageDirectionHash -and $receipt.imageDirectionHash -ne $item.imageDirectionHash) { throw 'Image receipt belongs to a different scene setting.' }
                if ($receipt.tool -ne 'imagegen' -or $receipt.sourcePath -cne $entry.sourcePath -or $receipt.sha256 -ne $entry.sha256 -or -not $receipt.evidence -or $receipt.evidenceKind -notin @('codex-tool-event','observed-builtin-tool-result')) { throw 'Invalid image-generation evidence.' }
                Assert-EbookImageRaster $path
            } catch { $detail = $_.Exception.Message }
            $status = if ($detail) { 'FAIL' } else { 'PASS' }
            if ($detail) { [void]$issues.Add("Chapter $($item.chapterNumber): $detail") }
            [void]$chapters.Add([pscustomobject]@{chapterNumber=$item.chapterNumber;status=$status;detail=$detail;relativePath=$item.openerImageFile})
        }
        $hashes = @($manifest.images | Where-Object { $_.status -eq 'Generated' } | Group-Object sha256 | Where-Object Count -gt 1)
        if ($hashes.Count) {
            [void]$issues.Add('The same opener image is reused across chapters. Create chapter-specific artwork.')
            $duplicates = @($hashes | ForEach-Object { $_.Group.chapterNumber })
            foreach ($chapter in @($chapters | Where-Object { $_.chapterNumber -in $duplicates })) { $chapter.status='FAIL'; $chapter.detail='Duplicate artwork: a distinct chapter-specific image is required.' }
        }
    } catch { [void]$issues.Add($_.Exception.Message) }
    [pscustomobject]@{
        status = $(if ($issues.Count) { 'FAIL' } else { 'PASS' })
        generatedCount = @($chapters | Where-Object status -eq 'PASS').Count
        expectedCount = $chapters.Count
        chapters = @($chapters)
        issues = @($issues)
        detail = $(if ($issues.Count) { $issues -join ' ' } else { "All $($chapters.Count) chapter openers have matching generated-image receipts and valid PNGs. Visual review is still required." })
    }
}

function Register-EbookGeneratedImage {
    param(
        [Parameter(Mandatory)][string]$OutputFolder,
        [Parameter(Mandatory)][int]$ChapterNumber,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Evidence,
        [ValidateSet('codex-tool-event','observed-builtin-tool-result')][string]$EvidenceKind = 'codex-tool-event'
    )
    $item = @(Get-EbookImagePlan $OutputFolder | Where-Object chapterNumber -eq $ChapterNumber)
    if ($item.Count -ne 1) { throw "No unique image plan for Chapter $ChapterNumber." }
    $item = $item[0]
    $source = (Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop).ProviderPath
    if ($source -notmatch '[\\/]generated_images[\\/].+\.png$') { throw 'Use the original PNG returned by the Codex image-generation tool, not a locally drawn substitute.' }
    if ([string]::IsNullOrWhiteSpace($Prompt) -or -not $Evidence.Contains([IO.Path]::GetFileName($source))) { throw 'The tool evidence must identify this generated image.' }
    Assert-EbookImageRaster $source
    $hash = Get-EbookImageHash $source
    $manifestPath = Join-Path $OutputFolder 'image-production.json'
    $manifest = if (Test-Path -LiteralPath $manifestPath) { Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{schemaVersion=1;images=@()} }
    $target = Resolve-EbookImagePath $OutputFolder $item.openerImageFile
    New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent), (Join-Path $OutputFolder 'image-receipts') | Out-Null
    if ([IO.File]::Exists((Get-EbookImageNativePath $target))) {
        $backupDir = Join-Path $OutputFolder ('image-backups/' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        [IO.File]::Copy((Get-EbookImageNativePath $target), (Get-EbookImageNativePath (Join-Path $backupDir ([IO.Path]::GetFileName($target)))))
    }
    [IO.File]::Copy((Get-EbookImageNativePath $source), (Get-EbookImageNativePath $target), $true)
    $receiptFile = "image-receipts/$ChapterNumber-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
    $receiptPath = Join-Path $OutputFolder $receiptFile
    [pscustomobject]@{tool='imagegen';sourcePath=$source;sha256=$hash;prompt=$Prompt;imageDirectionHash=$item.imageDirectionHash;evidence=$Evidence;evidenceKind=$EvidenceKind;recordedAt=(Get-Date).ToString('o')} | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
    $record = [pscustomobject]@{chapterNumber=$ChapterNumber;chapterTitle=$item.chapterTitle;relativePath=$item.openerImageFile;status='Generated';provider='codex-imagegen';sha256=$hash;sourceSha256=$hash;sourcePath=$source;receiptFile=$receiptFile;receiptSha256=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash;visualReview='Pending';generatedAt=(Get-Date).ToString('o')}
    $record | Add-Member -NotePropertyName imageDirectionHash -NotePropertyValue $item.imageDirectionHash
    $manifest.images = @($manifest.images | Where-Object chapterNumber -ne $ChapterNumber) + @($record)
    $manifest | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $planPath = Join-Path $OutputFolder 'engagement-plan.json'
    $plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($chapter in @($plan.items | Where-Object chapterNumber -eq $ChapterNumber)) {
        $chapter | Add-Member -NotePropertyName productionStatus -NotePropertyValue 'Generated' -Force
        $chapter | Add-Member -NotePropertyName openerImagePrompt -NotePropertyValue $Prompt -Force
    }
    $plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $planPath -Encoding UTF8
    return $record
}

function Add-EbookGeneratedOpeners {
    param([string]$OutputFolder, [string]$MarkdownPath)
    $review = Get-EbookImageProductionReview $OutputFolder
    if ($review.status -ne 'PASS') { throw "Image production incomplete. $($review.detail)" }
    $markdown = Get-Content -LiteralPath $MarkdownPath -Raw -Encoding UTF8
    foreach ($item in @(Get-EbookImagePlan $OutputFolder)) {
        if ($markdown.Contains("]($($item.openerImageFile))")) { continue }
        $pattern = '(?m)^(# Chapter ' + $item.chapterNumber + ':[^\r\n]*\r?\n)'
        if (-not [regex]::IsMatch($markdown, $pattern)) { throw "Missing chapter heading for image $($item.chapterNumber)." }
        $replacement = "`$1`r`n![$($item.openerAltText)]($($item.openerImageFile))`r`n"
        $markdown = [regex]::Replace($markdown, $pattern, $replacement)
    }
    Set-Content -LiteralPath $MarkdownPath -Value $markdown -Encoding UTF8
}

function Get-EbookImageExportReview {
    param([Parameter(Mandatory)][string]$OutputFolder)
    try {
        $review = Get-EbookImageProductionReview $OutputFolder
        if ($review.status -ne 'PASS') { throw $review.detail }
        $md = @(Get-ChildItem -LiteralPath $OutputFolder -Filter '* - E-Book.md' -File)
        $html = @(Get-ChildItem -LiteralPath $OutputFolder -Filter '* - E-Book.html' -File)
        $docx = @(Get-ChildItem -LiteralPath $OutputFolder -Filter '* - E-Book.docx' -File)
        if ($md.Count -ne 1 -or $html.Count -ne 1 -or $docx.Count -ne 1) { throw 'Image delivery requires one current Markdown, HTML, and Word book.' }
        $mdText = Get-Content -LiteralPath $md[0].FullName -Raw -Encoding UTF8
        $htmlText = Get-Content -LiteralPath $html[0].FullName -Raw -Encoding UTF8
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $stream = [IO.File]::OpenRead((Get-EbookImageNativePath $docx[0].FullName))
        try {
            $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read)
            try {
                $embeddedHashes = @{}
                foreach ($entry in @($zip.Entries | Where-Object FullName -like 'word/media/*')) {
                    $part = $entry.Open(); $sha = [Security.Cryptography.SHA256]::Create()
                    try { $hash = -join ($sha.ComputeHash($part) | ForEach-Object {$_.ToString('X2')}); $embeddedHashes[$hash] = $true }
                    finally { $part.Dispose(); $sha.Dispose() }
                }
                foreach ($item in @(Get-EbookImagePlan $OutputFolder)) {
                    if (-not $mdText.Contains("]($($item.openerImageFile))") -or -not $htmlText.Contains("src=`"$($item.openerImageFile)`"")) { throw "Chapter $($item.chapterNumber) generated image is not referenced in the current manuscript and HTML." }
                    $hash = Get-EbookImageHash (Resolve-EbookImagePath $OutputFolder $item.openerImageFile)
                    if (-not $embeddedHashes.ContainsKey($hash)) { throw "Chapter $($item.chapterNumber) generated image is missing or stale in Word. Rebuild the actual output." }
                }
            } finally { $zip.Dispose() }
        } finally { $stream.Dispose() }
        return [pscustomobject]@{status='PASS';detail='Every planned generated opener is referenced in Markdown/HTML and embedded byte-for-byte in the current Word output.'}
    } catch { return [pscustomobject]@{status='FAIL';detail=$_.Exception.Message} }
}
