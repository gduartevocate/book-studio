param([Parameter(Mandatory)][string]$OutlineArchive, [string]$ManuscriptFolder)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'lib/BookStudio.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'lib/EbookGenerator.psm1') -Force -DisableNameChecking
$studio = Get-Module BookStudio
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('studio-qa-' + [guid]::NewGuid().ToString('N'))
$dbPath = Initialize-BookStudioDatabase -ProjectRoot $fixture
Expand-Archive -LiteralPath $OutlineArchive -DestinationPath (Join-Path $fixture 'outline')
$folder = (Get-ChildItem -LiteralPath (Join-Path $fixture 'outline') -Recurse -Filter ebook-plan.json | Select-Object -First 1).DirectoryName
$script:checks = 0
function Check([bool]$ok, [string]$message) { if (-not $ok) { throw $message }; $script:checks++ }
function SaveJob([string]$path, [string]$status = 'Completed') {
    $db = Read-BookStudioDatabase $dbPath
    $db.jobs = @([pscustomobject]@{id='qa-test';title='QA regression';courseCode='';status=$status;updatedAt=(Get-Date).ToString('s');outputFolder=$path;artifacts=@();log=@();aiRequests=@()})
    Write-BookStudioDatabase $dbPath $db
}
function Review { & $studio {param($d,$r) Invoke-BookStudioQaReview -DatabasePath $d -JobId 'qa-test' -ProjectRoot $r} $dbPath $root }
function HashContent([string]$path) {
    @(Get-ChildItem -LiteralPath $path -File | Where-Object { $_.Extension -eq '.docx' -or $_.Name -like '* - E-Book.md' -or $_.Name -eq 'ebook-outline.md' } | Sort-Object Name | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash }) -join ','
}
SaveJob $folder
$before = HashContent $folder
$result = Review
Check ($result.status -eq 'Completed' -and $result.qaSummary.stage -eq 'outline') 'Outline was reviewed as a book.'
Check ($result.qaSummary.outlineStatus -eq 'Ready for review') 'Ann outline exports failed.'
Check ($result.qaSummary.sourceReadiness.status -eq 'Needs attention') 'Saved title-only source entries were silently cleared.'
Check (@($result.qaSummary.findings).Count -eq 0 -and ($result.qaSummary | ConvertTo-Json -Depth 15) -notmatch 'numbered source note') 'Outline got manuscript citation findings.'
Check ($before -eq (HashContent $folder)) 'Review rewrote outline content or Word exports.'
Check (-not (Test-Path -LiteralPath (Join-Path $folder 'quality-report.json'))) 'Outline generated book quality reports.'
Check ((Get-BookStudioJob $dbPath 'qa-test').qaReview.checkedAt -and (Test-Path -LiteralPath (Join-Path $folder 'qa-review.json'))) 'Review receipt missing.'
# Stale manuscript reports cannot turn a preview into a book failure.
'{"status":"FAIL"}' | Set-Content -LiteralPath (Join-Path $folder 'quality-report.json') -Encoding UTF8
$summary = & $studio {param($f) Get-BookStudioQualitySummary $f} $folder
Check ($summary.stage -eq 'outline' -and $summary.status -ne 'FAIL') 'Stale book QA leaked into outline status.'
$planPath = Join-Path $folder 'ebook-plan.json'
$plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
$plan.requiredReadings = @($plan.requiredReadings | Where-Object url)
$plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $planPath -Encoding UTF8
$result = Review
Check ($result.qaSummary.sourceReadiness.status -eq 'Not checked') 'Unretrieved links were labeled ready.'
$null = Update-EbookRequiredSourceEvidence -Plan $plan -OutputFolder $folder -ReadSource {param($url,$work) [pscustomobject]@{text=('Synthetic test evidence. '*40);resolvedUrl=$url;contentType='text/plain'}}
$result = Review
Check ($result.qaSummary.sourceReadiness.status -eq 'Ready') 'Verified source evidence was rejected for missing manuscript citations.'
$source = Get-ChildItem -LiteralPath (Join-Path $folder 'source-readings') -File | Select-Object -First 1
Add-Content -LiteralPath $source.FullName -Value 'Changed source text.'
$result = Review
Check ($result.qaSummary.sourceReadiness.status -eq 'Needs attention') 'Changed source evidence passed outline QA.'
SaveJob $folder 'Running'
$rejected = $false
try { Review | Out-Null } catch { $rejected = $_.Exception.Message -match 'current work|finish' }
Check $rejected 'Concurrent QA was allowed during generation.'
SaveJob $folder
'invalid json' | Set-Content -LiteralPath $planPath -Encoding UTF8
$rejected = $false
try { Review | Out-Null } catch { $rejected = $true }
Check ($rejected -and (Get-BookStudioJob $dbPath 'qa-test').qaReview.status -eq 'Failed') 'Review execution failure was hidden.'
if ($ManuscriptFolder) {
    $book = Join-Path $fixture 'book'
    Copy-Item -LiteralPath $ManuscriptFolder -Destination $book -Recurse
    SaveJob $book
    $before = HashContent $book
    $result = Review
    Check ($result.status -eq 'Completed' -and $result.qaSummary.stage -ne 'outline') 'Manuscript QA did not finish.'
    Check ($before -eq (HashContent $book)) 'QA rerun rewrote the manuscript or Word exports.'
    $quality = Get-Content -LiteralPath (Join-Path $book 'quality-report.json') -Raw | ConvertFrom-Json
    Check ($quality.generatedAt -and $quality.manuscriptSha256 -and (Test-Path -LiteralPath (Join-Path $book 'ebook-output-audit.json'))) 'Fresh book QA reports missing.'
}
"PASS: $script:checks QA review checks. Fixture: $fixture"
