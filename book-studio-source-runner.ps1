param([string]$ProjectRoot,[string]$DatabasePath,[string]$JobId,[string]$PriorStatus)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $ProjectRoot 'lib/BookStudio.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'lib/EbookGenerator.psm1') -Force
$failure=''
try {
    $job=Get-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId
    $plan=Get-Content -LiteralPath (Join-Path $job.outputFolder 'ebook-plan.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $report=Update-EbookRequiredSourceEvidence -Plan $plan -OutputFolder $job.outputFolder
    if ($report.status -ne 'PASS') { throw ($report.issues -join ' ') }
    $contextPath=Join-Path $job.outputFolder 'source-context-index.json'
    $context=if(Test-Path -LiteralPath $contextPath){Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 | ConvertFrom-Json}else{$null}
    $sources=@(New-EbookRequiredSourceBrief -Plan $plan -OutputFolder $job.outputFolder -SourceContext $context)
    $backup=Join-Path $job.outputFolder ('production-backups/'+(Get-Date -Format 'yyyyMMddHHmmssfff'))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($name in @('source-brief.json','sources.json','sources.md')) { $old=Join-Path $job.outputFolder $name; if(Test-Path -LiteralPath $old){Copy-Item -LiteralPath $old -Destination (Join-Path $backup $name)} }
    $sources | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $job.outputFolder 'source-brief.json') -Encoding UTF8
    & (Get-Module EbookGenerator) {
        param($sources,$folder,$course)
        $registry=New-SourceRegistry $sources
        $registry | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $folder 'sources.json') -Encoding UTF8
        ConvertTo-SourceRegistryMarkdown -Course $course -SourceRegistry $registry | Set-Content -LiteralPath (Join-Path $folder 'sources.md') -Encoding UTF8
    } $sources $job.outputFolder ([pscustomobject]@{courseCode=$job.courseCode;courseName=$job.title})
} catch { $failure=$_.Exception.Message }
finally {
    Update-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -Update { param($current) $current.status=$PriorStatus; $current.runnerProcessId=$null }
    $detail=if($failure){"Required source check failed: $failure"}else{'Required source text retrieved. Existing manuscript is unchanged. Use Fix QA with Codex to integrate and cite these readings, then review the content.'}
    Set-BookStudioJobProgress -DatabasePath $DatabasePath -JobId $JobId -Phase 'Required source check finished' -Detail $detail -Percent 100 -AddLog
    $null=Refresh-BookStudioJobArtifacts -DatabasePath $DatabasePath -JobId $JobId
}
