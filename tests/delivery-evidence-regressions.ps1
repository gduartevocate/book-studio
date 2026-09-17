param([string]$OutputFolder=(Join-Path (Split-Path $PSScriptRoot -Parent) 'dist/GM1025-src-v6'))
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib/EbookReadiness.ps1')
$script:count=0
function Check([bool]$Ok,[string]$Message){if(-not $Ok){throw $Message};$script:count++}
function Clone($Value){$Value | ConvertTo-Json -Depth 40 | ConvertFrom-Json}
function Read([string]$Name){Get-Content -LiteralPath (Join-Path $OutputFolder $Name) -Raw -Encoding UTF8 | ConvertFrom-Json}
$render=Read 'GM1025-review.render.json'
$independent=Read 'independent-publication-review.json'
$links=Read 'source-link-review.json'
$manifest=Read 'assigned-reading-list.json'
$base=@{Render=$render;Independent=$independent;Links=$links;CourseCode='GM1025';ChapterNumbers=@(1..5);DocxSha256=$render.docxSha256;PdfSha256=$render.pdfSha256;ManifestSha256=$links.manifestSha256;ExpectedUrls=@($manifest.sections.url)+@($manifest.resources.url)}
# Synthetic review records test the guard only. They are never saved to a book.
$visual=[pscustomobject]@{status='PASS';reviewer='TEST FIXTURE ONLY';reviewedAt=(Get-Date).ToString('o');docxSha256=$render.docxSha256;pdfSha256=$render.pdfSha256;thumbnailPages=@(1..$render.pages);enlargedPages=@(1..8)}
function TestCase([string]$Message,[scriptblock]$Mutate){$args=@{};foreach($key in $base.Keys){$args[$key]=Clone $base[$key]};$args.Visual=Clone $visual;& $Mutate $args;Check ((Test-EbookReviewEvidence @args).status -eq 'FAIL') $Message}
Check ((Test-EbookReviewEvidence @base -Visual $visual).status -eq 'PASS') 'Complete synthetic evidence did not pass.'
TestCase 'Missing render passed.' {param($a) $a.Render=$null}
TestCase 'Missing independent review passed.' {param($a) $a.Independent=$null}
TestCase 'Rendering alone counted as visual inspection.' {param($a) $a.Visual=$null}
TestCase 'Missing live link review passed.' {param($a) $a.Links=$null}
TestCase 'Stale DOCX passed.' {param($a) $a.DocxSha256='A'*64}
TestCase 'Stale PDF passed.' {param($a) $a.PdfSha256='B'*64}
TestCase 'Invalid hash passed.' {param($a) $a.PdfSha256=''}
TestCase 'Changed source manifest passed.' {param($a) $a.ManifestSha256='C'*64}
TestCase 'Another course review passed.' {param($a) $a.Independent.courseCode='GM1000'}
TestCase 'A failed detail under an overall PASS passed.' {param($a) $a.Independent.checks[0].status='FAIL'}
TestCase 'An empty independent review passed.' {param($a) $a.Independent.checks=@()}
TestCase 'A missing chapter check passed.' {param($a) $a.Independent.checks=@($a.Independent.checks | Where-Object name -ne 'word_chapter_3_exact_objectives')}
TestCase 'An obsolete review policy passed.' {param($a) $a.Independent.editorialPolicyVersion='old'}
TestCase 'Partial page inspection passed.' {param($a) $a.Visual.thumbnailPages=@(1..($render.pages-1))}
TestCase 'Missing enlarged samples passed.' {param($a) $a.Visual.enlargedPages=@(1..7)}
TestCase 'An out-of-range enlarged page passed.' {param($a) $a.Visual.enlargedPages=@(1..8)+999}
TestCase 'An unnamed visual reviewer passed.' {param($a) $a.Visual.reviewer=''}
TestCase 'An old visual review passed.' {param($a) $a.Visual.reviewedAt=([datetime]$render.generatedAt).AddDays(-1).ToString('o')}
TestCase 'A future visual review passed.' {param($a) $a.Visual.reviewedAt=(Get-Date).AddDays(1).ToString('o')}
TestCase 'A malformed render date passed.' {param($a) $a.Render.generatedAt='not a date'}
TestCase 'A fractional page count passed.' {param($a) $a.Render.pages=2.5}
TestCase 'A failed URL passed.' {param($a) $a.Links.results[0].status='FAIL'}
TestCase 'A missing URL passed.' {param($a) $a.Links.results=@($a.Links.results | Select-Object -Skip 1)}
TestCase 'An expired link review passed.' {param($a) $a.Links.generatedAt=(Get-Date).AddDays(-8).ToString('o')}
TestCase 'A future link review passed.' {param($a) $a.Links.generatedAt=(Get-Date).AddDays(1).ToString('o')}
TestCase 'A missing chapter contract passed.' {param($a) $a.ChapterNumbers=@()}
Check ((Test-EbookEditorialThresholds 7 -1).status -eq 'FAIL') 'Negative passive count passed.'
Check (-not (Get-EbookDeliveryReadiness -Checks @([pscustomobject]@{name='export';status='PASS'},[pscustomobject]@{name='generation_gate';status='FAIL'})).draftReadyForReview) 'A failed generation gate was ignored.'

$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ebook-package-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
foreach($pattern in @('quality-report.json','publishing-editor-report.json','ebook-output-audit.json','* - E-Book.docx','* - E-Book.md')){Get-ChildItem -LiteralPath $OutputFolder -Filter $pattern -File | Copy-Item -Destination $fixture}
Check ((Get-EbookPackageQaStatus $fixture) -eq 'FAIL') 'Legacy reports without generated-image evidence passed the new image gate.'
# Isolate the existing report-freshness unit cases from the image gate. Real
# image receipts plus Word/HTML embedding are covered without this stub in
# image-production-regressions.ps1. Never save synthetic approval to a book.
$actualImageReview = ${function:Get-EbookImageExportReview}
function Get-EbookImageExportReview { param([string]$OutputFolder) [pscustomobject]@{status='PASS';detail='TEST-ONLY report-freshness isolation'} }
try {
Check ((Get-EbookPackageQaStatus $fixture) -eq 'PASS') 'Current package fixture did not pass.'
function BadReport([string]$Name,[scriptblock]$Mutate,[string]$Message){$report=Read $Name;& $Mutate $report;$report | ConvertTo-Json -Depth 45 | Set-Content -LiteralPath (Join-Path $fixture $Name) -Encoding UTF8;Check ((Get-EbookPackageQaStatus $fixture) -eq 'FAIL') $Message;Copy-Item -LiteralPath (Join-Path $OutputFolder $Name) -Destination (Join-Path $fixture $Name)}
BadReport 'ebook-output-audit.json' {param($r) $r.docxSha256='D'*64} 'Stale Word audit passed.'
BadReport 'quality-report.json' {param($r) $r.manuscriptSha256='stale'} 'Stale manuscript report passed.'
BadReport 'publishing-editor-report.json' {param($r) $r.manuscriptSha256='stale'} 'Stale publishing review passed.'
BadReport 'publishing-editor-report.json' {param($r) $r.editorialPolicyVersion='old'} 'Obsolete publishing policy passed.'
BadReport 'ebook-output-audit.json' {param($r) $r.checks[0].status='WARNING'} 'A warning was hidden by readiness=true.'
BadReport 'ebook-output-audit.json' {param($r) $r.editorialPolicyVersion='old'} 'Obsolete audit policy passed.'
BadReport 'ebook-output-audit.json' {param($r) $r.checks=@()} 'Empty audit checks passed.'
} finally { Set-Item -Path Function:Get-EbookImageExportReview -Value $actualImageReview }
Write-Output "PASS: $script:count delivery-evidence regression assertions. Test fixture: $fixture"
