[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('BookStudioTests/'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
Import-Module (Join-Path $root 'lib/BookStudio.psm1') -Force -DisableNameChecking
$studio=Get-Module BookStudio
$script:checks=0
function Check([bool]$Ok,[string]$Message){if(-not $Ok){throw $Message};$script:checks++}
function Reject([scriptblock]$Action,[string]$Pattern){$rejected=$false;try{& $Action | Out-Null}catch{if($_.Exception.Message -notmatch $Pattern){throw};$rejected=$true};Check $rejected "Expected rejection: $Pattern"}
function Upload([string]$Name,[string]$Text){[pscustomobject]@{name=$Name;contentBase64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))}}
$spec=@'
Course Number
QA1000
Course Name
Office Workflow Fixture
Course Description
This fixture teaches office records and workflow coordination.
Course Objectives
CO1: Organize office records using clear naming rules.
CO2: Coordinate office workflow using task ownership.
Week 1 Office Records
1. Office records and clear naming rules
Week 2 Workflow Coordination
2. Office workflow, task ownership, and handoffs
'@
$first=Upload 'QA1000 blueprint.txt' $spec
$second=Upload 'QA1000 blueprint.txt' 'Office records use clear naming rules. Workflow coordination assigns task ownership. This is a separate reading, not the authoritative blueprint.'
Reject {New-BookStudioJob -ProjectRoot $fixture -DatabasePath (Join-Path $fixture 'db.json') -Request ([pscustomobject]@{files=@($first,$second)})} 'Select the authoritative'
foreach($bad in @((Upload 'scan.pdf' 'pdf'),(Upload 'empty.txt' ''),[pscustomobject]@{name='bad.txt';contentBase64='not-base64'})){
    Reject {& $studio {param($r) Test-BookStudioUploadRequest $r} ([pscustomobject]@{files=@($bad)})} 'Unsupported|nonempty|Invalid upload'
}
$db=Initialize-BookStudioDatabase -ProjectRoot $fixture
$job=New-BookStudioJob -ProjectRoot $fixture -DatabasePath $db -Request ([pscustomobject]@{title='Office Workflow Fixture';courseCode='QA1000';primaryFileIndex=0;files=@($first,$second);specialInstructions='Use plain language and preserve all objectives.';useCodexDrafting=$false;useCodexImages=$false})
Check ($job.options.sourceMode -eq 'UploadedOnly' -and $job.options.skipResearch -and $job.options.skipOpenStaxFetch) 'New jobs did not default to uploaded-only mode.'
Check (($job.uploadedFiles.path | Select-Object -Unique).Count -eq 3) 'Duplicate filenames overwrote each other.'
Check ((Get-Content -LiteralPath $job.uploadedFiles[0].path -Raw -Encoding UTF8) -eq $spec) 'The blueprint was overwritten.'
Check ($job.intake.readFiles -eq 3 -and $job.intake.files[0].sha256) 'Accepted source coverage or hashes missing.'
Check ($job.specPath -eq $job.uploadedFiles[0].path) 'Explicit primary selection was not honored.'
Import-Module (Join-Path $root 'lib/EbookGenerator.psm1') -Force
$ebook=Get-Module EbookGenerator
$context=Import-SourceContext -Path $job.sourceContextPath -CourseSpecPath $job.specPath -StrictCoverage -IncludedPaths $job.uploadedFiles.path
$context | Add-Member sourceMode UploadedOnly
Reject {Import-SourceContext -Path $job.sourceContextPath -StrictCoverage -IncludedPaths $job.uploadedFiles.path -MaxFiles 2} 'limit'
Reject {Import-SourceContext -Path $job.sourceContextPath -StrictCoverage -IncludedPaths $job.uploadedFiles.path -MaxTotalChars 10} 'truncation'
$empty=Join-Path $fixture 'blank.txt';'   ' | Set-Content -LiteralPath $empty
Reject {Import-SourceContext -Path $fixture -StrictCoverage -IncludedPaths @($empty)} 'readable'
$many=@(1..24 | ForEach-Object {Upload "reading$_.txt" "Office workflow reading $_ contains distinct evidence about task ownership and records."})
$manyJob=New-BookStudioJob -ProjectRoot $fixture -DatabasePath $db -Request ([pscustomobject]@{files=$many;primaryFileIndex=0})
Check $manyJob.options.useCodexImages 'Server-side job creation did not default real image generation on.'
Check ($manyJob.intake.readFiles -eq 24) 'The old 20-file silent cap remains.'
$chapter1=[pscustomobject]@{number=1;title='Office Records';focus='Office records naming';learningTargets=@('Organize office records using clear naming rules.');learningTargetRecords=@([pscustomobject]@{objectiveId='';objective='Organize office records using clear naming rules.'})}
$plan=[pscustomobject]@{sourceMode='UploadedOnly';chapters=@($chapter1)}
# Any source-discovery or web call is a test failure, not a stubbed success.
$sources=& $ebook {
    param($p,$ctx)
    function Find-OpenStaxPages {throw 'Unexpected external discovery'}
    function Get-OpenStaxPageContent {throw 'Unexpected external fetch'}
    function Invoke-WebRequest {throw 'Unexpected web request'}
    function Invoke-RestMethod {throw 'Unexpected REST request'}
    Resolve-EbookSources -Plan $p -SourceContext $ctx -SourceMapPath 'deliberately-absent.json' -SourceMode UploadedOnly
} $plan $context
Check (@($sources).Count -eq 1 -and @($sources[0].openStax).Count -eq 0 -and @($sources[0].researchCandidates).Count -eq 0) 'Uploaded-only source resolution used external sources.'
Check (@($sources[0].sourceContext | Where-Object {$_.sourceFile -match 'book-studio-brief'}).Count -eq 0) 'Production notes were treated as academic citation evidence.'
Check (@($sources[0].sourceContext | Where-Object sourceFile -eq $job.specPath).Count -eq 0) 'Blueprint was treated as academic evidence.'
Reject { & $ebook { param($p,$ctx) $ctx.files=@($ctx.files | Where-Object isCourseSpec); $ctx.chunks=@($ctx.chunks | Where-Object sourceFile -eq $ctx.files[0].path); Resolve-EbookSources -Plan $p -SourceContext $ctx -SourceMapPath 'absent.json' -SourceMode UploadedOnly } $plan ($context | ConvertTo-Json -Depth 15 | ConvertFrom-Json) } 'No uploaded teaching content'
Check (& $ebook {param($p,$s,$c) Test-EbookUploadedSourceEvidence $p $s $c} $plan $sources[0] $context) 'Valid uploaded evidence failed.'
Check ((& $ebook {param($chapter,$chapterSources) Get-SourceFitSignals -Chapter $chapter -ChapterSources $chapterSources} $chapter1 $sources[0]).status -eq 'WARNING') 'Uploaded-only source policy incorrectly blocked on external source-fit coverage.'
$badSources=$sources[0] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$badSources.sourceContext[0].excerpt+=' invented evidence'
Check (-not (& $ebook {param($p,$s,$c) Test-EbookUploadedSourceEvidence $p $s $c} $plan $badSources $context)) 'Invented chunk evidence passed.'
Check ((& $ebook {param($p,$s,$c) Get-EbookUploadedSourceReview -Plan $p -Sources $s -SourceContext $c -Markdown '[outside](https://example.org)'} $plan $sources $context).status -eq 'FAIL') 'External citation passed uploaded-only gate.'
$registry=& $ebook {param($s) New-SourceRegistry -Sources $s} $sources
$citations=& $ebook {param($s,$r) Get-ChapterCitationModel -ChapterSources $s -SourceRegistry $r} $sources[0] $registry
Check ($citations.sourceContext.Count -ge 1 -and @($citations.sourceContext | Where-Object {$_.url}).Count -eq 0) 'Provided-document citations are missing or invented URLs.'
'changed after intake' | Add-Content -LiteralPath $job.uploadedFiles[1].path
Check (-not (& $ebook {param($p,$s,$c) Test-EbookUploadedSourceEvidence $p $s $c} $plan $sources[0] $context)) 'Changed uploaded files passed the source hash gate.'

$output=Join-Path $fixture 'format';New-Item -ItemType Directory -Path $output | Out-Null
$plan | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $output 'ebook-plan.json') -Encoding UTF8
Update-BookStudioJob -DatabasePath $db -JobId $job.id -Update {param($j) $j.outputFolder=$output;$j.status='Completed'}
$job=Get-BookStudioJob -DatabasePath $db -JobId $job.id
$null=New-BookStudioFormatPreview -Job $job -OutputFolder $output
Check ((Get-Content -LiteralPath (Join-Path $output 'book-format-preview.html') -Raw) -match 'Objective mapping ID requires verification') 'A valid objective with a missing mapping ID incorrectly blocked the format preview.'
$before=& $studio {param($j) Get-BookStudioFormatState $j} $job
$null=Set-BookStudioFormatReview -DatabasePath $db -JobId $job.id -ProjectRoot $fixture -Action request-changes -Layout large-text -Notes 'Check the larger text layout.'
$job=Get-BookStudioJob -DatabasePath $db -JobId $job.id
$after=& $studio {param($j) Get-BookStudioFormatState $j} $job
Check ($before.fingerprint -ne $after.fingerprint -and $after.layout -eq 'large-text') 'Format edits did not change the preview/fingerprint.'
Check ((Get-Content -LiteralPath (Join-Path $output 'book-format-preview.html') -Raw) -match 'font-size: 14pt') 'Larger layout was not applied to HTML.'
Reject {Set-BookStudioFormatReview -DatabasePath $db -JobId $job.id -ProjectRoot $fixture -Action approve -Layout large-text -PreviewFingerprint $before.fingerprint -NotesResolved $true} 'preview changed'
Reject {Set-BookStudioFormatReview -DatabasePath $db -JobId $job.id -ProjectRoot $fixture -Action approve -Layout large-text -PreviewFingerprint $after.fingerprint} 'additional format requests'
Import-Module (Join-Path $root 'lib/EbookGenerator.psm1') -Force
$ebook=Get-Module EbookGenerator
$word=Join-Path $output 'layout.docx'
& $ebook {param($p,$o) Export-MarkdownToDocx -Markdown "# Chapter 1: Layout fixture`n`nUse clear records." -Path $p -AssetRoot $o} $word $output
Check ((& $ebook {param($p) Get-EbookDocxArtifactIssues -Path $p} $word).status -eq 'PASS') 'Word export did not match the per-book format contract.'
$job.formatReview.status='Approved';$job.formatReview.fingerprint=$after.fingerprint
& $studio {param($j,$r) Assert-BookStudioGenerationReady $j $r} $job $fixture
Check $true 'Valid preview approval rejected.'
'<!-- changed -->' | Add-Content -LiteralPath (Join-Path $output 'book-format-preview.html')
Reject {& $studio {param($j,$r) Assert-BookStudioGenerationReady $j $r} $job $fixture} 'outdated approval'

$wrapped="Error: Your access token could not be refreshed because your refresh token was already used. Please log`nout and sign in again."
Check ((& $studio {param($t) Get-BookStudioCodexFailure $t} $wrapped).kind -eq 'authentication') 'Refresh-token failure not classified.'
$errorLog=Join-Path $fixture 'wrapped.log';$wrapped | Set-Content -LiteralPath $errorLog
Check ((& $studio {param($p) Get-BookStudioAiLogPreview -Path $p} $errorLog) -match 'out and sign in again') 'Wrapped recovery text was lost.'
Check ((& $studio {Get-BookStudioCodexFailure '429 rate limit'}).kind -eq 'quota') 'Quota classification missing.'
Check ((& $studio {Get-BookStudioCodexFailure 'Connection timed out'}).kind -eq 'timeout') 'Timeout classification missing.'
$command='C:\fixture\codex.exe'
$identity=& $studio {param($c) Get-BookStudioConnectionIdentity $c} $command
$record=[pscustomobject]@{status='PASS';checkedAt=(Get-Date).ToString('o');identity=$identity}
& $studio {param($r,$v) Set-BookStudioConnectionResult $r $v} $fixture $record
Check ((& $studio {param($r,$c) Get-BookStudioConnectionResult $r $c} $fixture $command).status -eq 'PASS') 'Current probe proof rejected.'
Check (-not (& $studio {param($r) Get-BookStudioConnectionResult $r 'different.exe'} $fixture)) 'Connection proof transferred to another executable.'
$record.checkedAt=(Get-Date).AddMinutes(-11).ToString('o')
& $studio {param($r,$v) Set-BookStudioConnectionResult $r $v} $fixture $record
Check (-not (& $studio {param($r,$c) Get-BookStudioConnectionResult $r $c} $fixture $command)) 'Expired probe still reported connected.'
$configured=Join-Path $fixture 'override.exe';Copy-Item -LiteralPath (Join-Path $PSHOME 'powershell.exe') -Destination $configured
$configured | Set-Content -LiteralPath (Join-Path $fixture 'codex-path.txt') -Encoding UTF8
Check ((Resolve-BookStudioCodexCommand -ProjectRoot $fixture).Source -eq $configured) 'Saved executable override did not take precedence.'

# npm installs Codex as shell wrappers. Book Studio starts Codex directly, so a
# wrapper must resolve to the native binary npm vendored inside the package.
$npmRoot=Join-Path $fixture 'npm'
$vendorBin=Join-Path $npmRoot 'node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin'
New-Item -ItemType Directory -Path $vendorBin -Force | Out-Null
$nativeCodex=Join-Path $vendorBin 'codex.exe'
Copy-Item -LiteralPath (Join-Path $PSHOME 'powershell.exe') -Destination $nativeCodex
foreach($wrapperName in @('codex','codex.cmd','codex.ps1')){
    $wrapper=Join-Path $npmRoot $wrapperName
    'wrapper that launches node' | Set-Content -LiteralPath $wrapper -Encoding UTF8
    Check ((& $studio {param($p) Resolve-BookStudioNativeCodexExecutable -Path $p} $wrapper) -eq $nativeCodex) "The npm wrapper $wrapperName did not resolve to the native codex.exe."
    $wrapper | Set-Content -LiteralPath (Join-Path $fixture 'codex-path.txt') -Encoding UTF8
    $resolvedCommand=Resolve-BookStudioCodexCommand -ProjectRoot $fixture
    Check ($resolvedCommand.Source -eq $nativeCodex -and $resolvedCommand.Discovery -match 'npm wrapper') "A configured $wrapperName was not replaced by the native executable."
}
# A wrapper inside the package (.../@openai/codex/bin) resolves the same way.
$packageBin=Join-Path $npmRoot 'node_modules\@openai\codex\bin'
New-Item -ItemType Directory -Path $packageBin -Force | Out-Null
$packageWrapper=Join-Path $packageBin 'codex.js'
'#!/usr/bin/env node' | Set-Content -LiteralPath $packageWrapper -Encoding UTF8
Check ((& $studio {param($p) Resolve-BookStudioNativeCodexExecutable -Path $p} $packageWrapper) -eq $nativeCodex) 'A wrapper inside the Codex package did not resolve to the native executable.'
# Without a vendored binary the wrapper is still returned, so the app can explain itself.
$lonelyWrapper=Join-Path $fixture 'lonely-codex.cmd'
'wrapper with no package' | Set-Content -LiteralPath $lonelyWrapper -Encoding UTF8
Check ($null -eq (& $studio {param($p) Resolve-BookStudioNativeCodexExecutable -Path $p} $lonelyWrapper)) 'A wrapper with no vendored binary must not resolve.'
$lonelyWrapper | Set-Content -LiteralPath (Join-Path $fixture 'codex-path.txt') -Encoding UTF8
$lonelyResult=Resolve-BookStudioCodexCommand -ProjectRoot $fixture
# Either the wrapper itself (nothing native anywhere) or a native executable
# found elsewhere on this machine; never nothing at all.
Check ($lonelyResult -and ($lonelyResult.Source -eq $lonelyWrapper -or [IO.Path]::GetExtension($lonelyResult.Source) -eq '.exe')) 'A wrapper with no vendored binary must still resolve to a usable Codex command.'
$configured | Set-Content -LiteralPath (Join-Path $fixture 'codex-path.txt') -Encoding UTF8
[pscustomobject]@{status='PASS';assertions=$script:checks;fixture=$fixture;liveCodex='Not invoked';productionBooksChanged=$false} | ConvertTo-Json
